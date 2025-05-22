#!/bin/bash

echo "Fetching PVCs with StorageClass: ocs-storagecluster-cephfs..."

# Get all PVCs with storageClassName = ocs-storagecluster-cephfs
mapfile -t cephfs_pvcs < <(oc get pvc --all-namespaces -o json | jq -r '
  .items[] |
  select(.spec.storageClassName == "ocs-storagecluster-cephfs") |
  "\(.metadata.namespace),\(.metadata.name),\(.spec.resources.requests.storage)"')

# Build a PVC map (namespace:name) for quick lookup
declare -A pvc_map
for pvc in "${cephfs_pvcs[@]}"; do
  ns=$(echo "$pvc" | cut -d',' -f1)
  name=$(echo "$pvc" | cut -d',' -f2)
  size=$(echo "$pvc" | cut -d',' -f3)
  pvc_map["$ns/$name"]="$size"
done

# Build namespace -> email map
declare -A ns_email_map
while IFS= read -r line; do
  ns=$(echo "$line" | cut -d',' -f1)
  email=$(echo "$line" | cut -d',' -f2)
  ns_email_map["$ns"]="$email"
done < <(oc get ns -o json | jq -r '.items[] | "\(.metadata.name),\(.metadata.labels["project.ocp.com/email"] // "N/A")"')

echo "Scanning workloads..."

# Function to scan workloads and link to PVCs
check_pvcs_in_workload() {
  local kind=$1
  local json
  json=$(oc get "$kind" --all-namespaces -o json)

  echo "$json" | jq -r --arg kind "$kind" '
    .items[] |
    {
      namespace: .metadata.namespace,
      name: .metadata.name,
      volumes: (
        (try .spec.template.spec.volumes // []) +
        (try .spec.volumes // [])
      )
    } |
    select(.volumes != null) |
    . as $workload |
    .volumes[]? |
    select(.persistentVolumeClaim != null) |
    "\($workload.namespace),\($workload.name),\($kind),\(.persistentVolumeClaim.claimName)"
  '
}

# Header
echo "KIND,NAMESPACE,NAME,PVC,SIZE,TEAM_EMAIL"

# Find matching workloads
for kind in deployment deploymentconfig statefulset; do
  check_pvcs_in_workload "$kind"
done | while IFS=',' read -r ns name kind pvc_name; do
  key="$ns/$pvc_name"
  if [[ -n "${pvc_map[$key]}" ]]; then
    size="${pvc_map[$key]}"
    email="${ns_email_map[$ns]:-N/A}"
    echo "$kind,$ns,$name,$pvc_name,$size,$email"
  fi
done | column -t -s','

