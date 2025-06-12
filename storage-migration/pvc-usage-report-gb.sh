oc get pods --all-namespaces -o jsonpath="{range .items[*]}{.metadata.namespace}{','}{.metadata.name}{','}{range .spec.containers[*]}{.image}{'\n'}{end}{end}" | sort | uniq | grep nexus.cmgmi.local



skopeo copy  docker://nexus.cmgmi.local:18079/oss/kubernetes-csi/livenessprobe:v2.14.0 docker://nexus.azure.cmgmi.local:18080/oss/kubernetes-csi/livenessprobe:v2.14.0



#!/bin/bash

##########################
#!/bin/bash

STORAGE_CLASS="storage-class-name"

echo -e "NAMESPACE\tPVC_NAME\tSIZE\tPOD\tMOUNT_PATH\tACTUAL_USAGE"

oc get pvc --all-namespaces -o json | jq -r \
  --arg sc "$STORAGE_CLASS" '
    .items[] | select(.spec.storageClassName == $sc) |
    [.metadata.namespace, .metadata.name, .spec.resources.requests.storage] | @tsv' | while IFS=$'\t' read -r ns pvc size; do

  # Find the first pod mounting this PVC
  pod=$(oc get pods -n "$ns" -o json | jq -r \
    --arg pvc "$pvc" '
      .items[]
      | select(.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $pvc))
      | .metadata.name' | head -n 1)

  if [ -z "$pod" ]; then
    echo -e "$ns\t$pvc\t$size\tNO_POD_FOUND\tN/A\tN/A"
    continue
  fi

  # Check pod status
  pod_status=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.status.phase}')
  if [ "$pod_status" != "Running" ]; then
    echo -e "$ns\t$pvc\t$size\t$pod\tPOD_NOT_RUNNING\tN/A"
    continue
  fi

  # Get volume and mount path
  volume_name=$(oc get pod "$pod" -n "$ns" -o json | jq -r \
    --arg pvc "$pvc" '
      .spec.volumes[]
      | select(.persistentVolumeClaim.claimName == $pvc)
      | .name')

  mount_path=$(oc get pod "$pod" -n "$ns" -o json | jq -r \
    --arg vn "$volume_name" '
      .spec.containers[].volumeMounts[]
      | select(.name == $vn)
      | .mountPath' | head -n 1)

  if [ -z "$mount_path" ]; then
    echo -e "$ns\t$pvc\t$size\t$pod\tNO_MOUNT_PATH\tN/A"
    continue
  fi

  # Use the first container in the pod
  container=$(oc get pod "$pod" -n "$ns" -o json | jq -r '.spec.containers[0].name')
  usage=$(oc exec -n "$ns" "$pod" -c "$container" -- df -h "$mount_path" 2>/dev/null | awk 'NR==2{print $3"/"$2}')
  if [ -z "$usage" ]; then usage="N/A"; fi

  echo -e "$ns\t$pvc\t$size\t$pod\t$mount_path\t$usage"
done
