#!/bin/bash

set -euo pipefail

### Configurable variables
VOLUME_SNAPSHOT_CLASS="your-snapshotclass"
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

### Logging
log()     { echo "[INFO]    $*" | tee -a "$LOG_FILE"; }
log_warn(){ echo "[WARNING] $*" | tee -a "$LOG_FILE"; }
log_err() { echo "[ERROR]   $*" | tee -a "$LOG_FILE" >&2; echo "$NAMESPACE,,,$PVC_NAME,$*" >> "$ERROR_REPORT"; }

### Input args
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace) NAMESPACE="$2"; shift ;;
    --pvc-name) PVC_NAME="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option $1"; exit 1 ;;
  esac
  shift
done

if [[ -z "${NAMESPACE:-}" || -z "${PVC_NAME:-}" ]]; then
  echo "Usage: $0 --namespace <namespace> --pvc-name <pvc> [--dry-run]"
  exit 1
fi

SNAPSHOT_NAME="${PVC_NAME}-snapshot-${TIMESTAMP}"
NEW_PVC="${PVC_NAME}-ps"
mkdir -p "$MANIFEST_DIR/$NAMESPACE"

### Validate PVC
if ! oc get pvc "$PVC_NAME" -n "$NAMESPACE" &>/dev/null; then
  log_err "PVC $PVC_NAME does not exist in $NAMESPACE"
  exit 1
fi

PHASE=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
if [[ "$PHASE" != "Bound" ]]; then
  log_err "PVC $PVC_NAME is not in Bound state (current: $PHASE)"
  exit 1
fi

### PVC details
SIZE=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
ACCESS_MODES=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.accessModes[*]}')

### Save original PVC manifest
oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/old_${PVC_NAME}.yaml"

### Create VolumeSnapshot
log "Creating VolumeSnapshot $SNAPSHOT_NAME"
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

[[ "$DRY_RUN" == false ]] && oc apply -f "$MANIFEST_DIR/$NAMESPACE/${SNAPSHOT_NAME}.yaml"

log "Waiting for VolumeSnapshot $SNAPSHOT_NAME to be ready..."
timeout 120 bash -c -- "[[ '$DRY_RUN' == true ]] || while ! oc get volumesnapshot $SNAPSHOT_NAME -n $NAMESPACE -o jsonpath='{.status.readyToUse}' | grep -q true; do sleep 5; done"

### Create new PVC from snapshot
log "Creating new PVC $NEW_PVC"
cat <<EOF > "$MANIFEST_DIR/$NAMESPACE/new_${NEW_PVC}.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $NEW_PVC
  namespace: $NAMESPACE
spec:
  accessModes:
$(for mode in $ACCESS_MODES; do echo "  - $mode"; done)
  storageClassName: $NEW_STORAGE_CLASS
  resources:
    requests:
      storage: $SIZE
  dataSource:
    name: $SNAPSHOT_NAME
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

[[ "$DRY_RUN" == false ]] && oc apply -f "$MANIFEST_DIR/$NAMESPACE/new_${NEW_PVC}.yaml"

### Wait for new PVC to bind
if [[ "$DRY_RUN" == false ]]; then
  log "Waiting for new PVC $NEW_PVC to be bound..."
  timeout 120 bash -c "while [[ \$(oc get pvc $NEW_PVC -n $NAMESPACE -o jsonpath='{.status.phase}') != 'Bound' ]]; do sleep 5; done"
fi

### Remove dataSource after binding
if [[ "$DRY_RUN" == false ]]; then
  log "Removing dataSource from PVC $NEW_PVC"
  oc patch pvc "$NEW_PVC" -n "$NAMESPACE" --type=json -p='[{"op": "remove", "path": "/spec/dataSource"}]' || log_warn "Failed to remove dataSource (may already be removed)"
fi

### Identify workloads using the PVC
log "Searching for workloads using PVC: $PVC_NAME"

WORKLOADS=$(oc get deploy,dc,sts -n "$NAMESPACE" -o json | jq -r \
  --arg pvc "$PVC_NAME" '
  .items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) |
  [.kind, .metadata.name] | @tsv')

if [[ -z "$WORKLOADS" ]]; then
  log_warn "No workloads found using PVC $PVC_NAME"
  exit 0
fi

while IFS=$'\t' read -r KIND NAME; do
  log "Processing $KIND $NAME"

  VOLUME_INDEX=$(oc get "$KIND" "$NAME" -n "$NAMESPACE" -o json | jq -r \
    --arg pvc "$PVC_NAME" '
      .spec.template.spec.volumes
      | to_entries[]
      | select(.value.persistentVolumeClaim.claimName == $pvc)
      | .key')

  oc get "$KIND" "$NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/before_${NAME}.yaml"

  REPLICAS=$(oc get "$KIND" "$NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
  log "Scaling down $KIND/$NAME to 0"
  [[ "$DRY_RUN" == false ]] && oc scale "$KIND" "$NAME" -n "$NAMESPACE" --replicas=0

  log "Patching $KIND/$NAME to use PVC $NEW_PVC"
  PATCH=$(cat <<EOF
[{"op": "replace", "path": "/spec/template/spec/volumes/$VOLUME_INDEX/persistentVolumeClaim/claimName", "value": "$NEW_PVC"}]
EOF
)
  [[ "$DRY_RUN" == false ]] && oc patch "$KIND" "$NAME" -n "$NAMESPACE" --type=json -p="$PATCH"

  oc get "$KIND" "$NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/after_${NAME}.yaml"

  log "Scaling $KIND/$NAME back to $REPLICAS"
  [[ "$DRY_RUN" == false ]] && oc scale "$KIND" "$NAME" -n "$NAMESPACE" --replicas="$REPLICAS"
done <<< "$WORKLOADS"

log "✅ PVC migration complete for $PVC_NAME → $NEW_PVC"

### Email error report if any
if [[ -s "$ERROR_REPORT" ]]; then
  log_warn "Sending error report to $EMAIL_TO"
  {
    echo "Subject: PVC Migration Error Report - $TIMESTAMP"
    echo "From: $EMAIL_FROM"
    echo "To: $EMAIL_TO"
    echo
    echo "Errors during PVC migration:"
    echo
    cat "$ERROR_REPORT"
  } | /usr/sbin/sendmail "$EMAIL_TO"
fi
