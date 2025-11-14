#!/bin/bash

# dmd Resource Report Generator - Simple CSV Output
# Generates comprehensive resource reports for namespaces with label "appDomain=dmd"
# Includes Deployments, StatefulSets, DeploymentConfigs with CPU/Memory requests/limits and PVC information

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global variables
CLUSTER_NAME=""
OUTPUT_DIR=""
TIMESTAMP=""

print_color() {
    echo -e "${1}${2}${NC}"
}

# Get current cluster context name
get_current_cluster() {
    local context_info
    context_info=$(kubectl config current-context 2>/dev/null)
    if [[ $? -ne 0 || -z "$context_info" ]]; then
        print_color "$RED" "Error: No active kubectl context found"
        print_color "$YELLOW" "Please login to your cluster first: oc login or kubectl config use-context"
        exit 1
    fi
    
    # Extract cluster name from context
    if [[ "$context_info" =~ aro-nonprod ]]; then
        echo "aro-nonprod"
    elif [[ "$context_info" =~ aro-prod.*usc ]]; then
        echo "aro-prod-usc"
    elif [[ "$context_info" =~ aro-prod.*use2 ]]; then
        echo "aro-prod-use2"
    elif [[ "$context_info" =~ aro-prod ]]; then
        echo "aro-prod-use2"
    elif [[ "$context_info" =~ onprem-nonprod ]]; then
        echo "onprem-nonprod"
    elif [[ "$context_info" =~ onprem-prod ]]; then
        echo "onprem-prod"
    else
        echo "${context_info##*/}"
    fi
}

# Parse arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [--cluster-name <name>]"
                echo "Generates CSV report for dmd resources"
                exit 0
                ;;
            *)
                print_color "$RED" "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Auto-detect cluster if not provided
    if [[ -z "$CLUSTER_NAME" ]]; then
        CLUSTER_NAME=$(get_current_cluster)
        print_color "$GREEN" "Auto-detected cluster: $CLUSTER_NAME"
    fi
}

