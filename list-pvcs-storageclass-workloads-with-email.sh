#!/bin/bash

STORAGE_CLASS="ocs-storagecluster-cephfs"

echo "Fetching PVCs using StorageClass: $STORAGE_CLASS (spec or annotation)..."

# Step 1: Get all PVCs matching storage class via spec or annotation
mapfile -t cephfs_pvcs < <(oc get pvc --all-namespaces -o json | jq -r --arg sc "$STORAGE_CLASS" '
  .items[] |
  select(
    (.spec.storageClassName == $sc) or
    (.metadata.annotations["volume.beta.kubernetes.io/storage-class"] == $sc)
  ) |
  "\(.metadata.namespace),\(.metadata.name),\(.spec.resources.requests.storage)"
')

# Step 2: Build a PVC map (namespace:name) => size
declare -A pvc_map
for pvc in "${cephfs_pvcs[@]}"; do
  ns=$(echo "$pvc" | cut -d',' -f1)
  name=$(echo "$pvc" | cut -d',' -f2)
  size=$(echo "$pvc" | cut -d',' -f3)
  pvc_map["$ns/$name"]="$size"
done

# Step 3: Build namespace label maps for email and manager
declare -A ns_email_map
declare -A ns_manager_map

while IFS=',' read -r ns email manager; do
  ns_email_map["$ns"]="$email"
  ns_manager_map["$ns"]="$manager"
done < <(oc get ns -o json | jq -r '
  .items[] |
  "\(.metadata.name),\(.metadata.labels["project.ocp.com/email"] // "N/A"),\(.metadata.labels["project.ocp.bcbc.com/manager"] // "N/A")"
')

echo "Scanning workloads using CephFS PVCs..."

# Step 4: Extract volumes from workloads
check_pvcs_in_workload() {
  local kind=$1
  oc get "$kind" --all-namespaces -o json | jq -r --arg kind "$kind" '
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

# Step 5: Print header
echo "KIND,NAMESPACE,NAME,PVC,SIZE,TEAM_EMAIL,MANAGER"

# Step 6: Match workloads to PVCs and namespace labels
for kind in deployment deploymentconfig statefulset; do
  check_pvcs_in_workload "$kind"
done | while IFS=',' read -r ns name kind pvc_name; do
  key="$ns/$pvc_name"
  if [[ -n "${pvc_map[$key]}" ]]; then
    size="${pvc_map[$key]}"
    email="${ns_email_map[$ns]:-N/A}"
    manager="${ns_manager_map[$ns]:-N/A}"
    echo "$kind,$ns,$name,$pvc_name,$size,$email,$manager"
  fi
done | column -t -s','

