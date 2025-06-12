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

echo "KIND,NAMESPACE,NAME,PVC,SIZE,USED(BYTES),TEAM_EMAIL,MANAGER,TIER" > "$REPORT_FILE"

# Step 1: Get all PVCs with the given storage class or annotation
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

# Step 2: Get email and manager label per namespace
declare -A ns_email_map
declare -A ns_manager_map
while read -r ns_json; do
  ns=$(echo "$ns_json" | jq -r '.metadata.name')
  email=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.com/email"] // "N/A"')
  manager=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.bcbc.com/manager"] // "N/A"')
  ns_email_map["$ns"]="$email"
  ns_manager_map["$ns"]="$manager"
done < <(oc get ns -o json | jq -c '.items[]')

# Step 3: Gather workloads using PVCs (Deployments & DeploymentConfigs)
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
    . as $w |
    .volumes[]? |
    select(.persistentVolumeClaim != null) |
    "\($w.namespace),\($w.name),\($kind),\(.persistentVolumeClaim.claimName),\($w.tier)"
  '
}
for kind in deployment deploymentconfig; do
  check_pvcs_in_workload "$kind"
done > /tmp/_workload_pvcs.txt

# Step 4: Handle StatefulSet PVCs
mapfile -t statefulsets < <(oc get statefulset --all-namespaces -o json | jq -c '
  .items[] | {
    namespace: .metadata.namespace,
    name: .metadata.name,
    tier: (.metadata.labels["app.ocp.com/tier"] // "N/A"),
    volumeClaims: [.spec.volumeClaimTemplates[].metadata.name]
  }
')

for sts in "${statefulsets[@]}"; do
  ns=$(jq -r '.namespace' <<< "$sts")
  sts_name=$(jq -r '.name' <<< "$sts")
  tier=$(jq -r '.tier' <<< "$sts")
  mapfile -t claims < <(jq -r '.volumeClaims[]' <<< "$sts")

  for claim in "${claims[@]}"; do
    mapfile -t pvc_list < <(oc get pvc -n "$ns" -o json | jq -r --arg claim "$claim" --arg sts "$sts_name" '
      .items[] |
      select(.metadata.name | test("^" + $claim + "-" + $sts + "-[0-9]+$")) |
      select((.metadata.ownerReferences[]?.kind // "") == "StatefulSet") |
      .metadata.name
    ')
    for pvc_name in "${pvc_list[@]}"; do
      echo "$ns,$sts_name,statefulset,$pvc_name,$tier" >> /tmp/_workload_pvcs.txt
    done
  done
done

# Step 5: Function to get PVC usage by exec'ing into pod
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
        usage=$(oc exec -n "$ns" "$pod" -c "$container" -- df -B1 "$mount_path" 2>/dev/null | awk 'NR==2 { print $3 }')
        break
      fi
    done
  fi
  echo "$usage"
}

# Step 6: Final Report
while IFS=',' read -r ns name kind pvc_name tier; do
  key="$ns/$pvc_name"
  if [[ -n "${pvc_map[$key]:-}" ]]; then
    size="${pvc_map[$key]}"
    email="${ns_email_map[$ns]:-N/A}"
    manager="${ns_manager_map[$ns]:-N/A}"
    used=$(get_pvc_usage_from_pod "$ns" "$pvc_name")
    echo "$kind,$ns,$name,$pvc_name,$size,$used,$email,$manager,$tier" >> "$REPORT_FILE"
  fi
done < /tmp/_workload_pvcs.txt

# Step 7: Email Report
SUBJECT="CephFS PVC Usage Report - $CLUSTER_NAME - $(date +%F)"
TO_EMAIL="${TO_EMAIL:-alerts@example.com}"
echo "Please find the attached CephFS PVC usage report for $CLUSTER_NAME." | mailx \
  -s "$SUBJECT" \
  -a "$REPORT_FILE" \
  "$TO_EMAIL"
