#!/bin/bash

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Validate Input: Cluster Name
# ─────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <CLUSTER_NAME>"
  exit 1
fi

CLUSTER_NAME="$1"
STORAGE_CLASS="ocs-storagecluster-cephfs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="/tmp/cephfs_report_${CLUSTER_NAME}_${TIMESTAMP}.csv"

# ─────────────────────────────────────────────────────────────
# CSV Header
# ─────────────────────────────────────────────────────────────
echo "KIND,NAMESPACE,NAME,PVC,SIZE,TEAM_EMAIL,MANAGER,TIER" > "$REPORT_FILE"

# ─────────────────────────────────────────────────────────────
# Build PVC map (filtering for CephFS StorageClass + annotation)
# ─────────────────────────────────────────────────────────────
declare -A pvc_map
mapfile -t cephfs_pvcs < <(oc get pvc --all-namespaces -o json | jq -r --arg sc "$STORAGE_CLASS" '
  .items[] |
  select(
    (.spec.storageClassName == $sc) or
    (.metadata.annotations["volume.beta.kubernetes.io/storage-class"] == $sc)
  ) |
  "\(.metadata.namespace),\(.metadata.name),\(.spec.resources.requests.storage)"
')

for pvc in "${cephfs_pvcs[@]}"; do
  ns=$(cut -d',' -f1 <<< "$pvc")
  name=$(cut -d',' -f2 <<< "$pvc")
  size=$(cut -d',' -f3 <<< "$pvc")
  pvc_map["$ns/$name"]="$size"
done

# ─────────────────────────────────────────────────────────────
# Get email and manager from namespace labels
# ─────────────────────────────────────────────────────────────
declare -A ns_email_map
declare -A ns_manager_map
while read -r ns_json; do
  ns=$(echo "$ns_json" | jq -r '.metadata.name')
  email=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.com/email"] // "N/A"')
  manager=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.bcbc.com/manager"] // "N/A"')
  ns_email_map["$ns"]="$email"
  ns_manager_map["$ns"]="$manager"
done < <(oc get ns -o json | jq -c '.items[]')

# ─────────────────────────────────────────────────────────────
# Extract PVCs from workloads and tier labels
# ─────────────────────────────────────────────────────────────
check_pvcs_in_workload() {
  local kind=$1
  oc get "$kind" --all-namespaces -o json | jq -r --arg kind "$kind" '
    .items[] |
    {
      namespace: .metadata.namespace,
      name: .metadata.name,
      tier: (.metadata.labels["app.ocp.com/tier"] // "N/A"),
      volumes: (
        (try .spec.template.spec.volumes // []) +
        (try .spec.volumes // [])
      )
    } |
    select(.volumes != null) |
    . as $workload |
    .volumes[]? |
    select(.persistentVolumeClaim != null) |
    "\($workload.namespace),\($workload.name),\($kind),\(.persistentVolumeClaim.claimName),\($workload.tier)"
  '
}

# ─────────────────────────────────────────────────────────────
# Process All Workloads
# ─────────────────────────────────────────────────────────────
for kind in deployment deploymentconfig statefulset; do
  check_pvcs_in_workload "$kind"
done | while IFS=',' read -r ns name kind pvc_name tier; do
  key="$ns/$pvc_name"
  if [[ -n "${pvc_map[$key]:-}" ]]; then
    size="${pvc_map[$key]}"
    email="${ns_email_map[$ns]:-N/A}"
    manager="${ns_manager_map[$ns]:-N/A}"
    echo "$kind,$ns,$name,$pvc_name,$size,$email,$manager,$tier" >> "$REPORT_FILE"
  fi
done

# ─────────────────────────────────────────────────────────────
# Email Report
# ─────────────────────────────────────────────────────────────
SUBJECT="CephFS PVC Usage Report - $CLUSTER_NAME - $(date +%F)"
TO_EMAIL="${TO_EMAIL:-alerts@example.com}"

echo "Please find the attached CephFS PVC usage report for $CLUSTER_NAME." | mailx \
  -s "$SUBJECT" \
  -a "$REPORT_FILE" \
  "$TO_EMAIL"
