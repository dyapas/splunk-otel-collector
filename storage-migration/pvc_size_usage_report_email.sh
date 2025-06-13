#!/bin/bash

# Usage: ./pvc_usage_report.sh <clusterName>
# Example: ./pvc_usage_report.sh mycluster

if [ $# -ne 1 ]; then
  echo "Usage: $0 <clusterName>"
  exit 1
fi

CLUSTER_NAME="$1"
TO_EMAIL="abc@xyz.com"
FROM_EMAIL="noreply@xyz.com"    # Change as needed
STORAGE_CLASS="storageClassName"
SUBJECT="PVC Usage Report for Cluster $CLUSTER_NAME for the storageClass $STORAGE_CLASS"
REPORT_FILE="pvc_usage_report_${CLUSTER_NAME}_$(date +%Y%m%d).csv"

# Print CSV header to the report file
echo "ClusterName,Namespace,PVC_Name,Size,Pod,Container,Mount_Path,Pod_Status,Actual_Usage" > "$REPORT_FILE"

# Get all PVCs with the storage class
pvc_list=($(oc get pvc --all-namespaces -o json | jq -r \
  --arg sc "$STORAGE_CLASS" '
    .items[] | select(.spec.storageClassName == $sc) |
    "\(.metadata.namespace)|\(.metadata.name)|\(.spec.resources.requests.storage)"'))

for pvc_info in "${pvc_list[@]}"; do
  ns=$(echo "$pvc_info" | cut -d"|" -f1)
  pvc=$(echo "$pvc_info" | cut -d"|" -f2)
  size=$(echo "$pvc_info" | cut -d"|" -f3)

  # Find all pods mounting this PVC
  pods=$(oc get pods -n "$ns" -o json | jq -r --arg pvc "$pvc" '
    .items[]
    | select(.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $pvc))
    | .metadata.name')

  if [ -z "$pods" ]; then
    echo "$CLUSTER_NAME,$ns,$pvc,$size,NO_POD_FOUND,N/A,N/A,N/A,N/A"| tee -a "$REPORT_FILE"
    continue
  fi

  pod=""
  container=""
  mount_path=""
  pod_status=""

  # For the first pod that mounts this PVC, check all containers for the mount path
  for pod_candidate in $pods; do
    pod_json=$(oc get pod "$pod_candidate" -n "$ns" -o json)
    volume_name=$(echo "$pod_json" | jq -r --arg pvc "$pvc" '
      .spec.volumes[]
      | select(.persistentVolumeClaim.claimName == $pvc)
      | .name')

    # Search all containers for the mount
    container_found=""
    mount_path_found=""
    containers=$(echo "$pod_json" | jq -r '.spec.containers[].name')
    for cont in $containers; do
      mp=$(echo "$pod_json" | jq -r --arg cont "$cont" --arg vn "$volume_name" '
        .spec.containers[] | select(.name == $cont) | .volumeMounts[]?
        | select(.name == $vn)
        | .mountPath' | head -n 1)
      if [ -n "$mp" ]; then
        container_found="$cont"
        mount_path_found="$mp"
        break
      fi
    done

    if [ -n "$container_found" ] && [ -n "$mount_path_found" ]; then
      pod="$pod_candidate"
      container="$container_found"
      mount_path="$mount_path_found"
      pod_status=$(echo "$pod_json" | jq -r '.status.phase')
      break
    fi
  done

  if [ -z "$pod" ] || [ -z "$container" ] || [ -z "$mount_path" ]; then
    echo "$CLUSTER_NAME,$ns,$pvc,$size,NO_VALID_MOUNT,N/A,N/A,N/A,N/A"| tee -a "$REPORT_FILE"
    continue
  fi

  # If pod is not running, print status and skip usage check
  if [ "$pod_status" != "Running" ]; then
    echo "$CLUSTER_NAME,$ns,$pvc,$size,$pod,$container,$mount_path,$pod_status,N/A"| tee -a "$REPORT_FILE"
    continue
  fi

  # Try df -h first
  usage=$(oc exec -n "$ns" "$pod" -c "$container" -- sh -c "df -h \"$mount_path\" | awk 'NR==2{print \$3}'" 2>/dev/null)
  # If usage is zero or blank, fallback to du -sh
  if [[ "$usage" == "0"* || -z "$usage" ]]; then
    du_usage=$(oc exec -n "$ns" "$pod" -c "$container" -- sh -c "du -sh \"$mount_path\" 2>/dev/null | awk '{print \$1}'")
    if [ -n "$du_usage" ]; then
      usage="$du_usage"
    else
      usage="N/A"
    fi
  fi

  echo "$CLUSTER_NAME,$ns,$pvc,$size,$pod,$container,$mount_path,$pod_status,$usage"| tee -a "$REPORT_FILE"
done

echo "Report written to $REPORT_FILE"

# Send the report as an email attachment using mailx
echo "PVC usage report for cluster $CLUSTER_NAME." | mailx -r "$FROM_EMAIL" -s "$SUBJECT" -a "$REPORT_FILE" "$TO_EMAIL"
if [ $? -eq 0 ]; then
  echo "Report sent to $TO_EMAIL"
else
  echo "Failed to send report to $TO_EMAIL"
fi
