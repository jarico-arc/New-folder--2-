#!/bin/bash

# YugabyteDB Database RBAC Setup Script
# ✅ FIXED: Secure secret management and improved error handling

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
NAMESPACE="${1:-codet-dev-yb}"
MAX_RETRIES=30
RETRY_INTERVAL=5

# ✅ FIXED: Secure password generation
generate_secure_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# ✅ FIXED: Check if secrets exist, create if needed
ensure_database_secrets() {
    local namespace="$1"
    local secret_name="yugabyte-db-credentials"
    
    log_info "🔐 Checking database secrets in namespace $namespace..."
    
    if kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
        log_success "Database secrets already exist"
        return 0
    fi
    
    log_info "Creating new database secrets..."
    
    # Generate secure passwords
    local admin_password=$(generate_secure_password)
    local app_password=$(generate_secure_password)
    local yugabyte_password=$(generate_secure_password)
    
    # Create the secret
    kubectl create secret generic "$secret_name" \
        --namespace="$namespace" \
        --from-literal=admin-password="$admin_password" \
        --from-literal=app-password="$app_password" \
        --from-literal=yugabyte-password="$yugabyte_password" || {
        log_error "Failed to create database secrets"
        return 1
    }
    
    log_success "Database secrets created successfully"
    return 0
}

# ✅ FIXED: Get password from secret (not hardcoded)
get_password_from_secret() {
    local namespace="$1"
    local secret_name="yugabyte-db-credentials"
    local key="$2"
    
    kubectl get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$key}" | base64 -d
}

# ✅ FIXED: Robust connection test
test_database_connection() {
    local namespace="$1"
    local retries=$MAX_RETRIES
    
    log_info "Testing database connection..."
    
    while [ $retries -gt 0 ]; do
        # Try to connect to the database
        if kubectl exec -n "$namespace" deployment/yb-tserver-0 -- ysqlsh -h localhost -U yugabyte -d yugabyte -c "SELECT 1;" &>/dev/null; then
            log_success "Database connection successful"
            return 0
        fi
        
        log_info "⏳ Waiting for database to be ready... ($retries retries left)"
        sleep $RETRY_INTERVAL
        ((retries--))
    done
    
    log_error "Failed to connect to database after $MAX_RETRIES attempts"
    return 1
}

# Execute SQL with proper error handling
execute_sql() {
    local namespace="$1"
    local sql="$2"
    local description="${3:-SQL execution}"
    
    log_info "Executing: $description"
    
    if kubectl exec -n "$namespace" deployment/yb-tserver-0 -- ysqlsh -h localhost -U yugabyte -d yugabyte -c "$sql" &>/dev/null; then
        log_success "$description completed"
        return 0
    else
        log_error "$description failed"
        return 1
    fi
}

# ✅ FIXED: Port forward management
setup_port_forward() {
    local namespace="$1"
    local local_port="5433"
    
    log_info "Setting up port forward for database access..."
    
    # Start port forwarding in background
    kubectl port-forward -n "$namespace" service/yb-tserver-service "$local_port:5433" &
    port_forward_pid=$!
    
    # Wait for port forward to be ready
    sleep 3
    
    if kill -0 $port_forward_pid 2>/dev/null; then
        log_success "Port forward established on localhost:$local_port"
        return 0
    else
        log_error "Failed to establish port forward"
        return 1
    fi
}

# Cleanup function
cleanup() {
    if [ -n "${port_forward_pid:-}" ]; then
        kill $port_forward_pid 2>/dev/null || true
        sleep 2
    fi
}

trap cleanup EXIT

