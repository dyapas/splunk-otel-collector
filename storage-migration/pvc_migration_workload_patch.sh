#!/bin/bash

set -euo pipefail

### Configuration
VOLUME_SNAPSHOT_CLASS="your-snapshotclass"
NEW_STORAGE_CLASS="your-new-storageclass"
INPUT_CSV="migration-input.csv"
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
log_err() { echo "[ERROR]   $*" | tee -a "$LOG_FILE" >&2; echo "$NAMESPACE,$WORKLOAD_NAME,$WORKLOAD_KIND,$PVC_NAME,$*" >> "$ERROR_REPORT"; }

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

### Lookup CSV Entry
ENTRY=$(awk -F',' -v ns="$NAMESPACE" -v pvc="$PVC_NAME" '$1==ns && $4==pvc {print}' "$INPUT_CSV" | head -n1)
if [[ -z "$ENTRY" ]]; then
  log_err "No entry found in CSV for namespace=$NAMESPACE and pvc=$PVC_NAME"
  exit 1
fi

WORKLOAD_NAME=$(echo "$ENTRY" | cut -d',' -f2)
WORKLOAD_KIND=$(echo "$ENTRY" | cut -d',' -f3)
OLD_PVC="$PVC_NAME"
NEW_PVC="${OLD_PVC}-ps"
SNAPSHOT_NAME="${OLD_PVC}-snapshot-${TIMESTAMP}"

### Validate PVC Bound
if ! oc get pvc "$OLD_PVC" -n "$NAMESPACE" -o jsonpath='{.status.phase}' | grep -q Bound; then
  log_err "PVC $OLD_PVC is not Bound. Skipping."
  exit 1
fi

### Extract size and accessModes
SIZE=$(oc get pvc "$OLD_PVC" -n "$NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')
ACCESS_MODES=$(oc get pvc "$OLD_PVC" -n "$NAMESPACE" -o jsonpath='{.spec.accessModes[*]}')

### Save old PVC manifest
mkdir -p "$MANIFEST_DIR/$NAMESPACE"
oc get pvc "$OLD_PVC" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/old_${OLD_PVC}.yaml"

### Scale down workload
REPLICAS=0
if [[ "$WORKLOAD_KIND" =~ ^(Deployment|DeploymentConfig|StatefulSet)$ ]]; then
  REPLICAS=$(oc get "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
  log "Scaling down $WORKLOAD_KIND/$WORKLOAD_NAME to 0"
  [[ "$DRY_RUN" == false ]] && oc scale "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" --replicas=0
else
  log_err "Unsupported workload kind: $WORKLOAD_KIND"
  exit 1
fi

### Save pre-patch manifest
oc get "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/before_${WORKLOAD_NAME}.yaml"

### Create VolumeSnapshot
log "Creating VolumeSnapshot $SNAPSHOT_NAME"
cat <<EOF | tee "$MANIFEST_DIR/$NAMESPACE/${SNAPSHOT_NAME}.yaml"
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $SNAPSHOT_NAME
  namespace: $NAMESPACE
spec:
  volumeSnapshotClassName: $VOLUME_SNAPSHOT_CLASS
  source:
    persistentVolumeClaimName: $OLD_PVC
EOF

[[ "$DRY_RUN" == false ]] && oc apply -f "$MANIFEST_DIR/$NAMESPACE/${SNAPSHOT_NAME}.yaml"

log "Waiting for snapshot to be ready..."
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

### Patch workload volumeMount
log "Patching workload to use new PVC..."
VOLUME_INDEX=$(oc get "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" -o json | jq -r \
  --arg pvc "$OLD_PVC" '
    .spec.template.spec.volumes
    | to_entries[]
    | select(.value.persistentVolumeClaim.claimName == $pvc)
    | .key')

PATCH=$(cat <<EOF
[{"op": "replace", "path": "/spec/template/spec/volumes/$VOLUME_INDEX/persistentVolumeClaim/claimName", "value": "$NEW_PVC"}]
EOF
)

[[ "$DRY_RUN" == false ]] && oc patch "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" --type=json -p="$PATCH"

### Save post-patch manifest
oc get "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" -o yaml > "$MANIFEST_DIR/$NAMESPACE/after_${WORKLOAD_NAME}.yaml"

### Scale back workload
log "Scaling $WORKLOAD_KIND/$WORKLOAD_NAME back to $REPLICAS"
[[ "$DRY_RUN" == false ]] && oc scale "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" --replicas="$REPLICAS"

log "✅ Migration completed for $OLD_PVC → $NEW_PVC"

### Send email if errors
if [[ -s "$ERROR_REPORT" ]]; then
  log_warn "Sending error report to $EMAIL_TO"
  {
    echo "Subject: PVC Migration Error Report - $TIMESTAMP"
    echo "From: $EMAIL_FROM"
    echo "To: $EMAIL_TO"
    echo
    echo "Errors occurred during PVC migration:"
    echo
    cat "$ERROR_REPORT"
  } | /usr/sbin/sendmail "$EMAIL_TO"
fi
