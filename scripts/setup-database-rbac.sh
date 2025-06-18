#!/bin/bash

# Database RBAC Setup Script
# This script configures role-based access control for all YugabyteDB environments

set -e

echo "🔐 Setting up Database RBAC for all environments..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Function to check if cluster is ready
check_cluster_ready() {
    local namespace=$1
    local cluster_name=$2
    
    echo "🔍 Checking if $cluster_name is ready..."
    
    # Check if at least one tserver pod is running
    if kubectl get pods -n $namespace | grep -q "${cluster_name}.*tserver.*Running"; then
        echo "✅ $cluster_name is ready"
        return 0
    else
        echo "❌ $cluster_name is not ready"
        return 1
    fi
}

# Function to setup RBAC for a specific environment
setup_environment_rbac() {
    local environment=$1
    local namespace="codet-${environment}-yb"
    local cluster_name="codet-${environment}-yb"
    local app_role="codet_${environment}_app"
    local admin_role="codet_${environment}_admin"
    
    echo ""
    echo "🔧 Setting up RBAC for $environment environment..."
    echo "   Namespace: $namespace"
    echo "   Cluster: $cluster_name"
    echo "   App Role: $app_role"
    echo "   Admin Role: $admin_role"
    
    # Read credentials from Kubernetes secrets
    local secret_name="codet-${environment}-db-credentials"
    
    if ! kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
        echo "❌ Kubernetes secret $secret_name not found in namespace $namespace"
        echo "Please run scripts/generate-secrets.sh first"
        return 1
    fi
    
    # Extract credentials from Kubernetes secret
    local admin_password=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.admin-password}' | base64 -d)
    local app_password=$(kubectl get secret "$secret_name" -n "$namespace" -o jsonpath='{.data.app-password}' | base64 -d)
    
    if [ -z "$admin_password" ] || [ -z "$app_password" ]; then
        echo "❌ Failed to retrieve passwords from Kubernetes secret"
        return 1
    fi
    
    echo "🔑 Retrieved credentials from Kubernetes secret"
    
    # Check if cluster is ready
    if ! check_cluster_ready $namespace $cluster_name; then
        echo "⚠️  Skipping $environment - cluster not ready"
        return 1
    fi
    
    # Get the YSQL service
    local ysql_service="${cluster_name}-yb-tserver-service"
    
    # Check if netcat is available for connection testing
    if ! command -v nc &> /dev/null; then
        echo "⚠️  netcat (nc) not found. Will skip connection test."
        echo "   Please ensure netcat is installed for better reliability."
    fi
    
    # Port forward to connect to the database
    echo "🔌 Setting up connection to $environment database..."
    kubectl port-forward -n $namespace svc/$ysql_service 5433:5433 &
    local port_forward_pid=$!
    
    # Set up cleanup trap for this specific port forward
    trap "kill $port_forward_pid 2>/dev/null || true; sleep 2" EXIT
    
    # Wait a moment for port forward to establish
    sleep 5
    
    # Check if we can connect (if netcat is available)
    if command -v nc &> /dev/null; then
        if ! nc -z localhost 5433 2>/dev/null; then
            echo "❌ Cannot connect to $environment database"
            kill $port_forward_pid 2>/dev/null || true
            sleep 2
            return 1
        fi
    else
        echo "⚠️  Skipping connection test (netcat not available)"
        echo "   Proceeding with database operations..."
    fi
    
    echo "✅ Connected to $environment database"
    
    # Create a temporary SQL file for this environment
    local temp_sql="/tmp/rbac_setup_${environment}.sql"
    
    # Generate environment-specific SQL
    cat > $temp_sql << EOF
-- RBAC Setup for $environment environment
-- Generated on $(date)

-- Create admin role for $environment
CREATE ROLE $admin_role WITH LOGIN PASSWORD '$admin_password' SUPERUSER;

-- Create application role for $environment (restricted access)
CREATE ROLE $app_role WITH LOGIN PASSWORD '$app_password';

