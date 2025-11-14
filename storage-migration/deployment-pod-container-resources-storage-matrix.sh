#!/bin/bash

# Kubernetes Resource Report Generator - Simple CSV Output
# Generates comprehensive resource reports for namespaces with specified label
# Includes Deployments, StatefulSets, DeploymentConfigs with CPU/Memory requests/limits and PVC information

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global variables
OUTPUT_DIR=""
TIMESTAMP=""
NAMESPACE_LABEL=""
LABEL_KEY=""
LABEL_VALUE=""

print_color() {
    echo -e "${1}${2}${NC}"
}



# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --label)
                NAMESPACE_LABEL="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 --label <key=value>"
                echo ""
                echo "Required parameters:"
                echo "  --label <key=value>    Namespace label selector (e.g., appDomain=IT)"
                echo ""
                echo "Examples:"
                echo "  $0 --label appDomain=IT"
                echo "  $0 --label environment=production"
                echo "  $0 --label team=platform"
                echo ""
                echo "Prerequisites:"
                echo "  - Login to your cluster first (oc login or kubectl config use-context)"
                echo "  - Ensure kubectl and jq commands are available"
                echo ""
                echo "Generates CSV report for Kubernetes resources in namespaces matching the label"
                exit 0
                ;;
            *)
                print_color "$RED" "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$NAMESPACE_LABEL" ]]; then
        print_color "$RED" "Error: --label parameter is required"
        echo "Example: $0 --label appDomain=IT"
        echo "Use --help for more information"
        exit 1
    fi

    # Parse label into key and value
    if [[ "$NAMESPACE_LABEL" =~ ^([^=]+)=([^=]+)$ ]]; then
        LABEL_KEY="${BASH_REMATCH[1]}"
        LABEL_VALUE="${BASH_REMATCH[2]}"
    else
        print_color "$RED" "Error: Invalid label format. Expected format: key=value"
        echo "Example: appDomain=IT"
        exit 1
    fi
}

# Setup output directory
setup_output_directory() {
    TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
    OUTPUT_DIR="/opt/webadmin/k8s-resource-reports/${LABEL_VALUE}/${TIMESTAMP}"
    
    if ! mkdir -p "$OUTPUT_DIR"; then
        print_color "$RED" "Error: Failed to create output directory: $OUTPUT_DIR"
        exit 1
    fi
    
    print_color "$GREEN" "Created output directory: $OUTPUT_DIR"
}

# Check prerequisites
check_prerequisites() {
    for cmd in kubectl jq; do
        if ! command -v "$cmd" &> /dev/null; then
            print_color "$RED" "Error: $cmd is required but not installed"
            exit 1
        fi
    done
    
    print_color "$GREEN" "Prerequisites validated"
}

# Convert CPU to millicores
convert_cpu_to_millicores() {
    local cpu_value="$1"
    
    if [[ -z "$cpu_value" || "$cpu_value" == "null" || "$cpu_value" == "0" ]]; then
        echo "0"
        return
    fi
    
    cpu_value=$(echo "$cpu_value" | sed 's/"//g')
    
    if [[ "$cpu_value" == *"m" ]]; then
        echo "${cpu_value%m}"
    elif [[ "$cpu_value" == *"."* ]]; then
        echo "$(echo "$cpu_value * 1000" | bc 2>/dev/null || echo "0")"
    else
        echo "$((cpu_value * 1000))"
    fi
}

# Convert memory to MB
convert_memory_to_mb() {
    local mem_value="$1"
    
    if [[ -z "$mem_value" || "$mem_value" == "null" || "$mem_value" == "0" ]]; then
        echo "0"
        return
    fi
    
    mem_value=$(echo "$mem_value" | sed 's/"//g')
    local number=$(echo "$mem_value" | grep -oE '[0-9]+(\.[0-9]+)?')
    local unit=$(echo "$mem_value" | grep -oE '[A-Za-z]+$')
    
    if [[ -z "$number" ]]; then
        echo "0"
        return
    fi
    
    case "$unit" in
        "Ki"|"K")
            echo "$(echo "$number / 1024" | bc -l 2>/dev/null | cut -d. -f1 || echo "0")"
            ;;
        "Mi"|"M")
            echo "${number%.*}"
            ;;
        "Gi"|"G")
            echo "$(echo "$number * 1024" | bc 2>/dev/null || echo "0")"
            ;;
        "Ti"|"T")
            echo "$(echo "$number * 1024 * 1024" | bc 2>/dev/null || echo "0")"
            ;;
        *)
            echo "$(echo "$number / 1024 / 1024" | bc 2>/dev/null | cut -d. -f1 || echo "0")"
            ;;
    esac
}

