#!/bin/bash

# Complete Stack Deployment Script for YugabyteDB
# ✅ FIXED: Improved error handling and health checks

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Configuration
SKIP_TERRAFORM="${1:-false}"
ENVIRONMENT="${2:-dev}"
MAX_RETRIES=30
RETRY_INTERVAL=10

# ✅ FIXED: Pre-flight checks
preflight_checks() {
    log_info "🔍 Running pre-flight checks..."
    
    # Check required tools
    local required_tools=("kubectl" "helm" "gcloud")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool is not installed or not in PATH"
            exit 1
        fi
    done
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "kubectl cannot connect to cluster"
        exit 1
    fi
    
    # Check GCP authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        log_error "No active GCP authentication found"
        exit 1
    fi
    
    log_success "Pre-flight checks passed"
}

# ✅ FIXED: Robust health check functions
wait_for_operator_ready() {
    log_info "Waiting for YugabyteDB operator to be ready..."
    local retries=$MAX_RETRIES
    
    while [ $retries -gt 0 ]; do
        if kubectl get pods -n yb-operator -l app=yugabyte-k8s-operator --field-selector=status.phase=Running | grep -q Running; then
            log_success "YugabyteDB operator is ready"
            return 0
        fi
        log_info "⏳ Waiting for operator... ($retries retries left)"
        sleep $RETRY_INTERVAL
        ((retries--))
    done
    
    log_error "YugabyteDB operator failed to become ready"
    return 1
}

