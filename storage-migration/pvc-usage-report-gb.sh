#!/bin/bash
set -euo pipefail

STORAGE_CLASS="ocs-storagecluster-cephfs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="/tmp/pvc_usage_report_${TIMESTAMP}.csv"

echo "NAMESPACE,PVC_NAME,SIZE,USED(GB)" > "$REPORT_FILE"

# Step 1: Get all PVCs with the desired storage class
mapfile -t cephfs_pvcs < <(oc get pvc --all-namespaces -o json | jq -r --arg sc "$STORAGE_CLASS" '
  .items[] |
  select(
    (.spec.storageClassName == $sc) or
    (.metadata.annotations["volume.beta.kubernetes.io/storage-class"] == $sc)
  ) |
  "\(.metadata.namespace),\(.metadata.name),\(.spec.resources.requests.storage)"
')

# Step 2: Function to get actual usage in GB
get_pvc_usage_from_pod() {
  local ns="$1"
  local pvc="$2"
  local usage="N/A"

  pod=$(oc get pod -n "$ns" -o json | jq -r --arg pvc "$pvc" '
    .items[] |
    select(.status.phase == "Running") |
    select(.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $pvc)) |
    .metadata.name' | head -n1)

  if [[ -n "$pod" ]]; then
    for container in $(oc get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}'); do
      mount_path=$(oc get pod "$pod" -n "$ns" -o json | jq -r --arg pvc "$pvc" '
        .spec.volumes[] |
        select(.persistentVolumeClaim.claimName == $pvc) |
        .name' | xargs -I{} jq -r --arg name "{}" '
        .spec.containers[].volumeMounts[]? |
        select(.name == $name) |
        .mountPath' < <(oc get pod "$pod" -n "$ns" -o json))

      if [[ -n "$mount_path" ]]; then
        usage_bytes=$(oc exec -n "$ns" "$pod" -c "$container" -- df -B1 "$mount_path" 2>/dev/null | awk 'NR==2 { print $3 }')
        if [[ "$usage_bytes" =~ ^[0-9]+$ ]]; then
          usage=$(awk -v b="$usage_bytes" 'BEGIN { printf "%.2f", b / (1024*1024*1024) }')
        fi
        break
      fi
    done
  fi

  echo "$usage"
}

# Step 3: Build report
for pvc_line in "${cephfs_pvcs[@]}"; do
  ns=$(cut -d',' -f1 <<< "$pvc_line")
  pvc=$(cut -d',' -f2 <<< "$pvc_line")
  size=$(cut -d',' -f3 <<< "$pvc_line")
  used=$(get_pvc_usage_from_pod "$ns" "$pvc")
  echo "$ns,$pvc,$size,$used" >> "$REPORT_FILE"
done

echo "Report saved to: $REPORT_FILE"