# Format resource value
format_resource() {
    local value="$1"
    local unit="$2"
    
    if [[ "$value" == "0" ]]; then
        echo "0${unit}"
    elif [[ "$unit" == "m" && "$value" -ge 1000 ]]; then
        echo "$((value / 1000))"
    elif [[ "$unit" == "Mi" && "$value" -ge 1024 ]]; then
        echo "$((value / 1024))Gi"
    else
        echo "${value}${unit}"
    fi
}

# Get workload selector for finding pods
get_workload_selector() {
    local workload_name="$1"
    local workload_type="$2"
    local namespace="$3"
    
    # Get the actual labels used by the workload
    case "$workload_type" in
        "Deployment")
            # For deployments, get the selector from the deployment spec
            local selector_raw=$(kubectl get deployment "$workload_name" -n "$namespace" -o json 2>/dev/null | jq -r '.spec.selector.matchLabels | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | head -1)
            if [[ -n "$selector_raw" ]]; then
                echo "$selector_raw"
            else
                echo "app=${workload_name}"
            fi
            ;;
        "StatefulSet")
            # For statefulsets, get the selector from the statefulset spec
            local selector_raw=$(kubectl get statefulset "$workload_name" -n "$namespace" -o json 2>/dev/null | jq -r '.spec.selector.matchLabels | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null | head -1)
            if [[ -n "$selector_raw" ]]; then
                echo "$selector_raw"
            else
                echo "app=${workload_name}"
            fi
            ;;
        "DeploymentConfig")
            echo "deploymentconfig=${workload_name}"
            ;;
        *)
            echo "app=${workload_name}"
            ;;
    esac
}

# Write CSV rows for workload (one row per container in each pod)
write_workload_csv_rows() {
    local namespace="$1"
    local workload_name="$2"
    local workload_type="$3"
    local result="$4"
    local csv_file="$5"
    
    # Extract container data from result
    local containers_data=$(echo "$result" | cut -d'|' -f1)  # Container data part
    local pvc_info_part=$(echo "$result" | cut -d'|' -f2)   # PVC info part
    
    # Extract PVC fields
    local has_pvc=$(echo "$pvc_info_part" | cut -d',' -f1)
    local pvc_details=$(echo "$pvc_info_part" | cut -d',' -f2)
    local total_storage=$(echo "$pvc_info_part" | cut -d',' -f3)
    
    # Handle case where no containers found
    if [[ "$containers_data" == "N/A:N/A:N/A:0m:0Mi:No Limit:No Limit" ]]; then
        echo "\"$namespace\",\"$workload_name\",\"$workload_type\",\"N/A\",\"N/A\",\"N/A\",\"0m\",\"0Mi\",\"No Limit\",\"No Limit\",\"$has_pvc\",\"$pvc_details\",\"$total_storage\"" >> "$csv_file"
        return
    fi
    
    # Split container data by semicolon separator (each container entry)
    IFS=';' read -ra CONTAINER_ARRAY <<< "$containers_data"
    for container_entry in "${CONTAINER_ARRAY[@]}"; do
        if [[ -n "$container_entry" ]]; then
            # Parse container entry: PodName:NodeName:ContainerName:CPUReq:MemReq:CPULim:MemLim
            local pod_name=$(echo "$container_entry" | cut -d: -f1)
            local node_name=$(echo "$container_entry" | cut -d: -f2)
            local container_name=$(echo "$container_entry" | cut -d: -f3)
            local cpu_req=$(echo "$container_entry" | cut -d: -f4)
            local mem_req=$(echo "$container_entry" | cut -d: -f5)
            local cpu_lim=$(echo "$container_entry" | cut -d: -f6)
            local mem_lim=$(echo "$container_entry" | cut -d: -f7)
            
            echo "\"$namespace\",\"$workload_name\",\"$workload_type\",\"$pod_name\",\"$node_name\",\"$container_name\",\"$cpu_req\",\"$mem_req\",\"$cpu_lim\",\"$mem_lim\",\"$has_pvc\",\"$pvc_details\",\"$total_storage\"" >> "$csv_file"
        fi
    done
}

