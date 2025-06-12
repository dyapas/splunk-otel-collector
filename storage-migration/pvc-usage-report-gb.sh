#!/bin/bash
set -euo pipefail

STORAGE_CLASS="ocs-storagecluster-cephfs"
REPORT_FILE="pvc_usage_report_$(date +%Y%m%d_%H%M%S).csv"

echo "Namespace,PVC Name,Requested Size,Actual Usage,StorageClass" > "$REPORT_FILE"

echo "🔍 Scanning for PVCs using storage class: $STORAGE_CLASS ..."

ALL_PVCS=$(oc get pvc --all-namespaces -o json)

echo "$ALL_PVCS" | jq -c '.items[]' | while read -r pvc; do
  NS=$(echo "$pvc" | jq -r '.metadata.namespace')
  PVC_NAME=$(echo "$pvc" | jq -r '.metadata.name')
  REQUESTED_SIZE=$(echo "$pvc" | jq -r '.spec.resources.requests.storage')
  
  # Determine actual storage class
  SC=$(echo "$pvc" | jq -r '.spec.storageClassName // empty')
  if [[ -z "$SC" || "$SC" == "null" ]]; then
    SC=$(echo "$pvc" | jq -r '.metadata.annotations["volume.beta.kubernetes.io/storage-class"] // empty')
  fi

  [[ "$SC" != "$STORAGE_CLASS" ]] && continue

  # Find pod using this PVC
  POD=$(oc get pod -n "$NS" -o json | jq -r --arg PVC "$PVC_NAME" '
    .items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $PVC) | .metadata.name' | head -n1)

  if [[ -z "$POD" ]]; then
    echo "⚠️ $NS/$PVC_NAME not mounted to any pod."
    echo "$NS,$PVC_NAME,$REQUESTED_SIZE,N/A,$SC" >> "$REPORT_FILE"
    continue
  fi

  CONTAINER=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.containers[0].name}')

  # Get volume name associated with PVC
  VOLUME_NAME=$(oc get pod "$POD" -n "$NS" -o json | jq -r \
    --arg PVC "$PVC_NAME" \
    '.spec.volumes[] | select(.persistentVolumeClaim.claimName == $PVC) | .name')

  if [[ -z "$VOLUME_NAME" ]]; then
    echo "⚠️ $NS/$PVC_NAME: Volume name not found in pod."
    echo "$NS,$PVC_NAME,$REQUESTED_SIZE,N/A,$SC" >> "$REPORT_FILE"
    continue
  fi

  # Get mount path using volume name
  MOUNT_PATH=$(oc get pod "$POD" -n "$NS" -o json | jq -r \
    --arg VOL "$VOLUME_NAME" \
    '.spec.containers[].volumeMounts[] | select(.name == $VOL) | .mountPath' | head -n1)

  if [[ -z "$MOUNT_PATH" ]]; then
    echo "⚠️ $NS/$PVC_NAME: Mount path not found in pod container."
    echo "$NS,$PVC_NAME,$REQUESTED_SIZE,N/A,$SC" >> "$REPORT_FILE"
    continue
  fi

  # Get actual usage via df -h on the mount path
  ACTUAL_USAGE=$(oc exec -n "$NS" "$POD" -c "$CONTAINER" -- df -h "$MOUNT_PATH" 2>/dev/null | awk 'NR==2{print $3}' || echo "N/A")

  echo "✅ $NS/$PVC_NAME - Usage: $ACTUAL_USAGE at $MOUNT_PATH"
  echo "$NS,$PVC_NAME,$REQUESTED_SIZE,$ACTUAL_USAGE,$SC" >> "$REPORT_FILE"
done

echo "📄 Report saved to: $REPORT_FILE"
