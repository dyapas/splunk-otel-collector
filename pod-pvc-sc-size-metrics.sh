#!/bin/bash

OUTPUT_FILE="pvc-workload-report.csv"
echo "Namespace,Workload Type,Workload Name,PVC Name,Storage Requested" > "$OUTPUT_FILE"

# Loop through all namespaces
for ns in $(oc get ns --no-headers -o custom-columns=":metadata.name"); do
  # Check Deployments
  for deploy in $(oc get deploy -n $ns --no-headers -o custom-columns=":metadata.name"); do
    oc get deploy "$deploy" -n "$ns" -o json |
    jq -r --arg ns "$ns" --arg workload "$deploy" '
      .spec.template.spec.volumes[]? 
      | select(.persistentVolumeClaim != null) 
      | [$ns, "Deployment", $workload, .persistentVolumeClaim.claimName] 
      | @csv' |
    while IFS=',' read -r namespace type name pvc; do
      storage=$(oc get pvc "$pvc" -n "$namespace" -o jsonpath="{.spec.resources.requests.storage}" 2>/dev/null)
      echo "$namespace,$type,$name,$pvc,$storage" >> "$OUTPUT_FILE"
    done
  done

  # Check DeploymentConfigs
  for dc in $(oc get dc -n $ns --no-headers -o custom-columns=":metadata.name"); do
    oc get dc "$dc" -n "$ns" -o json |
    jq -r --arg ns "$ns" --arg workload "$dc" '
      .spec.template.spec.volumes[]? 
      | select(.persistentVolumeClaim != null) 
      | [$ns, "DeploymentConfig", $workload, .persistentVolumeClaim.claimName] 
      | @csv' |
    while IFS=',' read -r namespace type name pvc; do
      storage=$(oc get pvc "$pvc" -n "$namespace" -o jsonpath="{.spec.resources.requests.storage}" 2>/dev/null)
      echo "$namespace,$type,$name,$pvc,$storage" >> "$OUTPUT_FILE"
    done
  done

  # Check StatefulSets
  for sts in $(oc get sts -n $ns --no-headers -o custom-columns=":metadata.name"); do
    oc get sts "$sts" -n "$ns" -o json |
    jq -r --arg ns "$ns" --arg workload "$sts" '
      .spec.volumeClaimTemplates[]? 
      | [$ns, "StatefulSet", $workload, .metadata.name] 
      | @csv' |
    while IFS=',' read -r namespace type name pvc_template; do
      for pvc in $(oc get pvc -n "$namespace" -o json | jq -r --arg base "$pvc_template" --arg sts "$name" '.items[] | select(.metadata.name | startswith($base + "-" + $sts)) | .metadata.name'); do
        storage=$(oc get pvc "$pvc" -n "$namespace" -o jsonpath="{.spec.resources.requests.storage}" 2>/dev/null)
        echo "$namespace,$type,$name,$pvc,$storage" >> "$OUTPUT_FILE"
      done
    done
  done
done

echo "Report saved to $OUTPUT_FILE"