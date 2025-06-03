#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <CLUSTER_NAME>"
  exit 1
fi

CLUSTER_NAME="$1"
STORAGE_CLASS="ocs-storagecluster-cephfs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="/tmp/cephfs_report_${CLUSTER_NAME}_${TIMESTAMP}.csv"

echo "KIND,NAMESPACE,NAME,PVC,SIZE,TEAM_EMAIL,MANAGER,TIER" > "$REPORT_FILE"

# Build PVC map
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

# Namespace labels: email + manager
declare -A ns_email_map
declare -A ns_manager_map
while read -r ns_json; do
  ns=$(echo "$ns_json" | jq -r '.metadata.name')
  email=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.com/email"] // "N/A"')
  manager=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.bcbc.com/manager"] // "N/A"')
  ns