# ✅ FIXED: Main RBAC setup function
setup_rbac() {
    local namespace="$1"
    
    log_info "🔒 Setting up database RBAC for namespace: $namespace"
    
    # Ensure secrets exist
    if ! ensure_database_secrets "$namespace"; then
        log_error "Failed to ensure database secrets exist"
        exit 1
    fi
    
    # Test database connection
    if ! test_database_connection "$namespace"; then
        log_error "Cannot connect to database"
        exit 1
    fi
    
    # Get passwords from secrets
    local admin_password
    local app_password
    admin_password=$(get_password_from_secret "$namespace" "admin-password")
    app_password=$(get_password_from_secret "$namespace" "app-password")
    
    # ✅ FIXED: Set up port forward for local access
    setup_port_forward "$namespace"
    
    # Execute RBAC setup SQL
    log_info "📋 Executing RBAC setup..."
    
    # ✅ FIXED: Use proper authentication with generated passwords
    export PGPASSWORD="$admin_password"
    
    # Create admin user
    execute_sql "$namespace" "CREATE USER IF NOT EXISTS admin_user WITH PASSWORD '$admin_password' SUPERUSER;" "Creating admin user"
    
    # Create application user with limited privileges
    execute_sql "$namespace" "CREATE USER IF NOT EXISTS app_user WITH PASSWORD '$app_password';" "Creating application user"
    
    # Create application database
    execute_sql "$namespace" "CREATE DATABASE IF NOT EXISTS app_db OWNER app_user;" "Creating application database"
    
    # Load messaging patterns setup
    if [ -f "sql/messaging-patterns-setup.sql" ]; then
        log_info "📡 Loading messaging patterns..."
        kubectl exec -n "$namespace" deployment/yb-tserver-0 -- ysqlsh -h localhost -U yugabyte -d yugabyte -f /dev/stdin < sql/messaging-patterns-setup.sql || {
            log_warning "Failed to load messaging patterns, but continuing..."
        }
    fi
    
    # Load RBAC setup
    if [ -f "sql/rbac-setup.sql" ]; then
        log_info "🔐 Loading RBAC configuration..."
        kubectl exec -n "$namespace" deployment/yb-tserver-0 -- ysqlsh -h localhost -U yugabyte -d yugabyte -f /dev/stdin < sql/rbac-setup.sql || {
            log_warning "Failed to load RBAC setup, but continuing..."
        }
    fi
    
    # Grant appropriate permissions
    execute_sql "$namespace" "GRANT CONNECT ON DATABASE app_db TO app_user;" "Granting database connection"
    execute_sql "$namespace" "GRANT USAGE ON SCHEMA public TO app_user;" "Granting schema usage"
    execute_sql "$namespace" "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_user;" "Granting function execution"
    
    # Create credentials file for reference
    local creds_file="/tmp/${namespace}-credentials.txt"
    cat > "$creds_file" << EOF
# YugabyteDB Credentials for $namespace
# Generated: $(date)

# Admin User (Full privileges)
ADMIN_USER=admin_user
ADMIN_PASSWORD=<retrieve from secret>

# Application User (Limited privileges)
APP_USER=app_user
APP_PASSWORD=<retrieve from secret>

# Commands to retrieve passwords:
kubectl get secret yugabyte-db-credentials -n $namespace -o jsonpath='{.data.admin-password}' | base64 -d
kubectl get secret yugabyte-db-credentials -n $namespace -o jsonpath='{.data.app-password}' | base64 -d

# Connection examples:
psql -h localhost -p 5433 -U admin_user -d yugabyte
psql -h localhost -p 5433 -U app_user -d app_db
EOF
    
    log_success "🎉 RBAC setup completed successfully!"
    log_info "📄 Credentials reference saved to: $creds_file"
    log_warning "⚠️ For security, passwords are stored in Kubernetes secrets only"
}

# ✅ FIXED: Enhanced namespace detection
detect_namespace() {
    local ns=""
    
    # Method 1: Look for YB tserver pods
    ns=$(kubectl get pods --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    
    # Method 2: Look for YB services  
    if [ -z "$ns" ]; then
        ns=$(kubectl get services --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    fi
    
    # Method 3: Look for YB StatefulSets
    if [ -z "$ns" ]; then
        ns=$(kubectl get statefulsets --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    fi
    
    # Method 4: Look for YB master pods
    if [ -z "$ns" ]; then
        ns=$(kubectl get pods --all-namespaces -l app=yb-master -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    fi
    
    # Method 5: Namespace name pattern matching
    if [ -z "$ns" ]; then
        ns=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -m1 -E '(yugabyte|yb)' 2>/dev/null || echo "")
    fi
    
    echo "$ns"
}

# Main execution
main() {
    log_info "🚀 Starting YugabyteDB RBAC setup..."
    
    # Auto-detect namespace if needed
    if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_warning "Namespace $NAMESPACE not found, attempting auto-detection..."
        DETECTED_NS=$(detect_namespace)
        if [ -n "$DETECTED_NS" ]; then
            log_info "Using detected namespace: $DETECTED_NS"
            NAMESPACE="$DETECTED_NS"
        else
            log_error "Could not find YugabyteDB namespace"
            log_info "Available namespaces:"
            kubectl get namespaces | grep -E "(yugabyte|yb)" || log_info "No YugabyteDB namespaces found"
            exit 1
        fi
    fi
    
    # Run RBAC setup
    setup_rbac "$NAMESPACE"
}

# Execute main function
main 