#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

NAMESPACE=$1
OUTPUT_FILE="images-${NAMESPACE}-$(date +%Y%m%d%H%M%S).csv"

if [[ -z "${NAMESPACE:-}" ]]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

# Check dependencies
command -v oc >/dev/null || { echo "oc not found"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

echo "Kind,Workload,ContainerType,ContainerName,Image" > "$OUTPUT_FILE"

echo "Fetching all workloads in one call..."

# Fetch once (avoids repeated API calls)
ALL_JSON=$(oc get deploy,statefulset -n "$NAMESPACE" -o json)

echo "$ALL_JSON" | jq -c '.items[]' | while read -r item; do

  KIND=$(echo "$item" | jq -r '.kind' | tr '[:upper:]' '[:lower:]')
  NAME=$(echo "$item" | jq -r '.metadata.name')

  # Containers
  echo "$item" | jq -c '.spec.template.spec.containers[]?' | while read -r c; do
    CNAME=$(echo "$c" | jq -r '.name // "NA"')
    CIMAGE=$(echo "$c" | jq -r '.image // "NA"')

    echo "$KIND,$NAME,container,$CNAME,$CIMAGE" >> "$OUTPUT_FILE"
  done

  # InitContainers (safe even if absent)
  echo "$item" | jq -c '.spec.template.spec.initContainers[]?' | while read -r c; do
    CNAME=$(echo "$c" | jq -r '.name // "NA"')
    CIMAGE=$(echo "$c" | jq -r '.image // "NA"')

    echo "$KIND,$NAME,initContainer,$CNAME,$CIMAGE" >> "$OUTPUT_FILE"
  done

done

echo "✅ CSV generated: $OUTPUT_FILE"
