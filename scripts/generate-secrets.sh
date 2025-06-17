#!/bin/bash

# Generate Secure Database Secrets
# This script generates strong passwords and creates Kubernetes secrets

set -e

echo "🔐 Generating secure database credentials..."

# Function to generate secure password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-25
}

# Function to base64 encode
base64_encode() {
    echo -n "$1" | base64 -w 0
}

# Function to create secrets for an environment
create_environment_secrets() {
    local env=$1
    local namespace="codet-${env}-yb"
    
    echo "🔧 Creating secrets for $env environment..."
    
    # Generate strong passwords
    local admin_password=$(generate_password)
    local app_password=$(generate_password)
    
    # Base64 encode passwords
    local admin_password_b64=$(base64_encode "$admin_password")
    local app_password_b64=$(base64_encode "$app_password")
    
    # Create the secret manifest
    cat > "manifests/secrets/codet-${env}-db-credentials.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: codet-${env}-db-credentials
  namespace: ${namespace}
  labels:
    app: yugabytedb
    environment: ${env}
type: Opaque
data:
  admin-password: ${admin_password_b64}
  app-password: ${app_password_b64}
  yugabyte-password: eXVnYWJ5dGU=  # default 'yugabyte' for initial setup
stringData:
  admin-username: codet_${env}_admin
  app-username: codet_${env}_app
  database-name: codet_${env}
  host: codet-${env}-yb-yb-tserver-service.${namespace}.svc.cluster.local
  port: "5433"
EOF

    echo "✅ Secret manifest created: manifests/secrets/codet-${env}-db-credentials.yaml"
    
    # Apply the secret to Kubernetes
    if kubectl get namespace "$namespace" &>/dev/null; then
        kubectl apply -f "manifests/secrets/codet-${env}-db-credentials.yaml"
        echo "✅ Secret applied to Kubernetes: $namespace/codet-${env}-db-credentials"
    else
        echo "⚠️  Namespace $namespace not found. Secret manifest created but not applied."
    fi
    
    # Create a secure credentials file for reference (readable only by owner)
    mkdir -p credentials
    cat > "credentials/codet-${env}-credentials-secure.txt" << EOF
# YugabyteDB Credentials for ${env} Environment
# Generated on $(date)
# KEEP THESE CREDENTIALS SECURE!

Database: codet_${env}
Admin Username: codet_${env}_admin
Admin Password: ${admin_password}
Application Username: codet_${env}_app
Application Password: ${app_password}

Kubernetes Secret: ${namespace}/codet-${env}-db-credentials

Connection examples:
psql -h \$(kubectl get secret codet-${env}-db-credentials -n ${namespace} -o jsonpath='{.data.host}' | base64 -d) -p 5433 -U codet_${env}_app -d codet_${env}

To get passwords from Kubernetes:
kubectl get secret codet-${env}-db-credentials -n ${namespace} -o jsonpath='{.data.admin-password}' | base64 -d
kubectl get secret codet-${env}-db-credentials -n ${namespace} -o jsonpath='{.data.app-password}' | base64 -d
EOF

    chmod 600 "credentials/codet-${env}-credentials-secure.txt"
    echo "💾 Secure credentials saved to credentials/codet-${env}-credentials-secure.txt"
}

# Check if openssl is available
if ! command -v openssl &> /dev/null; then
    echo "❌ openssl is required but not installed. Please install openssl."
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is required but not installed. Please install kubectl."
    exit 1
fi

# Create secrets directory
mkdir -p manifests/secrets
mkdir -p credentials

# Generate secrets for all environments
for env in dev staging prod; do
    create_environment_secrets "$env"
    echo ""
done

echo "🎉 All database secrets generated successfully!"
echo ""
echo "📋 Summary:"
echo "==========="
echo "✅ Kubernetes Secret manifests created in manifests/secrets/"
echo "✅ Secure credential files created in credentials/"
echo "✅ All passwords are cryptographically secure (25 characters)"
echo ""
echo "🔒 Security Notes:"
echo "=================="
echo "• Credential files are mode 600 (owner read-write only)"
echo "• Passwords are stored as Kubernetes secrets (base64 encoded)"
echo "• Original plaintext credentials should be deleted after migration"
echo ""
echo "📝 Next Steps:"
echo "=============="
echo "1. Update scripts to use 'kubectl get secret' instead of plaintext files"
echo "2. Update applications to mount secrets as environment variables"
echo "3. Delete old plaintext credential files"
echo "4. Consider using sealed-secrets or external-secrets for GitOps" 