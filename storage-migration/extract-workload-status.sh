#!/bin/bash

# Usage: ./extract-workload-status.sh <cluster-name>
# Example: ./extract-workload-status.sh prod-cluster

CLUSTER_NAME="$1"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: Cluster name is required."
  echo "Usage: $0 <cluster-name>"
  exit 1
fi

OUTPUT_FILE="workload-status-$CLUSTER_NAME.csv"

echo "cluster,namespace,manager,domain,team_email,workload_type,workload_name,status" > "$OUTPUT_FILE"

# Get all non-system namespaces
namespaces=$(oc get ns --no-headers | awk '!/openshift/ && !/kube/ {print $1}')

for ns in $namespaces; do

  # Extract namespace-level labels
  manager=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.project\.ocp\.bcbc\.com/manager}' 2>/dev/null)
  domain=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.project\.ocp\.abc\.com/domain}' 2>/dev/null)
  team=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.project\.ocp\.com/email}' 2>/dev/null)

  manager=${manager:-}
  domain=${domain:-}
  team=${team:-}

  ### --------------------------
  ### Deployments
  ### --------------------------
  for dep in $(oc -n "$ns" get deploy -o jsonpath='{.items[*].metadata.name}'); do
    ready=$(oc -n "$ns" get deploy "$dep" -o jsonpath='{.status.readyReplicas}')
    total=$(oc -n "$ns" get deploy "$dep" -o jsonpath='{.status.replicas}')
    ready=${ready:-0}
    total=${total:-0}

    status="$ready/$total"

    echo "$CLUSTER_NAME,$ns,$manager,$domain,$team,Deployment,$dep,$status" >> "$OUTPUT_FILE"
  done

  ### --------------------------
  ### DeploymentConfigs
  ### --------------------------
  for dc in $(oc -n "$ns" get dc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    ready=$(oc -n "$ns" get dc "$dc" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    total=$(oc -n "$ns" get dc "$dc" -o jsonpath='{.status.replicas}' 2>/dev/null)
    ready=${ready:-0}
    total=${total:-0}

    status="$ready/$total"

    echo "$CLUSTER_NAME,$ns,$manager,$domain,$team,DeploymentConfig,$dc,$status" >> "$OUTPUT_FILE"
  done

  ### --------------------------
  ### StatefulSets
  ### --------------------------
  for sts in $(oc -n "$ns" get sts -o jsonpath='{.items[*].metadata.name}'); do
    ready=$(oc -n "$ns" get sts "$sts" -o jsonpath='{.status.readyReplicas}')
    total=$(oc -n "$ns" get sts "$sts" -o jsonpath='{.status.replicas}')
    ready=${ready:-0}
    total=${total:-0}

    status="$ready/$total"

    echo "$CLUSTER_NAME,$ns,$manager,$domain,$team,StatefulSet,$sts,$status" >> "$OUTPUT_FILE"
  done

  ### --------------------------
  ### DaemonSets
  ### --------------------------
  for ds in $(oc -n "$ns" get ds -o jsonpath='{.items[*].metadata.name}'); do
    ready=$(oc -n "$ns" get ds "$ds" -o jsonpath='{.status.numberReady}')
    total=$(oc -n "$ns" get ds "$ds" -o jsonpath='{.status.desiredNumberScheduled}')
    ready=${ready:-0}
    total=${total:-0}

    status="$ready/$total"

    echo "$CLUSTER_NAME,$ns,$manager,$domain,$team,DaemonSet,$ds,$status" >> "$OUTPUT_FILE"
  done

  ### --------------------------
  ### CronJobs
  ### --------------------------
  for cj in $(oc -n "$ns" get cronjob -o jsonpath='{.items[*].metadata.name}'); do
    active=$(oc -n "$ns" get cronjob "$cj" -o jsonpath='{.status.active[*].name}')
    if [[ -z "$active" ]]; then
      status="0 active jobs"
    else
      count=$(echo "$active" | wc -w)
      status="$count active jobs"
    fi

    echo "$CLUSTER_NAME,$ns,$manager,$domain,$team,CronJob,$cj,$status" >> "$OUTPUT_FILE"
  done

done

echo ""
echo "✅ Workload status extracted to: $OUTPUT_FILE"
