#!/bin/bash

OUTPUT_FILE="deployments_report.csv"

# Write CSV header
echo "Namespace,Type,Name,LastDeploymentDate,DeployedBy" > "$OUTPUT_FILE"

# Loop over both Deployments and DeploymentConfigs
for kind in deployment deploymentconfig; do
  oc get $kind --all-namespaces -o json | jq -r --arg kind "$kind" '
    .items[] |
    {
      ns: .metadata.namespace,
      name: .metadata.name,
      type: $kind,
      deploy_time: (
        .spec.template.spec.containers[]
        | select(.env != null)
        | .env[]
        | select(.name == "DEPLOY_TIME")
        | .value // "N/A"
      ),
      deployed_by: (
        .spec.template.spec.containers[]
        | select(.env != null)
        | .env[]
        | select(.name == "DEPLOYED_BY")
        | .value // "N/A"
      )
    } |
    [.ns, .type, .name, .deploy_time, .deployed_by] | @csv
  ' >> "$OUTPUT_FILE"
done

echo "✅ Report generated: $OUTPUT_FILE"
