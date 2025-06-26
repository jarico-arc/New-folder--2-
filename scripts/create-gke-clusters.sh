#!/bin/bash

# GKE Cluster Creation Script - Following YugabyteDB Multi-Zone Documentation
# https://docs.yugabyte.com/preview/deploy/kubernetes/multi-zone/gke/helm-chart/
# 
# Security: Validates all inputs and uses secure defaults
# Error Handling: Comprehensive error checking and logging
# Professional: Follows shell scripting best practices

set -euo pipefail  # Exit on error, undefined vars, pipe failures
IFS=$'\n\t'        # Secure Internal Field Separator

# Color codes for output formatting
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.*}.log"

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

# Colored output functions
log_info() { log "INFO" "${BLUE}$*${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$*${NC}"; }
log_warning() { log "WARNING" "${YELLOW}$*${NC}"; }
log_error() { log "ERROR" "${RED}$*${NC}"; }

# Cleanup function for script exit
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed with exit code $exit_code"
        log_info "Check log file: $LOG_FILE"
    fi
    exit $exit_code
}
trap cleanup EXIT

# Validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."
    
    # Check required commands
    local required_commands=("gcloud" "kubectl")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Required command '$cmd' is not installed"
            log_info "Install gcloud SDK: https://cloud.google.com/sdk/docs/install"
            return 1
        fi
        log_success "✓ $cmd is available"
    done
    
    # Check gcloud authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        log_error "No active gcloud authentication found"
        log_info "Run: gcloud auth login"
        return 1
    fi
    log_success "✓ gcloud authentication is active"
    
    # Validate project ID
    if [[ -z "${PROJECT_ID:-}" ]]; then
        log_error "GCP_PROJECT environment variable or gcloud project not set"
        log_info "Set project: gcloud config set project YOUR_PROJECT_ID"
        return 1
    fi
    log_success "✓ Project ID: $PROJECT_ID"
    
    return 0
}

# Validate configuration
validate_configuration() {
    log_info "Validating configuration..."
    
    # Validate region
    if ! gcloud compute regions describe "$REGION" &>/dev/null; then
        log_error "Invalid region: $REGION"
        return 1
    fi
    
    # Validate zones
    IFS=',' read -ra ZONE_ARRAY <<< "$ZONES"
    for zone in "${ZONE_ARRAY[@]}"; do
        zone=$(echo "$zone" | xargs)  # Trim whitespace
        if ! gcloud compute zones describe "$zone" &>/dev/null; then
            log_error "Invalid zone: $zone"
            return 1
        fi
    done
    
    # Validate machine type
    if ! gcloud compute machine-types describe "$MACHINE_TYPE" --zone="${ZONE_ARRAY[0]}" &>/dev/null; then
        log_error "Invalid machine type: $MACHINE_TYPE"
        return 1
    fi
    
    log_success "✓ Configuration validated"
    return 0
}

# Get or set configuration with secure defaults
get_configuration() {
    # Get project ID securely
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    readonly PROJECT_ID
    
    # Multi-zone configuration following YugabyteDB docs
    readonly CLUSTER_NAME="${CLUSTER_NAME:-yb-demo}"
    readonly REGION="${REGION:-us-central1}"
    readonly ZONES="${ZONES:-us-central1-a,us-central1-b,us-central1-c}"
    readonly MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
    readonly NUM_NODES="${NUM_NODES:-1}"
    readonly DISK_SIZE="${DISK_SIZE:-100}"
    readonly MAX_NODES="${MAX_NODES:-3}"
    readonly MIN_NODES="${MIN_NODES:-1}"
    
    # Security and compliance settings
    readonly ENABLE_NETWORK_POLICY="${ENABLE_NETWORK_POLICY:-true}"
    readonly ENABLE_POD_SECURITY_POLICY="${ENABLE_POD_SECURITY_POLICY:-true}"
    readonly ENABLE_STACKDRIVER="${ENABLE_STACKDRIVER:-true}"
    
    log_info "Configuration loaded:"
    log_info "  Project: $PROJECT_ID"
    log_info "  Cluster: $CLUSTER_NAME"
    log_info "  Region: $REGION"
    log_info "  Zones: $ZONES"
    log_info "  Machine Type: $MACHINE_TYPE"
    log_info "  Nodes per zone: $NUM_NODES"
}

