#!/bin/bash

echo "Fetching PVCs with StorageClass: ocs-storagecluster-cephfs..."

# Get all PVCs with storageClassName = ocs-storagecluster-cephfs
mapfile -t cephfs_pvcs < <(oc get pvc --all-namespaces -o json | jq -r '.items[] | select(.spec.storageClassName == "ocs-storagecluster-cephfs") | "\(.metadata.namespace),\(.metadata.name),\(.spec.resources.requests.storage)"')

# Build a PVC map (namespace:name) for quick lookup
declare -A pvc_map
for pvc in "${cephfs_pvcs[@]}"; do
  ns=$(echo "$pvc" | cut -d',' -f1)
  name=$(echo "$pvc" | cut -d',' -f2)
  size=$(echo "$pvc" | cut -d',' -f3)
  pvc_map["$ns/$name"]="$size"
done

echo "Scanning workloads..."

# Helper function to check if workload uses any of the matching PVCs
check_pvcs_in_workload() {
  local kind=$1
  local resource_json
  resource_json=$(oc get "$kind" --all-namespaces -o json)

  echo "$resource_json" | jq -r --arg kind "$kind" '
    .items[] |
    {
      namespace: .metadata.namespace,
      name: .metadata.name,
      volumes: (
        (try .spec.template.spec.volumes // []) +
        (try .spec.volumes // [])  # For DeploymentConfig which may use .spec.volumes
      )
    } |
    select(.volumes != null) |
    . as $workload |
    .volumes[]? |
    select(.persistentVolumeClaim != null) |
    "\($workload.namespace),\($workload.name),\($kind),\(.persistentVolumeClaim.claimName)"
  '
}

# Get workloads and match PVCs
for kind in deployment deploymentconfig statefulset; do
  check_pvcs_in_workload "$kind"
done | while IFS=',' read -r ns name kind pvc_name; do
  key="$ns/$pvc_name"
  if [[ -n "${pvc_map[$key]}" ]]; then
    size="${pvc_map[$key]}"
    echo "$kind,$ns,$name,$pvc_name,$size"
  fi
done | column -t -s','

