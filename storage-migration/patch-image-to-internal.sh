#!/bin/bash

NAMESPACE=$1
CSV_FILE=$2
MODE=${3:-dry-run}   # dry-run | apply

INTERNAL_REG="quay-abc.com"
REPO="sso/bigid"

if [[ -z "$NAMESPACE" || -z "$CSV_FILE" ]]; then
  echo "Usage: $0 <namespace> <csv-file> [dry-run|apply]"
  exit 1
fi

echo "Namespace: $NAMESPACE"
echo "Mode: $MODE"
echo "----------------------------------------"

# ----------------------------------------
# Transform image
# ----------------------------------------
transform_image() {
  local image=$1

  # Remove registry prefix if present
  # Examples:
  # docker.io/bigid/redis:8 → bigid/redis:8
  # quay.io/... → remove
  image=$(echo "$image" | sed -E 's|^[^/]+/||')

  # Remove duplicate repo prefix if exists
  image=$(echo "$image" | sed -E 's|^bigid/||')

  # Final format
  echo "$INTERNAL_REG/$REPO/$image"
}

# ----------------------------------------
# Process CSV
# ----------------------------------------
tail -n +2 "$CSV_FILE" | while IFS=',' read -r kind workload ctype cname old_image; do

  new_image=$(transform_image "$old_image")

  # Skip if already correct
  if [[ "$old_image" == "$new_image" ]]; then
    continue
  fi

  echo "----------------------------------------"
  echo "$kind/$workload"
  echo "Container: $cname"
  echo "OLD: $old_image"
  echo "NEW: $new_image"

  if [[ "$MODE" == "apply" ]]; then
    oc set image "$kind/$workload" "$cname=$new_image" -n "$NAMESPACE"
  fi

done

echo "----------------------------------------"
echo "Done."