wait_for_cluster_ready() {
    local namespace="$1"
    local cluster_name="$2"
    log_info "Waiting for YugabyteDB cluster $cluster_name in namespace $namespace to be ready..."
    local retries=$MAX_RETRIES
    
    while [ $retries -gt 0 ]; do
        # Check if master pods are running
        local master_ready=$(kubectl get pods -n "$namespace" -l app=yb-master --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        # Check if tserver pods are running  
        local tserver_ready=$(kubectl get pods -n "$namespace" -l app=yb-tserver --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        
        if [[ "$master_ready" -gt 0 && "$tserver_ready" -gt 0 ]]; then
            # Additional check: verify master is actually responsive
            if kubectl exec -n "$namespace" "$(kubectl get pods -n "$namespace" -l app=yb-master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" -- yb-admin --master_addresses=localhost:7100 list_all_masters &>/dev/null; then
                log_success "YugabyteDB cluster $cluster_name is ready"
                return 0
            fi
        fi
        
        log_info "⏳ Waiting for cluster ($retries retries left). Masters: $master_ready, TServers: $tserver_ready"
        sleep $RETRY_INTERVAL
        ((retries--))
    done
    
    log_error "YugabyteDB cluster $cluster_name failed to become ready"
    return 1
}

# ✅ FIXED: Better namespace creation with validation
create_namespaces() {
    log_info "📦 Creating namespaces..."
    
    if ! kubectl apply -f manifests/namespaces/environments.yaml; then
        log_error "Failed to create namespaces"
        exit 1
    fi
    
    # Wait for namespaces to be active
    local namespaces=("codet-dev-yb" "codet-staging-yb" "codet-prod-yb")
    for ns in "${namespaces[@]}"; do
        kubectl wait --for=condition=Ready namespace/"$ns" --timeout=60s || {
            log_error "Namespace $ns failed to become ready"
            exit 1
        }
    done
    
    log_success "Namespaces created successfully"
}

# Main deployment function
main() {
    log_info "🚀 Starting complete YugabyteDB stack deployment..."
    log_info "Environment: $ENVIRONMENT"
    log_info "Skip Terraform: $SKIP_TERRAFORM"
    
    # ✅ FIXED: Run pre-flight checks
    preflight_checks
    
    # Step 1: Deploy infrastructure (if not skipped)
    if [ "$SKIP_TERRAFORM" != "true" ] && [ "$SKIP_TERRAFORM" != "--skip-terraform" ]; then
        log_info "🏗️ Deploying infrastructure with Terraform..."
        if [ -f "terraform/terraform.tfvars" ]; then
            cd terraform
            terraform init
            terraform plan
            terraform apply -auto-approve
            cd ..
            log_success "Infrastructure deployed"
        else
            log_warning "terraform.tfvars not found, skipping Terraform deployment"
        fi
    else
        log_info "⏭️ Skipping Terraform deployment"
    fi
    
    # Step 2: Install YugabyteDB operator
    log_info "🔧 Installing YugabyteDB operator..."
    if ! ./scripts/install-operator.sh; then
        log_error "Failed to install YugabyteDB operator"
        exit 1
    fi
    
    # ✅ FIXED: Wait for operator to be ready
    if ! wait_for_operator_ready; then
        log_error "Operator deployment failed"
        exit 1
    fi
    
    # Step 3: Create namespaces
    create_namespaces
    
    # Step 4: Deploy YugabyteDB clusters
    log_info "🗄️ Deploying YugabyteDB environments..."
    if ! ./scripts/deploy-all-environments.sh; then
        log_error "Failed to deploy YugabyteDB environments"
        exit 1
    fi
    
    # ✅ FIXED: Wait for clusters to be ready
    case "$ENVIRONMENT" in
        "dev")
            if ! wait_for_cluster_ready "codet-dev-yb" "codet-dev-yb"; then
                exit 1
            fi
            ;;
        "staging")
            if ! wait_for_cluster_ready "codet-staging-yb" "codet-staging-yb"; then
                exit 1
            fi
            ;;
        "prod")
            if ! wait_for_cluster_ready "codet-prod-yb" "codet-prod-yb"; then
                exit 1
            fi
            ;;
        "all")
            for env in "codet-dev-yb" "codet-staging-yb" "codet-prod-yb"; do
                if ! wait_for_cluster_ready "$env" "$env"; then
                    exit 1
                fi
            done
            ;;
    esac
    
    # Step 5: Configure database security and RBAC
    log_info "🔒 Setting up database security..."
    if [ -f "./scripts/setup-database-rbac.sh" ]; then
        if ! ./scripts/setup-database-rbac.sh; then
            log_warning "Database RBAC setup encountered issues, but continuing..."
        fi
    else
        log_warning "Database RBAC script not found, skipping..."
    fi
    
    # Step 6: Set up messaging patterns
    log_info "📡 Setting up messaging patterns..."
    if [ -f "./scripts/setup-messaging-patterns.sh" ]; then
        if ! ./scripts/setup-messaging-patterns.sh; then
            log_warning "Messaging patterns setup encountered issues, but continuing..."
        fi
    else
        log_warning "Messaging patterns script not found, skipping..."
    fi
    
    # Step 7: Deploy monitoring (if enabled)
    log_info "📊 Setting up monitoring..."
    if [ -f "manifests/monitoring/prometheus-stack.yaml" ]; then
        kubectl apply -f manifests/monitoring/prometheus-stack.yaml || log_warning "Monitoring setup failed"
    fi
    
    # Step 8: Validation
    log_info "🔍 Running deployment validation..."
    if [ -f "./scripts/validate-deployment.sh" ]; then
        ./scripts/validate-deployment.sh || log_warning "Some validation checks failed"
    fi
    
    # Success message
    log_success "🎉 Complete stack deployment finished!"
    echo ""
    echo "📋 Next Steps:"
    echo "============="
    echo "1. Check cluster status:"
    echo "   kubectl get ybclusters --all-namespaces"
    echo ""
    echo "2. Access YugabyteDB:"
    echo "   kubectl port-forward -n codet-$ENVIRONMENT-yb svc/yb-tserver-service 5433:5433"
    echo ""
    echo "3. Connect to database:"
    echo "   psql -h localhost -p 5433 -U yugabyte"
    echo ""
}

# ✅ FIXED: Proper error handling and cleanup
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Deployment failed with exit code $exit_code"
        log_info "Check logs above for details"
    fi
}

trap cleanup EXIT

# Run main function
main "$@" 