#!/bin/bash

set -e

# Input arguments
NAMESPACE=$1
PVC_NAME=$2

# Define these inside the script
NEW_STORAGE_CLASS="new-storage-class-name"
SNAPSHOT_CLASS="common-volumesnapshotclass-name"

if [[ -z "$NAMESPACE" || -z "$PVC_NAME" ]]; then
  echo "❌ Usage: $0 <namespace> <pvc-name>"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d%H%M%S)
SNAPSHOT_NAME="${PVC_NAME}-snapshot-${TIMESTAMP}"
TMP_FILE="/tmp/original-replicas-${PVC_NAME}.json"

# Get workloads using PVC
get_workloads_using_pvc() {
  kubectl get deploy,statefulset -n "$NAMESPACE" -o json | jq -r "
    .items[]
    | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == \"$PVC_NAME\")
    | {kind: .kind, name: .metadata.name, replicas: .spec.replicas}
  "
}

echo "🔍 Checking workloads using PVC '$PVC_NAME'..."
WORKLOADS_JSON=$(get_workloads_using_pvc)
if [[ -z "$WORKLOADS_JSON" || "$WORKLOADS_JSON" == "null" ]]; then
  echo "⚠️ No workloads found using PVC '$PVC_NAME'"
else
  echo "$WORKLOADS_JSON" > "$TMP_FILE"
  echo "📉 Scaling down workloads..."
  echo "$WORKLOADS_JSON" | jq -c '.' | while read -r workload; do
    KIND=$(echo "$workload" | jq -r .kind)
    NAME=$(echo "$workload" | jq -r .name)
    echo "  ➤ Scaling down $KIND/$NAME..."
    kubectl scale "$KIND/$NAME" -n "$NAMESPACE" --replicas=0
  done
fi

echo "📸 Creating VolumeSnapshot '$SNAPSHOT_NAME'..."
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${NAMESPACE}
spec:
  volumeSnapshotClassName: ${SNAPSHOT_CLASS}
  source:
    persistentVolumeClaimName: ${PVC_NAME}
EOF

echo "⏳ Waiting for snapshot to be ready..."
ATTEMPTS=0
while true; do
  READY=$(kubectl get volumesnapshot ${SNAPSHOT_NAME} -n ${NAMESPACE} -o jsonpath="{.status.readyToUse}" 2>/dev/null || echo "false")
  if [[ "$READY" == "true" ]]; then
    echo "✅ Snapshot is ready."
    break
  fi
  if [[ "$ATTEMPTS" -ge 12 ]]; then
    echo "❌ Snapshot failed to become ready after 60 seconds. Rolling back..."
    if [[ -f "$TMP_FILE" ]]; then
      cat "$TMP_FILE" | jq -c '.' | while read -r workload; do
        KIND=$(echo "$workload" | jq -r .kind)
        NAME=$(echo "$workload" | jq -r .name)
        REPLICAS=$(echo "$workload" | jq -r .replicas)
        echo "  ➤ Scaling $KIND/$NAME back to $REPLICAS replicas..."
        kubectl scale "$KIND/$NAME" -n "$NAMESPACE" --replicas="$REPLICAS"
      done
    fi
    exit 1
  fi
  sleep 5
  ATTEMPTS=$((ATTEMPTS + 1))
done

echo "🗑️ Deleting old PVC '$PVC_NAME'..."
kubectl delete pvc ${PVC_NAME} -n ${NAMESPACE}

echo "📦 Recreating PVC '$PVC_NAME' from snapshot..."
STORAGE_SIZE=$(kubectl get volumesnapshot "$SNAPSHOT_NAME" -n "$NAMESPACE" -o jsonpath="{.status.restoreSize}")
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${NEW_STORAGE_CLASS}
  resources:
    requests:
      storage: ${STORAGE_SIZE}
  dataSource:
    name: ${SNAPSHOT_NAME}
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF

echo "⏫ Scaling workloads back up..."
if [[ -f "$TMP_FILE" ]]; then
  cat "$TMP_FILE" | jq -c '.' | while read -r workload; do
    KIND=$(echo "$workload" | jq -r .kind)
    NAME=$(echo "$workload" | jq -r .name)
    REPLICAS=$(echo "$workload" | jq -r .replicas)
    echo "  ➤ Scaling $KIND/$NAME to $REPLICAS replicas..."
    kubectl scale "$KIND/$NAME" -n "$NAMESPACE" --replicas="$REPLICAS"
  done
fi

echo "✅ PVC '$PVC_NAME' successfully migrated to new storage class '$NEW_STORAGE_CLASS'"
