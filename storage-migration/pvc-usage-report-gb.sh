#!/bin/bash
set -euo pipefail

STORAGE_CLASS="ocs-storagecluster-cephfs"
REPORT_FILE="pvc_usage_report_$(date +%Y%m%d_%H%M%S).csv"

echo "Namespace,PVC Name,Requested Size,Actual Usage,StorageClass" > "$REPORT_FILE"

echo "Scanning PVCs using $STORAGE_CLASS storage class..."

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
  POD=$(oc get pod -n "$NS" -o json | jq -r --arg PVC "$PVC_NAME" \
    '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $PVC) | .metadata.name' | head -n1)

  if [[ -z "$POD" ]]; then
    echo "$NS/$PVC_NAME is not mounted in any pod."
    echo "$NS,$PVC_NAME,$REQUESTED_SIZE,N/A,$SC" >> "$REPORT_FILE"
    continue
  fi

  # Get container name
  CONTAINER=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.containers[0].name}')

  # Try to get actual usage using `df -h`
  ACTUAL_USAGE=$(oc exec -n "$NS" "$POD" -c "$CONTAINER" -- df -h | grep /dev | awk 'NR==1{print $3}' 2>/dev/null || echo "N/A")

  echo "$NS,$PVC_NAME,$REQUESTED_SIZE,$ACTUAL_USAGE,$SC" >> "$REPORT_FILE"
done

echo "✅ PVC usage report saved to: $REPORT_FILE"
