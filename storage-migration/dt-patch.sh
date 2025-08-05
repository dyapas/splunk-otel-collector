#!/bin/bash

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <namespace> <deployment_name>"
  exit 1
fi

NAMESPACE="$1"
DEPLOYMENT="$2"

echo "🔹 Updating deployment $DEPLOYMENT in namespace $NAMESPACE..."

PATCH=$(cat <<EOF
{
  "spec": {
    "template": {
      "metadata": {
        "labels": {
          "admission.datadoghq.com/enabled": "true"
        }
      },
      "spec": {
        "nodeSelector": {
          "datadog-agent-nodes": "true"
        }
      }
    }
  }
}
EOF
)

oc -n "$NAMESPACE" patch deployment "$DEPLOYMENT" --type=merge -p "$PATCH"

echo "✅ Successfully updated $DEPLOYMENT"