# Analyze workload resources
analyze_workload() {
    local namespace="$1"
    local workload_name="$2"
    local workload_type="$3"
    
    # Get workload JSON for PVC analysis
    local workload_json
    case "$workload_type" in
        "Deployment")
            workload_json=$(kubectl get deployment "$workload_name" -n "$namespace" -o json 2>/dev/null)
            ;;
        "StatefulSet")
            workload_json=$(kubectl get statefulset "$workload_name" -n "$namespace" -o json 2>/dev/null)
            ;;
        "DeploymentConfig")
            workload_json=$(kubectl get deploymentconfig "$workload_name" -n "$namespace" -o json 2>/dev/null)
            ;;
    esac
    
    if [[ -z "$workload_json" ]]; then
        echo "N/A:N/A:N/A:0m:0Mi:No Limit:No Limit|No,N/A,0"
        return
    fi
    
    # Get node information from all running pods and extract container-level resources
    local pod_count=0
    local containers_info=""
    local selector=$(get_workload_selector "$workload_name" "$workload_type" "$namespace")
    
    if [[ -n "$selector" ]]; then
        # Try to find all running pods using the selector
        local pods=$(kubectl get pods -n "$namespace" -l "$selector" --no-headers 2>/dev/null | grep "Running" | awk '{print $1}')
        
        # If no running pods found with selector, try finding pods by name pattern
        if [[ -z "$pods" ]]; then
            pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep "^${workload_name}" | grep "Running" | awk '{print $1}')
        fi
        
        # Process each running pod to get container-level resource info
        if [[ -n "$pods" ]]; then
            while IFS= read -r pod; do
                if [[ -n "$pod" ]]; then
                    # Get pod details
                    local pod_json=$(kubectl get pod "$pod" -n "$namespace" -o json 2>/dev/null)
                    if [[ -n "$pod_json" ]]; then
                        local node=$(echo "$pod_json" | jq -r '.spec.nodeName // "N/A"' 2>/dev/null)
                        ((pod_count++))
                        
                        # Extract individual container resources from this pod
                        while IFS= read -r container; do
                            if [[ -n "$container" ]]; then
                                local container_name=$(echo "$container" | jq -r '.name // "unknown"' 2>/dev/null)
                                local cpu_req=$(echo "$container" | jq -r '.resources.requests.cpu // "0"' 2>/dev/null)
                                local mem_req=$(echo "$container" | jq -r '.resources.requests.memory // "0"' 2>/dev/null)
                                local cpu_lim=$(echo "$container" | jq -r '.resources.limits.cpu // "0"' 2>/dev/null)
                                local mem_lim=$(echo "$container" | jq -r '.resources.limits.memory // "0"' 2>/dev/null)
                                
                                [[ "$cpu_req" == "null" ]] && cpu_req="0"
                                [[ "$mem_req" == "null" ]] && mem_req="0"
                                [[ "$cpu_lim" == "null" ]] && cpu_lim="0"
                                [[ "$mem_lim" == "null" ]] && mem_lim="0"
                                
                                # Format resource values
                                local cpu_req_formatted=$(format_resource "$(convert_cpu_to_millicores "$cpu_req")" "m")
                                local mem_req_formatted=$(format_resource "$(convert_memory_to_mb "$mem_req")" "Mi")
                                local cpu_lim_formatted=$([[ "$cpu_lim" == "0" ]] && echo "No Limit" || format_resource "$(convert_cpu_to_millicores "$cpu_lim")" "m")
                                local mem_lim_formatted=$([[ "$mem_lim" == "0" ]] && echo "No Limit" || format_resource "$(convert_memory_to_mb "$mem_lim")" "Mi")
                                
                                # Add container info: PodName:NodeName:ContainerName:CPUReq:MemReq:CPULim:MemLim
                                [[ -n "$containers_info" ]] && containers_info="$containers_info;"
                                containers_info="${containers_info}${pod}:${node}:${container_name}:${cpu_req_formatted}:${mem_req_formatted}:${cpu_lim_formatted}:${mem_lim_formatted}"
                            fi
                        done <<< "$(echo "$pod_json" | jq -c '.spec.containers[]?' 2>/dev/null)"
                    fi
                fi
            done <<< "$pods"
        fi
    fi
    
    # If no pods found, try to get resource info from workload spec as fallback
    if [[ "$pod_count" -eq 0 ]]; then
        # Fallback to workload spec for container info
        while IFS= read -r container; do
            if [[ -n "$container" ]]; then
                local container_name=$(echo "$container" | jq -r '.name // "unknown"' 2>/dev/null)
                local cpu_req=$(echo "$container" | jq -r '.resources.requests.cpu // "0"' 2>/dev/null)
                local mem_req=$(echo "$container" | jq -r '.resources.requests.memory // "0"' 2>/dev/null)
                local cpu_lim=$(echo "$container" | jq -r '.resources.limits.cpu // "0"' 2>/dev/null)
                local mem_lim=$(echo "$container" | jq -r '.resources.limits.memory // "0"' 2>/dev/null)
                
                [[ "$cpu_req" == "null" ]] && cpu_req="0"
                [[ "$mem_req" == "null" ]] && mem_req="0"
                [[ "$cpu_lim" == "null" ]] && cpu_lim="0"
                [[ "$mem_lim" == "null" ]] && mem_lim="0"
                
                # Format resource values
                local cpu_req_formatted=$(format_resource "$(convert_cpu_to_millicores "$cpu_req")" "m")
                local mem_req_formatted=$(format_resource "$(convert_memory_to_mb "$mem_req")" "Mi")
                local cpu_lim_formatted=$([[ "$cpu_lim" == "0" ]] && echo "No Limit" || format_resource "$(convert_cpu_to_millicores "$cpu_lim")" "m")
                local mem_lim_formatted=$([[ "$mem_lim" == "0" ]] && echo "No Limit" || format_resource "$(convert_memory_to_mb "$mem_lim")" "Mi")
                
                # Add container info with N/A for pod and node
                [[ -n "$containers_info" ]] && containers_info="$containers_info;"
                containers_info="${containers_info}N/A:N/A:${container_name}:${cpu_req_formatted}:${mem_req_formatted}:${cpu_lim_formatted}:${mem_lim_formatted}"
            fi
        done <<< "$(echo "$workload_json" | jq -c '.spec.template.spec.containers[]?' 2>/dev/null)"
        
        # If still no container info, add default entry
        if [[ -z "$containers_info" ]]; then
            containers_info="N/A:N/A:N/A:0m:0Mi:No Limit:No Limit"
        fi
    fi
    
    # Get PVC info from workload spec
    local pvc_info="N/A"
    local total_storage=0
    local has_pvc="No"
    
    # Check for PVCs
    local pvcs=$(echo "$workload_json" | jq -r '.spec.template.spec.volumes[]? | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName' 2>/dev/null)
    if [[ -n "$pvcs" ]]; then
        has_pvc="Yes"
        pvc_info=""
        while IFS= read -r pvc_name; do
            if [[ -n "$pvc_name" ]]; then
                local pvc_details=$(kubectl get pvc "$pvc_name" -n "$namespace" -o json 2>/dev/null)
                if [[ -n "$pvc_details" ]]; then
                    local storage=$(echo "$pvc_details" | jq -r '.spec.resources.requests.storage // "0Gi"')
                    local storage_class=$(echo "$pvc_details" | jq -r '.spec.storageClassName // "default"')
                    
                    [[ -n "$pvc_info" ]] && pvc_info="$pvc_info; "
                    pvc_info="${pvc_info}${pvc_name}:${storage}(${storage_class})"
                    
                    total_storage=$((total_storage + $(convert_memory_to_mb "$storage")))
                fi
            fi
        done <<< "$pvcs"
    fi
    
    # Check StatefulSet volumeClaimTemplates
    if [[ "$workload_type" == "StatefulSet" ]]; then
        local vct_pvcs=$(echo "$workload_json" | jq -r '.spec.volumeClaimTemplates[]?.metadata.name' 2>/dev/null)
        if [[ -n "$vct_pvcs" ]]; then
            while IFS= read -r vct_name; do
                if [[ -n "$vct_name" ]]; then
                    local actual_pvcs=$(kubectl get pvc -n "$namespace" --no-headers 2>/dev/null | awk -v pattern="^${vct_name}-" '$1 ~ pattern {print $1}')
                    if [[ -n "$actual_pvcs" ]]; then
                        has_pvc="Yes"
                        while IFS= read -r actual_pvc; do
                            if [[ -n "$actual_pvc" ]]; then
                                local pvc_details=$(kubectl get pvc "$actual_pvc" -n "$namespace" -o json 2>/dev/null)
                                if [[ -n "$pvc_details" ]]; then
                                    local storage=$(echo "$pvc_details" | jq -r '.spec.resources.requests.storage // "0Gi"')
                                    local storage_class=$(echo "$pvc_details" | jq -r '.spec.storageClassName // "default"')
                                    
                                    [[ -n "$pvc_info" && "$pvc_info" != "N/A" ]] && pvc_info="$pvc_info; "
                                    [[ "$pvc_info" == "N/A" ]] && pvc_info=""
                                    pvc_info="${pvc_info}${actual_pvc}:${storage}(${storage_class})"
                                    
                                    total_storage=$((total_storage + $(convert_memory_to_mb "$storage")))
                                fi
                            fi
                        done <<< "$actual_pvcs"
                    fi
                fi
            done <<< "$vct_pvcs"
        fi
    fi
    
    # Return format: containers_info|has_pvc,pvc_info,total_storage
    echo "${containers_info}|${has_pvc},${pvc_info},${total_storage}"
}

