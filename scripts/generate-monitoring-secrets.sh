#!/bin/bash

# Generate Monitoring Secrets Script
# Creates secure passwords for monitoring stack components

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
NAMESPACE="monitoring"
SECRET_NAME="grafana-admin-secret"

# Function to generate secure password
generate_secure_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-"$length"
}

# Function to check if kubectl is available
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    
    if ! kubectl cluster-info &> /dev/null; then
        log_error "kubectl cannot connect to cluster"
        exit 1
    fi
}

# Function to create monitoring namespace if it doesn't exist
ensure_namespace() {
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_info "Creating monitoring namespace..."
        kubectl create namespace "$NAMESPACE"
        kubectl label namespace "$NAMESPACE" name=monitoring
        log_success "Monitoring namespace created"
    else
        log_info "Monitoring namespace already exists"
    fi
}

# Function to generate and apply Grafana admin secret
create_grafana_secret() {
    log_info "Generating secure Grafana admin password..."
    
    # Generate secure password
    local admin_password
    admin_password=$(generate_secure_password 24)
    
    # Check if secret already exists
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warning "Secret $SECRET_NAME already exists in namespace $NAMESPACE"
        read -p "Do you want to update it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping secret update"
            return 0
        fi
        
        # Delete existing secret
        kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
        log_info "Existing secret deleted"
    fi
    
    # Create new secret
    kubectl create secret generic "$SECRET_NAME" \
        --namespace="$NAMESPACE" \
        --from-literal=admin-user=admin \
        --from-literal=admin-password="$admin_password" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    if [ $? -eq 0 ]; then
        log_success "Grafana admin secret created successfully"
        echo ""
        echo "=================================="
        echo "🔐 GRAFANA ADMIN CREDENTIALS"
        echo "=================================="
        echo "Username: admin"
        echo "Password: $admin_password"
        echo "=================================="
        echo ""
        log_warning "⚠️  IMPORTANT: Save these credentials securely and delete this output!"
        echo ""
        
        # Save to secure file for later reference
        cat > grafana-admin-credentials.txt << EOF
Grafana Admin Credentials
Generated: $(date)
Username: admin
Password: $admin_password

IMPORTANT: Delete this file after saving credentials securely!
EOF
        
        chmod 600 grafana-admin-credentials.txt
        log_info "Credentials also saved to grafana-admin-credentials.txt (secure permissions)"
        
    else
        log_error "Failed to create Grafana admin secret"
        exit 1
    fi
}

# Function to verify secret was created
verify_secret() {
    log_info "Verifying secret creation..."
    
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        local username
        username=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.admin-user}' | base64 -d)
        log_success "Secret verified. Admin username: $username"
    else
        log_error "Secret verification failed"
        exit 1
    fi
}

# Main function
main() {
    log_info "🔐 Starting monitoring secrets generation..."
    
    # Pre-flight checks
    check_kubectl
    
    # Create namespace if needed
    ensure_namespace
    
    # Generate Grafana secret
    create_grafana_secret
    
    # Verify secret
    verify_secret
    
    log_success "🎉 Monitoring secrets generated successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Deploy the monitoring stack: kubectl apply -f manifests/monitoring/prometheus-stack.yaml"
    echo "2. Access Grafana: kubectl port-forward -n monitoring svc/grafana 3000:3000"
    echo "3. Login with the credentials above"
    echo "4. IMPORTANT: Delete grafana-admin-credentials.txt after use"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script failed with exit code $exit_code"
    fi
}

trap cleanup EXIT

# Run main function
main "$@" 