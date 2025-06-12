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

# ─────────────────────────────────────────────────────────────
# Build PVC map: all CephFS PVCs
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
# Namespace labels (email and manager)
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
# Workload PVCs (Deployments, DeploymentConfigs)
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

for kind in deployment deploymentconfig; do
  check_pvcs_in_workload "$kind"
done > /tmp/_workload_pvcs.txt

# ─────────────────────────────────────────────────────────────
# StatefulSet PVCs (via ownerReferences and label match)
# ─────────────────────────────────────────────────────────────
oc get statefulset --all-namespaces -o json | jq -r '
  .items[] |
  {
    namespace: .metadata.namespace,
    name: .metadata.name,
    tier: (.metadata.labels["app.ocp.com/tier"] // "N/A"),
    volumeClaims: [.spec.volumeClaimTemplates[].metadata.name]
  }
' > /tmp/_statefulsets.json

while IFS= read -r line; do
  ns=$(echo "$line" | jq -r '.namespace')
  sts_name=$(echo "$line" | jq -r '.name')
  tier=$(echo "$line" | jq -r '.tier')
  for claim in $(echo "$line" | jq -r '.volumeClaims[]'); do
    # Get all matching PVCs for this StatefulSet's volume claim
    oc get pvc -n "$ns" -o json | jq -r --arg claim "$claim" --arg sts "$sts_name" --arg tier "$tier" '
      .items[] |
      select(.metadata.name | test("^" + $claim + "-" + $sts + "-[0-9]+$")) |
      select(.metadata.ownerReferences[].kind == "StatefulSet") |
      "\(.metadata.namespace),\($sts),statefulset,\(.metadata.name),\($tier)"
    ' >> /tmp/_workload_pvcs.txt
  done
done < /tmp/_statefulsets.json

# ─────────────────────────────────────────────────────────────
# Final Output
# ─────────────────────────────────────────────────────────────
while IFS=',' read -r ns name kind pvc_name tier; do
  key="$ns/$pvc_name"
  if [[ -n "${pvc_map[$key]:-}" ]]; then
    size="${pvc_map[$key]}"
    email="${ns_email_map[$ns]:-N/A}"
    manager="${ns_manager_map[$ns]:-N/A}"
    echo "$kind,$ns,$name,$pvc_name,$size,$email,$manager,$tier" >> "$REPORT_FILE"
  fi
done < /tmp/_workload_pvcs.txt

# ─────────────────────────────────────────────────────────────
# Email Report
# ─────────────────────────────────────────────────────────────
SUBJECT="CephFS PVC Usage Report - $CLUSTER_NAME - $(date +%F)"
TO_EMAIL="${TO_EMAIL:-alerts@example.com}"

echo "Please find the attached CephFS PVC usage report for $CLUSTER_NAME." | mailx \
  -s "$SUBJECT" \
  -a "$REPORT_FILE" \
  "$TO_EMAIL"
