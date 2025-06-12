#!/bin/bash

# Set the storage class to filter PVCs
STORAGE_CLASS="sc_name"

# Print the header for output
echo -e "NAMESPACE,PVC_NAME,SIZE,POD,MOUNT_PATH,ACTUAL_USAGE"

# Get all PVCs in the cluster using the specified storage class and store them in an array
pvc_list=($(oc get pvc --all-namespaces -o json | jq -r \
  --arg sc "$STORAGE_CLASS" '
    .items[] | select(.spec.storageClassName == $sc) |
    "\(.metadata.namespace)|\(.metadata.name)|\(.spec.resources.requests.storage)"'))

# Iterate through each PVC in the list
for pvc_info in "${pvc_list[@]}"; do
  # Split the PVC info into namespace, name, and size
  ns=$(echo "$pvc_info" | cut -d"|" -f1)
  pvc=$(echo "$pvc_info" | cut -d"|" -f2)
  size=$(echo "$pvc_info" | cut -d"|" -f3)

  # Step 1: Find the first pod that mounts this PVC in the namespace
  pod=$(oc get pods -n "$ns" -o json | jq -r \
    --arg pvc "$pvc" '
      .items[]
      | select(.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $pvc))
      | .metadata.name' | head -n 1)

  # Step 2: If no pod is found, log and move on
  if [ -z "$pod" ]; then
    echo -e "$ns,$pvc,$size,NO_POD_FOUND,N/A,N/A"
    continue
  fi

  # Step 3: Check if the pod is in Running state
  pod_status=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}')
  if [ "$pod_status" != "Running" ]; then
    echo -e "$ns,$pvc,$size,$pod,POD_NOT_RUNNING,N/A"
    continue
  fi

  # Step 4: Find the volume name in the pod spec that matches the PVC
  volume_name=$(oc get pod "$pod" -n "$ns" -o json | jq -r \
    --arg pvc "$pvc" '
      .spec.volumes[]
      | select(.persistentVolumeClaim.claimName == $pvc)
      | .name')

  # Step 5: Find the mount path for this volume in the pod's containers
  mount_path=$(oc get pod "$pod" -n "$ns" -o json | jq -r \
    --arg vn "$volume_name" '
      .spec.containers[].volumeMounts[]
      | select(.name == $vn)
      | .mountPath' | head -n 1)

  if [ -z "$mount_path" ]; then
    echo -e "$ns,$pvc,$size,$pod,NO_MOUNT_PATH,N/A"
    continue
  fi

  # Step 6: Find the first container name in the pod
  container=$(oc get pod "$pod" -n "$ns" -o json | jq -r '.spec.containers[0].name')

  # Step 7: Execute 'df -h' inside the container to get usage of the mount path
  usage=$(oc exec -n "$ns" "$pod" -c "$container" -- df -h "$mount_path" 2>/dev/null | awk 'NR==2{print $3}')
  if [ -z "$usage" ]; then usage="N/A"; fi

  # Step 8: Print the results for this PVC
  echo -e "$ns,$pvc,$size,$pod,$mount_path,$usage"
done
