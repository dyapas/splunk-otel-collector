#

oc patch limitrange core-resource-limits \
  -n <namespace> \
  --type='json' \
  -p='[{"op": "replace", "path": "/spec/limits/0/defaultRequest/cpu", "value":"200m"}]'

#####

for ns in $(oc get ns --no-headers -o custom-columns=":metadata.name"); do
  lr=$(oc get limitrange -n $ns -o jsonpath='{.items[0].metadata.name}')
  if [ ! -z "$lr" ]; then
    oc patch limitrange $lr -n $ns \
      --type='json' \
      -p='[{"op": "replace", "path": "/spec/limits/0/defaultRequest/cpu", "value":"200m"}]'
    echo "Patched $lr in namespace $ns"
  fi
done
