#!/bin/bash

STORAGE_CLASS="sc_name"
echo -e "NAMESPACE\tPVC_NAME\tSIZE\tPOD\tCONTAINER\tMOUNT_PATH\tACTUAL_USAGE"

# Get all PVCs with the storage class
pvc_list=($(oc get pvc --all-namespaces -o json | jq -r \
  --arg sc "$STORAGE_CLASS" '
    .items[] | select(.spec.storageClassName == $sc) |
    "\(.metadata.namespace)|\(.metadata.name)|\(.spec.resources.requests.storage)"'))

for pvc_info in "${pvc_list[@]}"; do
  ns=$(echo "$pvc_info" | cut -d"|" -f1)
  pvc=$(echo "$pvc_info" | cut -d"|" -f2)
  size=$(echo "$pvc_info" | cut -d"|" -f3)

  # Find all running pods mounting this PVC
  pods=$(oc get pods -n "$ns" -o json | jq -r --arg pvc "$pvc" '
    .items[]
    | select(.status.phase == "Running")
    | select(.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $pvc))
    | .metadata.name')

  if [ -z "$pods" ]; then
    echo -e "$ns\t$pvc\t$size\tNO_POD_FOUND\tN/A\tN/A\tN/A"
    continue
  fi

  pod=""
  container=""
  mount_path=""

  # For the first running pod, find the right container and mount path
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
      break
    fi
  done

  if [ -z "$pod" ] || [ -z "$container" ] || [ -z "$mount_path" ]; then
    echo -e "$ns\t$pvc\t$size\tNO_VALID_MOUNT\tN/A\tN/A\tN/A"
    continue
  fi

  # Try df -h first
  usage=$(oc exec -n "$ns" "$pod" -c "$container" -- sh -c "df -h \"$mount_path\" | awk 'NR==2{print \$3}'" 2>/dev/null)
  # If usage is zero, fallback to du -sh
  if [[ "$usage" == "0"* || -z "$usage" ]]; then
    du_usage=$(oc exec -n "$ns" "$pod" -c "$container" -- sh -c "du -sh \"$mount_path\" 2>/dev/null | awk '{print \$1}'")
    if [ -n "$du_usage" ]; then
      usage="$du_usage (du est.)"
    else
      usage="N/A"
    fi
  fi

  echo -e "$ns\t$pvc\t$size\t$pod\t$container\t$mount_path\t$usage"
done