-- Create application database if it doesn't exist
CREATE DATABASE codet_${environment} OWNER $admin_role;

-- Connect to the application database
\c codet_${environment}

-- Create application schema
CREATE SCHEMA IF NOT EXISTS app_schema AUTHORIZATION $admin_role;

-- Grant usage on schema to application role
GRANT USAGE ON SCHEMA app_schema TO $app_role;

-- Example table structure (you can modify this)
CREATE TABLE IF NOT EXISTS app_schema.users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS app_schema.audit_log (
    id SERIAL PRIMARY KEY,
    user_id INTEGER,
    action VARCHAR(255) NOT NULL,
    details JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Example stored procedures for secure data access
CREATE OR REPLACE FUNCTION app_schema.create_user(
    p_username VARCHAR,
    p_email VARCHAR
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS \$\$
DECLARE
    v_user_id INTEGER;
BEGIN
    -- Validate input
    IF p_username IS NULL OR LENGTH(TRIM(p_username)) = 0 THEN
        RAISE EXCEPTION 'Username cannot be empty';
    END IF;
    
    IF p_email IS NULL OR LENGTH(TRIM(p_email)) = 0 THEN
        RAISE EXCEPTION 'Email cannot be empty';
    END IF;
    
    -- Insert user
    INSERT INTO app_schema.users (username, email)
    VALUES (p_username, p_email)
    RETURNING id INTO v_user_id;
    
    -- Log the action
    INSERT INTO app_schema.audit_log (user_id, action, details)
    VALUES (v_user_id, 'USER_CREATED', json_build_object('username', p_username, 'email', p_email));
    
    RETURN v_user_id;
END;
\$\$;

CREATE OR REPLACE FUNCTION app_schema.get_user_by_username(
    p_username VARCHAR
) RETURNS TABLE(id INTEGER, username VARCHAR, email VARCHAR, created_at TIMESTAMP)
LANGUAGE plpgsql
SECURITY DEFINER
AS \$\$
BEGIN
    RETURN QUERY
    SELECT u.id, u.username, u.email, u.created_at
    FROM app_schema.users u
    WHERE u.username = p_username;
END;
\$\$;

CREATE OR REPLACE FUNCTION app_schema.update_user_email(
    p_user_id INTEGER,
    p_new_email VARCHAR
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS \$\$
DECLARE
    v_old_email VARCHAR;
    v_updated BOOLEAN := FALSE;
BEGIN
    -- Get old email for audit
    SELECT email INTO v_old_email FROM app_schema.users WHERE id = p_user_id;
    
    IF v_old_email IS NULL THEN
        RAISE EXCEPTION 'User not found';
    END IF;
    
    -- Update email
    UPDATE app_schema.users 
    SET email = p_new_email, updated_at = CURRENT_TIMESTAMP
    WHERE id = p_user_id;
    
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    
    IF v_updated THEN
        -- Log the action
        INSERT INTO app_schema.audit_log (user_id, action, details)
        VALUES (p_user_id, 'EMAIL_UPDATED', 
                json_build_object('old_email', v_old_email, 'new_email', p_new_email));
    END IF;
    
    RETURN v_updated > 0;
END;
\$\$;

-- Grant EXECUTE permissions ONLY to the application role
GRANT EXECUTE ON FUNCTION app_schema.create_user(VARCHAR, VARCHAR) TO $app_role;
GRANT EXECUTE ON FUNCTION app_schema.get_user_by_username(VARCHAR) TO $app_role;
GRANT EXECUTE ON FUNCTION app_schema.update_user_email(INTEGER, VARCHAR) TO $app_role;

-- EXPLICITLY REVOKE all table permissions from application role
REVOKE ALL ON TABLE app_schema.users FROM $app_role;
REVOKE ALL ON TABLE app_schema.audit_log FROM $app_role;
REVOKE ALL ON SCHEMA public FROM $app_role;

-- Ensure application role cannot create objects
REVOKE CREATE ON SCHEMA app_schema FROM $app_role;
REVOKE CREATE ON DATABASE codet_${environment} FROM $app_role;

-- Display configuration summary
SELECT 'RBAC Configuration for $environment completed' AS status;
EOF

    # Execute the SQL
    echo "📝 Executing RBAC setup SQL for $environment..."
    export PGPASSWORD="yugabyte"  # Default YugabyteDB password
    
    if psql -h localhost -p 5433 -U yugabyte -d yugabyte -f $temp_sql; then
        echo "✅ RBAC setup completed for $environment"
        
        # Create reference file for credentials (passwords are in K8s secrets)
        local creds_file="credentials/codet-${environment}-rbac-info.txt"
        mkdir -p credentials
        
        echo "# YugabyteDB RBAC Configuration for $environment Environment" > $creds_file
        echo "# Generated on $(date)" >> $creds_file
        echo "# Passwords are stored in Kubernetes secrets" >> $creds_file
        echo "" >> $creds_file
        echo "Database: codet_${environment}" >> $creds_file
        echo "Admin Role: $admin_role" >> $creds_file
        echo "Application Role: $app_role" >> $creds_file
        echo "Kubernetes Secret: $secret_name" >> $creds_file
        echo "Namespace: $namespace" >> $creds_file
        echo "" >> $creds_file
        echo "Get passwords from Kubernetes:" >> $creds_file
        echo "kubectl get secret $secret_name -n $namespace -o jsonpath='{.data.admin-password}' | base64 -d" >> $creds_file
        echo "kubectl get secret $secret_name -n $namespace -o jsonpath='{.data.app-password}' | base64 -d" >> $creds_file
        echo "" >> $creds_file
        echo "Connection examples:" >> $creds_file
        echo "export APP_PASSWORD=\$(kubectl get secret $secret_name -n $namespace -o jsonpath='{.data.app-password}' | base64 -d)" >> $creds_file
        echo "psql -h <host> -p 5433 -U $app_role -d codet_${environment}" >> $creds_file
        echo "" >> $creds_file
        echo "Available functions for $app_role:" >> $creds_file
        echo "- app_schema.create_user(username, email)" >> $creds_file
        echo "- app_schema.get_user_by_username(username)" >> $creds_file
        echo "- app_schema.update_user_email(user_id, new_email)" >> $creds_file
        
        chmod 600 $creds_file
        echo "💾 RBAC information saved to $creds_file"
    else
        echo "❌ RBAC setup failed for $environment"
    fi
    
    # Clean up
    echo "🧹 Cleaning up resources for $environment..."
    if [ ! -z "$port_forward_pid" ]; then
        kill $port_forward_pid 2>/dev/null || true
        # Wait for graceful termination
        sleep 3
        # Force kill if still running
        if kill -0 $port_forward_pid 2>/dev/null; then
            kill -9 $port_forward_pid 2>/dev/null || true
        fi
    fi
    rm -f $temp_sql
    # Clear the trap for this function
    trap - EXIT
}

# Setup RBAC for all environments
echo "🚀 Starting RBAC setup for all environments..."

# Create credentials directory
mkdir -p credentials

setup_environment_rbac "dev"
setup_environment_rbac "staging"
setup_environment_rbac "prod"

echo ""
echo "🎉 Database RBAC setup completed!"
echo ""
echo "📁 Credentials have been saved to the 'credentials/' directory"
echo "🔒 These files contain sensitive passwords - keep them secure!"
echo ""
echo "📝 Security Implementation Summary:"
echo "=================================="
echo "✅ Application roles can ONLY execute stored procedures"
echo "✅ Application roles have NO direct table access"
echo "✅ All data operations are audited via stored procedures"
echo "✅ Attempting direct SQL (db.execute()) will result in permission denied"
echo ""
echo "🧪 Test the security by connecting as the application role and trying:"
echo "   SELECT * FROM app_schema.users;  -- This should FAIL"
echo "   SELECT app_schema.create_user('test', 'test@example.com');  -- This should WORK"
echo ""
echo "📍 Connection information is in the credentials files." 