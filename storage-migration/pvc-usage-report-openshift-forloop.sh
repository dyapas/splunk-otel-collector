#!/bin/bash
set -euo pipefail

STORAGE_CLASS="ocs-storagecluster-cephfs"
REPORT_FILE="pvc_usage_report_$(date +%Y%m%d_%H%M%S).csv"

echo "Namespace,PVC Name,Requested Size,Actual Usage,StorageClass,App Tier,Team Email,Manager" > "$REPORT_FILE"

echo "🔍 Building namespace email/manager label map..."

# Step 1: Load namespace labels into maps
declare -A ns_email_map
declare -A ns_manager_map

while read -r ns_json; do
  ns=$(echo "$ns_json" | jq -r '.metadata.name')
  email=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.com/email"] // "N/A"')
  manager=$(echo "$ns_json" | jq -r '.metadata.labels["project.ocp.bcbc.com/manager"] // "N/A"')
  ns_email_map["$ns"]="$email"
  ns_manager_map["$ns"]="$manager"
done < <(oc get ns -o json | jq -c '.items[]')

echo "🔍 Scanning PVCs using storage class: $STORAGE_CLASS ..."

# Step 2: Loop through all PVCs
PVC_LIST=$(oc get pvc --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{";"}{.metadata.name}{"\n"}{end}')

IFS=$'\n'
for line in $PVC_LIST; do
  NS=$(echo "$line" | cut -d';' -f1)
  PVC_NAME=$(echo "$line" | cut -d';' -f2)

  PVC_JSON=$(oc get pvc "$PVC_NAME" -n "$NS" -o json)
  REQUESTED_SIZE=$(echo "$PVC_JSON" | jq -r '.spec.resources.requests.storage')

  # Get storage class from spec or annotation
  SC_SPEC=$(echo "$PVC_JSON" | jq -r '.spec.storageClassName // empty')
  SC_ANNOTATION=$(echo "$PVC_JSON" | jq -r '.metadata.annotations["volume.beta.kubernetes.io/storage-class"] // empty')

  if [[ "$SC_SPEC" != "$STORAGE_CLASS" && "$SC_ANNOTATION" != "$STORAGE_CLASS" ]]; then
    continue
  fi

  SC="${SC_SPEC:-$SC_ANNOTATION}"

  # Find a pod using this PVC
  POD=$(oc get pod -n "$NS" -o json | jq -r --arg PVC "$PVC_NAME" '
    .items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $PVC) | .metadata.name' | head -n1)

  if [[ -z "$POD" ]]; then
    USAGE_NOTE="Not mounted to any pod"
    echo "⚠️  $NS/$PVC_NAME: $USAGE_NOTE"
    echo "$NS,$PVC_NAME,$REQUESTED_SIZE,$USAGE_NOTE,$SC,N/A,${ns_email_map[$NS]},${ns_manager_map[$NS]}" >> "$REPORT_FILE"
    continue
  fi

  CONTAINER=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.containers[0].name}')

  # Get volume name for this PVC in the pod
  VOLUME_NAME=$(oc get pod "$POD" -n "$NS" -o json | jq -r --arg PVC "$PVC_NAME" '
    .spec.volumes[] | select(.persistentVolumeClaim.claimName == $PVC) | .name')

  # Get mount path using volume name
  MOUNT_PATH=$(oc get pod "$POD" -n "$NS" -o json | jq -r --arg VOL "$VOLUME_NAME" '
    .spec.containers[].volumeMounts[] | select(.name == $VOL) | .mountPath' | head -n1)

  if [[ -z "$MOUNT_PATH" ]]; then
    USAGE_NOTE="Mount path not found in pod"
    echo "⚠️  $NS/$PVC_NAME: $USAGE_NOTE"
    echo "$NS,$PVC_NAME,$REQUESTED_SIZE,$USAGE_NOTE,$SC,N/A,${ns_email_map[$NS]},${ns_manager_map[$NS]}" >> "$REPORT_FILE"
    continue
  fi

  # Run df -h to get actual usage
  ACTUAL_USAGE=$(oc exec -n "$NS" "$POD" -c "$CONTAINER" -- df -h "$MOUNT_PATH" 2>/dev/null | awk 'NR==2{print $3}' || echo "Error reading usage")

  # Get app tier from pod label
  TIER=$(oc get pod "$POD" -n "$NS" -o json | jq -r '.metadata.labels["app.ocp.com/tier"] // "N/A"')

  echo "✅ $NS/$PVC_NAME - Usage: $ACTUAL_USAGE - Tier: $TIER"
  echo "$NS,$PVC_NAME,$REQUESTED_SIZE,$ACTUAL_USAGE,$SC,$TIER,${ns_email_map[$NS]},${ns_manager_map[$NS]}" >> "$REPORT_FILE"
done

echo "📄 Report saved to: $REPORT_FILE"
