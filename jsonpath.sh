#!/bin/bash

output="ns-domain.csv"
echo "namespace,project_domain" > $output

for ns in $(oc get ns -o jsonpath='{.items[*].metadata.name}'); do
  domain=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.project\.ocp\.abc\.com/domain}' 2>/dev/null)
  echo "$ns,${domain:-}" >> $output
done

echo "Generated: $output"


########
echo "namespace,domain" > ns-domain.csv
for ns in $(oc get ns -o jsonpath='{.items[*].metadata.name}'); do
  domain=$(oc get ns "$ns" -o jsonpath='{.metadata.labels.project\.ocp\.abc\.com/domain}' 2>/dev/null)
  if [[ -n "$domain" ]]; then
    echo "$ns,$domain" >> ns-domain.csv
  fi
done


