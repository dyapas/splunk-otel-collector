#!/bin/bash

NAMESPACE=$1
OUTPUT_FILE="images-${NAMESPACE}-$(date +%Y%m%d%H%M%S).csv"

if [[ -z "$NAMESPACE" ]]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

echo "Kind,Workload,ContainerType,ContainerName,Image" > "$OUTPUT_FILE"

process_workload() {
  local kind=$1
  local name=$2

  json=$(oc get $kind $name -n $NAMESPACE -o json)

  # Containers
  echo "$json" | jq -c '.spec.template.spec.containers[]?' | while read c; do
    cname=$(echo $c | jq -r '.name')
    cimage=$(echo $c | jq -r '.image')

    echo "$kind,$name,container,$cname,$cimage" >> "$OUTPUT_FILE"
  done

  # Init Containers
  echo "$json" | jq -c '.spec.template.spec.initContainers[]?' | while read c; do
    cname=$(echo $c | jq -r '.name')
    cimage=$(echo $c | jq -r '.image')

    echo "$kind,$name,initContainer,$cname,$cimage" >> "$OUTPUT_FILE"
  done
}

echo "Collecting Deployments..."
for d in $(oc get deployments -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}'); do
  process_workload "deployment" "$d"
done

echo "Collecting StatefulSets..."
for s in $(oc get statefulsets -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}'); do
  process_workload "statefulset" "$s"
done

echo "CSV generated: $OUTPUT_FILE"