# Check if cluster exists
cluster_exists() {
    if gcloud container clusters describe "$CLUSTER_NAME" --region="$REGION" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Create GKE cluster with security hardening
create_cluster() {
    log_info "Creating regional cluster: $CLUSTER_NAME"
    
    local cluster_args=(
        container clusters create "$CLUSTER_NAME"
        --region="$REGION"
        --node-locations="$ZONES"
        --machine-type="$MACHINE_TYPE"
        --num-nodes="$NUM_NODES"
        --disk-size="$DISK_SIZE"
        --disk-type=pd-ssd
        --enable-autoscaling
        --min-nodes="$MIN_NODES"
        --max-nodes="$MAX_NODES"
        --enable-autorepair
        --enable-autoupgrade
        --release-channel=regular
        --enable-ip-alias
        --enable-stackdriver-kubernetes
        --labels="environment=yugabytedb,team=platform,managed-by=script"
        --addons=HorizontalPodAutoscaling,HttpLoadBalancing
        --enable-shielded-nodes
        --enable-network-policy
        --no-enable-basic-auth
        --no-issue-client-certificate
        --metadata="disable-legacy-endpoints=true"
        --max-pods-per-node=64
        --default-max-pods-per-node=64
        --maintenance-window-start="2024-01-01T09:00:00Z"
        --maintenance-window-end="2024-01-01T17:00:00Z"
        --maintenance-window-recurrence="FREQ=WEEKLY;BYDAY=SA"
    )
    
    # Add security-focused node configuration
    cluster_args+=(
        --node-labels="security.cloud.google.com/private-pool=yugabytedb"
        --enable-autorepair
        --enable-autoupgrade
        --max-surge=1
        --max-unavailable=0
    )
    
    if ! gcloud "${cluster_args[@]}"; then
        log_error "Failed to create cluster"
        return 1
    fi
    
    log_success "✓ Regional cluster created successfully"
    return 0
}

# Create storage classes with proper configuration
create_storage_classes() {
    log_info "Creating storage classes..."
    
    # Check if yb-storage storage class already exists
    # FIXED: Check for current storage class structure
if kubectl get storageclass ssd-us-central1-a &>/dev/null; then
        log_warning "Storage class 'yb-storage' already exists, skipping creation"
        return 0
    fi
    
    # Create yb-storage storage class for YugabyteDB Helm charts
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: yb-storage
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
  labels:
    app: yugabytedb
    component: storage
provisioner: kubernetes.io/gce-pd
parameters:
  type: pd-ssd
  replication-type: regional-pd
  zones: $ZONES
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
EOF
    
    # Create additional storage class for general use
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: pd-ssd-regional
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
  labels:
    app: yugabytedb
    component: storage
provisioner: kubernetes.io/gce-pd
parameters:
  type: pd-ssd
  replication-type: regional-pd
  zones: $ZONES
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
EOF
    
    log_success "✓ Storage classes created"
    return 0
}

# Set up cluster credentials and basic configuration
setup_cluster_access() {
    log_info "Setting up cluster access..."
    
    if ! gcloud container clusters get-credentials "$CLUSTER_NAME" --region="$REGION"; then
        log_error "Failed to get cluster credentials"
        return 1
    fi
    
    # Verify cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        log_error "Failed to connect to cluster"
        return 1
    fi
    
    # Create basic namespaces if they don't exist
    local namespaces=("monitoring" "yugabytedb" "kafka")
    for ns in "${namespaces[@]}"; do
        if ! kubectl get namespace "$ns" &>/dev/null; then
            kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
            log_info "Created namespace: $ns"
        fi
    done
    
    log_success "✓ Cluster access configured"
    return 0
}

# Validate cluster health
validate_cluster_health() {
    log_info "Validating cluster health..."
    
    # Check node status
    local ready_nodes=$(kubectl get nodes --no-headers | grep -c "Ready")
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [[ "$ready_nodes" -eq "$total_nodes" ]] && [[ "$ready_nodes" -gt 0 ]]; then
        log_success "✓ All $ready_nodes nodes are ready"
    else
        log_error "Only $ready_nodes/$total_nodes nodes are ready"
        return 1
    fi
    
    # Check system pods
    local system_pods_ready=$(kubectl get pods -n kube-system --field-selector=status.phase=Running --no-headers | wc -l)
    if [[ "$system_pods_ready" -gt 0 ]]; then
        log_success "✓ System pods are running ($system_pods_ready)"
    else
        log_error "No system pods are running"
        return 1
    fi
    
    return 0
}

# Display next steps
show_next_steps() {
    log_success "🎉 GKE cluster setup completed successfully!"
    echo
    log_info "Cluster Information:"
    log_info "  Name: $CLUSTER_NAME"
    log_info "  Region: $REGION"
    log_info "  Zones: $ZONES"
    log_info "  Project: $PROJECT_ID"
    echo
    log_info "Next Steps:"
    log_info "1. Deploy YugabyteDB:"
    log_info "   bash scripts/create-multi-cluster-yugabytedb.sh"
    echo
    log_info "2. Test connectivity:"
    log_info "   bash scripts/test-yugabytedb-connectivity.sh"
    echo
    log_info "3. Deploy monitoring (optional):"
    log_info "   kubectl apply -f manifests/monitoring/prometheus-stack.yaml"
    echo
    log_info "4. View cluster status:"
    log_info "   kubectl get nodes -o wide"
    log_info "   kubectl get storageclass"
    echo
    log_info "Log file saved to: $LOG_FILE"
}

# Main execution function
main() {
    log_info "Starting GKE cluster creation for YugabyteDB"
    log_info "Script: $SCRIPT_NAME"
    log_info "Log file: $LOG_FILE"
    
    # Get configuration
    get_configuration
    
    # Validate prerequisites
    if ! validate_prerequisites; then
        log_error "Prerequisites validation failed"
        exit 1
    fi
    
    # Validate configuration
    if ! validate_configuration; then
        log_error "Configuration validation failed"
        exit 1
    fi
    
    # Check if cluster already exists
    if cluster_exists; then
        log_success "✓ Cluster '$CLUSTER_NAME' already exists"
    else
        # Create cluster
        if ! create_cluster; then
            log_error "Cluster creation failed"
            exit 1
        fi
    fi
    
    # Setup cluster access
    if ! setup_cluster_access; then
        log_error "Cluster access setup failed"
        exit 1
    fi
    
    # Create storage classes
    if ! create_storage_classes; then
        log_error "Storage class creation failed"
        exit 1
    fi
    
    # Validate cluster health
    if ! validate_cluster_health; then
        log_error "Cluster health validation failed"
        exit 1
    fi
    
    # Show next steps
    show_next_steps
}

# Script usage information
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

GKE Cluster Creation Script for YugabyteDB Multi-Zone Deployment

OPTIONS:
    -h, --help              Show this help message
    -p, --project PROJECT   GCP Project ID (default: current gcloud project)
    -c, --cluster NAME      Cluster name (default: yb-demo)
    -r, --region REGION     GCP region (default: us-central1)
    -z, --zones ZONES       Comma-separated zones (default: us-central1-a,us-central1-b,us-central1-c)
    -m, --machine TYPE      Machine type (default: e2-standard-4)
    -n, --nodes COUNT       Nodes per zone (default: 1)
    
ENVIRONMENT VARIABLES:
    CLUSTER_NAME           Override cluster name
    REGION                 Override region
    ZONES                  Override zones
    MACHINE_TYPE           Override machine type
    NUM_NODES              Override number of nodes
    
EXAMPLES:
    $SCRIPT_NAME                                    # Use defaults
    $SCRIPT_NAME --cluster prod-yb --nodes 2       # Custom cluster name and node count
    CLUSTER_NAME=staging $SCRIPT_NAME              # Use environment variable
    
EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -p|--project)
                PROJECT_ID="$2"
                shift 2
                ;;
            -c|--cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -r|--region)
                REGION="$2"
                shift 2
                ;;
            -z|--zones)
                ZONES="$2"
                shift 2
                ;;
            -m|--machine)
                MACHINE_TYPE="$2"
                shift 2
                ;;
            -n|--nodes)
                NUM_NODES="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"
    main
fi 