# Main analysis function
main() {
    local start_time=$(date +%s)
    
    print_color "$BLUE" "Kubernetes Resource Report Generator"
    print_color "$BLUE" "====================================="
    
    parse_arguments "$@"
    setup_output_directory
    check_prerequisites
    
    # Get namespaces matching the label
    local target_namespaces
    target_namespaces=$(kubectl get namespaces -l "${NAMESPACE_LABEL}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [[ -z "$target_namespaces" ]]; then
        print_color "$YELLOW" "No namespaces found with label ${NAMESPACE_LABEL}"
        exit 0
    fi
    
    print_color "$GREEN" "Found namespaces with label ${NAMESPACE_LABEL}: $target_namespaces"
    
    # Setup CSV
    local csv_file="${OUTPUT_DIR}/k8s-resource-analysis-${LABEL_VALUE}-${TIMESTAMP}.csv"
    echo "Namespace,WorkloadName,WorkloadType,PodName,NodeName,ContainerName,CPURequests,MemoryRequests,CPULimits,MemoryLimits,HasPVC,PVCDetails,TotalStorageMB" > "$csv_file"
    
    local total_workloads=0
    local workloads_with_pvc=0
    
    # Process each namespace
    for namespace in $target_namespaces; do
        print_color "$CYAN" "📁 Analyzing namespace: $namespace"
        
        # Deployments
        local deployments=$(kubectl get deployments -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' || true)
        for deployment in $deployments; do
            [[ -z "$deployment" ]] && continue
            print_color "$GREEN" "  📦 $deployment"
            local result=$(analyze_workload "$namespace" "$deployment" "Deployment")
            write_workload_csv_rows "$namespace" "$deployment" "Deployment" "$result" "$csv_file"
            ((total_workloads++))
            [[ "$result" =~ \|Yes, ]] && ((workloads_with_pvc++))
        done
        
        # StatefulSets
        local statefulsets=$(kubectl get statefulsets -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' || true)
        for statefulset in $statefulsets; do
            [[ -z "$statefulset" ]] && continue
            print_color "$GREEN" "  📊 $statefulset"
            local result=$(analyze_workload "$namespace" "$statefulset" "StatefulSet")
            write_workload_csv_rows "$namespace" "$statefulset" "StatefulSet" "$result" "$csv_file"
            ((total_workloads++))
            [[ "$result" =~ \|Yes, ]] && ((workloads_with_pvc++))
        done
        
        # DeploymentConfigs
        local deploymentconfigs=$(kubectl get deploymentconfigs -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' || true)
        for deploymentconfig in $deploymentconfigs; do
            [[ -z "$deploymentconfig" ]] && continue
            print_color "$GREEN" "  ⚙️  $deploymentconfig"
            local result=$(analyze_workload "$namespace" "$deploymentconfig" "DeploymentConfig")
            write_workload_csv_rows "$namespace" "$deploymentconfig" "DeploymentConfig" "$result" "$csv_file"
            ((total_workloads++))
            [[ "$result" =~ \|Yes, ]] && ((workloads_with_pvc++))
        done
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    print_color "$GREEN" "Analysis complete!"
    print_color "$CYAN" "=== SUMMARY ==="
    echo "Label selector: ${NAMESPACE_LABEL}"
    echo "Total workloads: $total_workloads"
    echo "Workloads with PVC: $workloads_with_pvc"
    echo "Duration: ${duration}s"
    print_color "$YELLOW" "CSV Report: $csv_file"
    print_color "$GREEN" "Kubernetes Resource Analysis completed! 🎉"
}

# Run the script
main "$@"
