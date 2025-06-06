#!/bin/bash

set -euo pipefail

#######################################
# Configuration (set your values here)
#######################################
VOLUME_SNAPSHOT_CLASS="your-volumesnapshotclass"
NEW_STORAGE_CLASS="your-new-storageclass"
LOG_DIR="./logs"
MANIFEST_DIR="./manifests"
ERROR_REPORT="./error_report.csv"
EMAIL_TO="admin@example.com"
EMAIL_FROM="pvc-migration@openshift.local"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
DRY_RUN=false

mkdir -p "$LOG_DIR" "$MANIFEST_DIR"
LOG_FILE="$LOG_DIR/storage-migration-${TIMESTAMP}.log"
touch "$ERROR_REPORT"

log() { echo "[INFO]    $*" | tee -a "$LOG_FILE"; }
log_warn() { echo "[WARNING] $*" | tee -a "$LOG_FILE"; }
log_err() {
  echo "[ERROR]   $*" | tee -a "$LOG_FILE" >&2
  echo "$NAMESPACE,,,$PVC_NAME,$*" >> "$ERROR_REPORT"
}

#######################################
# Parse Arguments
#######################################
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --pvc-name)
      PVC_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${NAMESPACE:-}" || -z "${PVC_NAME:-}" ]]; then
  echo "Usage: $0 --namespace <namespace> --pvc-name <pvc-name> [--dry-run]"
  exit 1
fi

#######################################
# Validate PVC
#######################################
if ! oc get pvc "$PVC_NAME" -n "$NAMESPACE" &>/dev/null; then
  log_err "PVC $PVC_NAME not found in namespace $NAMESPACE"
  exit 1
fi

PHASE=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
if [[ "$PHASE" != "Bound" ]]; then
  log_err "PVC $PVC_NAME is not bound (status: $PHASE)"
  exit 1
fi

SIZE=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
ACCESS_MODES=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.accessModes[0]}')
NEW_PVC="${PVC_NAME}-ps"
SNAPSHOT_NAME="${PVC_NAME}-snapshot-${TIMESTAMP}"

mkdir -p "$MANIFEST_DIR/$NAMESPACE"
oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/old_${PVC_NAME}.yaml"

#######################################
# Create VolumeSnapshot
#######################################
cat <<EOF > "$MANIFEST_DIR/$NAMESPACE/${SNAPSHOT_NAME}.yaml"
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $SNAPSHOT_NAME
  namespace: $NAMESPACE
spec:
  volumeSnapshotClassName: $VOLUME_SNAPSHOT_CLASS
  source:
    persistentVolumeClaimName: $PVC_NAME
EOF

if ! $DRY_RUN; then
  oc apply -f "$MANIFEST_DIR/$NAMESPACE/${SNAPSHOT_NAME}.yaml"
fi

log "Waiting for VolumeSnapshot $SNAPSHOT_NAME to be ready..."
if ! timeout 120 bash -c "until oc get volumesnapshot $SNAPSHOT_NAME -n $NAMESPACE -o jsonpath='{.status.readyToUse}' | grep -q true; do sleep 5; done"; then
  log_err "VolumeSnapshot $SNAPSHOT_NAME not ready after timeout"
  exit 1
fi

#######################################
# Create New PVC From Snapshot
#######################################
cat <<EOF > "$MANIFEST_DIR/$NAMESPACE/new_${NEW_PVC}.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW_PVC
  namespace: $NAMESPACE
spec:
  accessModes:
  - $ACCESS_MODES
  resources:
    requests:
      storage: $SIZE
  storageClassName: $NEW_STORAGE_CLASS
  dataSource:
    name: $SNAPSHOT_NAME
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

if ! $DRY_RUN; then
  oc apply -f "$MANIFEST_DIR/$NAMESPACE/new_${NEW_PVC}.yaml"
fi

log "Waiting for new PVC $NEW_PVC to be bound..."
if ! timeout 120 bash -c "until oc get pvc $NEW_PVC -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q Bound; do sleep 5; done"; then
  log_err "New PVC $NEW_PVC not bound after timeout"
  exit 1
fi

log "Removing dataSource field from PVC $NEW_PVC"
oc patch pvc "$NEW_PVC" -n "$NAMESPACE" --type=json -p='[{"op": "remove", "path": "/spec/dataSource"}]' || log_warn "Failed to remove dataSource from $NEW_PVC"

#######################################
# Identify Workloads and Patch
#######################################
WORKLOADS=$(oc get deploy,dc,sts -n "$NAMESPACE" -o json | jq -r ".items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == \"$PVC_NAME\") | [.kind, .metadata.name] | @tsv")

if [[ -z "$WORKLOADS" ]]; then
  log_warn "No workloads found using PVC $PVC_NAME in namespace $NAMESPACE"
  exit 0
fi

while IFS=$'\t' read -r KIND NAME; do
  log "Processing $KIND $NAME"
  REPLICAS=$(oc get "$KIND" "$NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
  oc get "$KIND" "$NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/before_patch_${KIND,,}_$NAME.yaml"

  if ! $DRY_RUN; then
    oc scale "$KIND" "$NAME" -n "$NAMESPACE" --replicas=0
    sleep 5
    VOLUME_INDEX=$(oc get "$KIND" "$NAME" -n "$NAMESPACE" -o json | jq -r ".spec.template.spec.volumes | to_entries[] | select(.value.persistentVolumeClaim.claimName == \"$PVC_NAME\") | .key")
    oc patch "$KIND" "$NAME" -n "$NAMESPACE" --type='json' -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/volumes/$VOLUME_INDEX/persistentVolumeClaim/claimName\",\"value\":\"$NEW_PVC\"}]"
    sleep 3
    oc scale "$KIND" "$NAME" -n "$NAMESPACE" --replicas=$REPLICAS
  fi
  oc get "$KIND" "$NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/after_patch_${KIND,,}_$NAME.yaml"

done <<< "$WORKLOADS"

#######################################
# Email Error Report if Needed
#######################################
if [[ -s "$ERROR_REPORT" ]]; then
  SUBJECT="PVC Storage Migration Errors - $(date +%F)"
  BODY="Errors occurred during PVC migration for $NAMESPACE/$PVC_NAME. See attached CSV."
  echo -e "$BODY" | mailx -s "$SUBJECT" -a "$ERROR_REPORT" "$EMAIL_TO"
  log_warn "Error report emailed to $EMAIL_TO"
else
  log "Migration completed without errors."
fi
