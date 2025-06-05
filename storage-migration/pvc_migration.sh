#!/bin/bash
## usage - with dry-run option: ./pvc_migration.sh dev-namespace my-data-pvc --dry-run
## actual migration/full migration: ./pvc_migration.sh dev-namespace my-data-pvc


set -euo pipefail

# Configurable values
NEW_STORAGE_CLASS="new-storage-class"
SNAPSHOT_CLASS="common-snapshot-class"
INPUT_CSV="migration-input.csv"
SNAPSHOT_RETENTION=3
OUTPUT_DIR="./pvc-manifests"
ERROR_REPORT="./error_report.csv"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Internal setup
LOG_FILE="/tmp/pvc_migration_${TIMESTAMP}.log"
DRY_RUN=false

log()     { echo "[INFO]    $*" | tee -a "$LOG_FILE"; }
log_warn(){ echo "[WARNING] $*" | tee -a "$LOG_FILE"; }
log_err() { echo "[ERROR]   $*" | tee -a "$LOG_FILE" >&2; }

usage() {
  echo "Usage: $0 <namespace> <pvc-name> [--dry-run]"
  exit 1
}

# Args
if [[ $# -lt 2 ]]; then usage; fi

NAMESPACE="$1"
PVC_NAME="$2"
[[ "${3:-}" == "--dry-run" ]] && DRY_RUN=true

mkdir -p "$OUTPUT_DIR/$NAMESPACE"

# Get matching row from CSV
MATCH=$(awk -F, -v ns="$NAMESPACE" -v pvc="$PVC_NAME" '
  NR>1 && $1 == ns && $4 == pvc { print; exit }' "$INPUT_CSV")

if [[ -z "$MATCH" ]]; then
  log_err "No match in CSV for namespace=$NAMESPACE PVC=$PVC_NAME"
  echo "$NAMESPACE,$PVC_NAME,CSV Not Found" >> "$ERROR_REPORT"
  exit 1
fi

WORKLOAD_NAME=$(echo "$MATCH" | cut -d, -f2)
WORKLOAD_KIND=$(echo "$MATCH" | cut -d, -f3)

log "🔍 Processing: $WORKLOAD_KIND/$WORKLOAD_NAME using PVC: $PVC_NAME"

# Validate PVC is Bound
BOUND_STATUS=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath="{.status.phase}")
if [[ "$BOUND_STATUS" != "Bound" ]]; then
  log_err "PVC $PVC_NAME is not Bound (status=$BOUND_STATUS)"
  echo "$NAMESPACE,$PVC_NAME,Not Bound" >> "$ERROR_REPORT"
  exit 1
fi

# Save old PVC manifest
log "Saving old PVC manifest..."
oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o yaml > "$OUTPUT_DIR/$NAMESPACE/${PVC_NAME}_OLD.yaml"

# Get original replica count
REPLICAS=$(oc get "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.replicas}" || echo "0")

log "Scaling down $WORKLOAD_KIND $WORKLOAD_NAME..."
$DRY_RUN || oc scale "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" --replicas=0

# Create snapshot
SNAPSHOT_NAME="${PVC_NAME}-snap-${TIMESTAMP}"
log "Creating VolumeSnapshot $SNAPSHOT_NAME"
SNAPSHOT_YAML=$(cat <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${NAMESPACE}
  labels:
    migrated-from: ${PVC_NAME}
spec:
  volumeSnapshotClassName: ${SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${PVC_NAME}
EOF
)

if $DRY_RUN; then
  echo "$SNAPSHOT_YAML" | tee "$OUTPUT_DIR/$NAMESPACE/${PVC_NAME}_Snapshot.yaml"
else
  echo "$SNAPSHOT_YAML" | oc apply -f -
fi

# Wait for snapshot
if ! $DRY_RUN; then
  log "Waiting for snapshot to be ready..."
  for i in {1..12}; do
    READY=$(oc get volumesnapshot "$SNAPSHOT_NAME" -n "$NAMESPACE" -o jsonpath="{.status.readyToUse}" 2>/dev/null || echo "false")
    [[ "$READY" == "true" ]] && break
    sleep 5
  done

  if [[ "$READY" != "true" ]]; then
    log_err "Snapshot failed for PVC $PVC_NAME"
    echo "$NAMESPACE,$PVC_NAME,Snapshot Failed" >> "$ERROR_REPORT"
    oc scale "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" --replicas="$REPLICAS"
    exit 1
  fi
fi

# Extract volume size and accessModes
if ! $DRY_RUN; then
  SIZE=$(oc get volumesnapshot "$SNAPSHOT_NAME" -n "$NAMESPACE" -o jsonpath="{.status.restoreSize}")
  ACCESS_MODES=$(oc get pvc "$PVC_NAME" -n "$NAMESPACE" -o jsonpath="{.spec.accessModes[*]}")
else
  SIZE="10Gi"
  ACCESS_MODES="ReadWriteOnce"
fi

# Delete old PVC
log "Deleting PVC $PVC_NAME"
$DRY_RUN || oc delete pvc "$PVC_NAME" -n "$NAMESPACE"

# Generate new PVC manifest
NEW_PVC_FILE="$OUTPUT_DIR/$NAMESPACE/${PVC_NAME}_NEW.yaml"
log "Generating new PVC manifest..."
cat <<EOF > "$NEW_PVC_FILE"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
$(for mode in $ACCESS_MODES; do echo "    - $mode"; done)
  storageClassName: ${NEW_STORAGE_CLASS}
  resources:
    requests:
      storage: ${SIZE}
  dataSource:
    name: ${SNAPSHOT_NAME}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

# Apply new PVC
log "Creating new PVC $PVC_NAME"
$DRY_RUN || oc apply -f "$NEW_PVC_FILE"

# Scale workload back up
log "Scaling up $WORKLOAD_KIND $WORKLOAD_NAME to $REPLICAS replicas"
$DRY_RUN || oc scale "$WORKLOAD_KIND" "$WORKLOAD_NAME" -n "$NAMESPACE" --replicas="$REPLICAS"

# Retain snapshots (if not dry-run)
if ! $DRY_RUN; then
  log "Pruning old snapshots for $PVC_NAME..."
  SNAPS=$(oc get volumesnapshot -n "$NAMESPACE" -l migrated-from="$PVC_NAME" -o json \
    | jq -r '.items[] | [.metadata.name, .metadata.creationTimestamp] | @tsv' \
    | sort -k2 -r)

  COUNT=0
  while read -r NAME _; do
    COUNT=$((COUNT + 1))
    if [[ $COUNT -gt $SNAPSHOT_RETENTION ]]; then
      log "Deleting old snapshot $NAME"
      oc delete volumesnapshot "$NAME" -n "$NAMESPACE"
    fi
  done <<< "$SNAPS"
fi

log "✅ Migration complete for PVC $PVC_NAME in namespace $NAMESPACE"