# Setup output directory
setup_output_directory() {
    TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
    OUTPUT_DIR="/opt/webadmin/dmd-resource-reports/dmd-${CLUSTER_NAME}/${TIMESTAMP}"
    
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
    
    if ! kubectl auth can-i get namespaces &>/dev/null; then
        print_color "$RED" "Error: Cannot access namespaces with current kubectl context"
        exit 1
    fi
    
    print_color "$GREEN" "Successfully validated kubectl access"
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

# Analyze workload resources
analyze_workload() {
    local namespace="$1"
    local workload_name="$2"
    local workload_type="$3"
    
    # Get workload JSON
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
        echo "0m,0Mi,No Limit,No Limit,0,No,N/A,0"
        return
    fi
    
    # Extract container resources
    local total_cpu_req=0
    local total_mem_req=0
    local total_cpu_lim=0
    local total_mem_lim=0
    local container_count=0
    local has_limits=false
    
    while IFS= read -r container; do
        if [[ -n "$container" ]]; then
            local cpu_req=$(echo "$container" | jq -r '.resources.requests.cpu // "0"' 2>/dev/null)
            local mem_req=$(echo "$container" | jq -r '.resources.requests.memory // "0"' 2>/dev/null)
            local cpu_lim=$(echo "$container" | jq -r '.resources.limits.cpu // "0"' 2>/dev/null)
            local mem_lim=$(echo "$container" | jq -r '.resources.limits.memory // "0"' 2>/dev/null)
            
            [[ "$cpu_req" == "null" ]] && cpu_req="0"
            [[ "$mem_req" == "null" ]] && mem_req="0"
            [[ "$cpu_lim" == "null" ]] && cpu_lim="0"
            [[ "$mem_lim" == "null" ]] && mem_lim="0"
            
            total_cpu_req=$((total_cpu_req + $(convert_cpu_to_millicores "$cpu_req")))
            total_mem_req=$((total_mem_req + $(convert_memory_to_mb "$mem_req")))
            total_cpu_lim=$((total_cpu_lim + $(convert_cpu_to_millicores "$cpu_lim")))
            total_mem_lim=$((total_mem_lim + $(convert_memory_to_mb "$mem_lim")))
            
            [[ "$cpu_lim" != "0" ]] && has_limits=true
            [[ "$mem_lim" != "0" ]] && has_limits=true
            
            ((container_count++))
        fi
    done <<< "$(echo "$workload_json" | jq -c '.spec.template.spec.containers[]?' 2>/dev/null)"
    
    # Get PVC info
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
    
    # Format output
    local cpu_req_formatted=$(format_resource "$total_cpu_req" "m")
    local mem_req_formatted=$(format_resource "$total_mem_req" "Mi")
    local cpu_lim_formatted=$([[ "$total_cpu_lim" == "0" ]] && echo "No Limit" || format_resource "$total_cpu_lim" "m")
    local mem_lim_formatted=$([[ "$total_mem_lim" == "0" ]] && echo "No Limit" || format_resource "$total_mem_lim" "Mi")
    
    echo "$cpu_req_formatted,$mem_req_formatted,$cpu_lim_formatted,$mem_lim_formatted,$container_count,$has_pvc,$pvc_info,$total_storage"
}

# Main analysis function
main() {
    local start_time=$(date +%s)
    
    print_color "$BLUE" "dmd Resource Report Generator"
    print_color "$BLUE" "=============================="
    
    parse_arguments "$@"
    setup_output_directory
    check_prerequisites
    
    # Get dmd namespaces
    local dmd_namespaces
    dmd_namespaces=$(kubectl get namespaces -l appDomain=dmd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [[ -z "$dmd_namespaces" ]]; then
        print_color "$YELLOW" "No namespaces found with label appDomain=dmd"
        exit 0
    fi
    
    print_color "$GREEN" "Found dmd namespaces: $dmd_namespaces"
    
    # Setup CSV
    local csv_file="${OUTPUT_DIR}/dmd-resource-analysis-${CLUSTER_NAME}-${TIMESTAMP}.csv"
    echo "Namespace,WorkloadName,WorkloadType,CPURequests,MemoryRequests,CPULimits,MemoryLimits,ContainerCount,HasPVC,PVCDetails,TotalStorageMB,PVCCount" > "$csv_file"
    
    local total_workloads=0
    local workloads_with_pvc=0
    
    # Process each namespace
    for namespace in $dmd_namespaces; do
        print_color "$CYAN" "📁 Analyzing namespace: $namespace"
        
        # Deployments
        local deployments=$(kubectl get deployments -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' || true)
        for deployment in $deployments; do
            [[ -z "$deployment" ]] && continue
            print_color "$GREEN" "  📦 $deployment"
            local result=$(analyze_workload "$namespace" "$deployment" "Deployment")
            echo "\"$namespace\",\"$deployment\",\"Deployment\",\"$(echo $result | tr ',' '","')\"" >> "$csv_file"
            ((total_workloads++))
            [[ "$result" =~ ,Yes, ]] && ((workloads_with_pvc++))
        done
        
        # StatefulSets
        local statefulsets=$(kubectl get statefulsets -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' || true)
        for statefulset in $statefulsets; do
            [[ -z "$statefulset" ]] && continue
            print_color "$GREEN" "  📊 $statefulset"
            local result=$(analyze_workload "$namespace" "$statefulset" "StatefulSet")
            echo "\"$namespace\",\"$statefulset\",\"StatefulSet\",\"$(echo $result | tr ',' '","')\"" >> "$csv_file"
            ((total_workloads++))
            [[ "$result" =~ ,Yes, ]] && ((workloads_with_pvc++))
        done
        
        # DeploymentConfigs
        local deploymentconfigs=$(kubectl get deploymentconfigs -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}' || true)
        for deploymentconfig in $deploymentconfigs; do
            [[ -z "$deploymentconfig" ]] && continue
            print_color "$GREEN" "  ⚙️  $deploymentconfig"
            local result=$(analyze_workload "$namespace" "$deploymentconfig" "DeploymentConfig")
            echo "\"$namespace\",\"$deploymentconfig\",\"DeploymentConfig\",\"$(echo $result | tr ',' '","')\"" >> "$csv_file"
            ((total_workloads++))
            [[ "$result" =~ ,Yes, ]] && ((workloads_with_pvc++))
        done
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    print_color "$GREEN" "Analysis complete!"
    print_color "$CYAN" "=== SUMMARY ==="
    echo "Total workloads: $total_workloads"
    echo "Workloads with PVC: $workloads_with_pvc"
    echo "Duration: ${duration}s"
    print_color "$YELLOW" "CSV Report: $csv_file"
    print_color "$GREEN" "dmd Resource Analysis completed! 🎉"
}

# Run the script
main "$@"
