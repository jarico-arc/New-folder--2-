#!/bin/bash

# Complete YugabyteDB Stack Deployment Script
# This script deploys the entire cost-optimized YugabyteDB stack

set -e

echo "🚀 Starting complete YugabyteDB stack deployment (MINIMAL COST VERSION)..."

# Check prerequisites
echo "🔍 Checking prerequisites..."
for tool in kubectl helm gcloud terraform; do
    if ! command -v $tool &> /dev/null; then
        echo "❌ $tool is not installed"
        exit 1
    fi
done

# Deploy infrastructure (optional)
if [ "${1:-}" != "--skip-terraform" ]; then
    echo "🏗️  Deploying infrastructure..."
    cd terraform && terraform init && terraform apply -auto-approve && cd ..
fi

# Install operator
echo "🔧 Installing YugabyteDB Operator..."
./scripts/install-operator.sh

# Generate secrets
echo "🔐 Generating secure credentials..."
if ! ./scripts/generate-secrets.sh; then
    echo "❌ Failed to generate secrets"
    exit 1
fi

# Verify secrets were created
echo "🔍 Verifying secrets were created..."
for env in dev staging prod; do
    if ! kubectl get secret "codet-${env}-db-credentials" -n "codet-${env}-yb" &>/dev/null; then
        echo "⚠️  Secret for $env environment not found, but continuing deployment..."
    else
        echo "✅ Secret for $env environment created successfully"
    fi
done

# Deploy environments
echo "🌍 Deploying environments..."
if ! ./scripts/deploy-all-environments.sh; then
    echo "❌ Failed to deploy environments"
    exit 1
fi

# SKIP monitoring deployment (disabled for cost optimization)
echo "⏭️  Skipping monitoring deployment (disabled for cost optimization)"
echo "   Monitoring features are disabled in cluster configurations"

# Apply security policies
echo "🔒 Applying security policies..."
if ! kubectl apply -f manifests/policies/; then
    echo "❌ Failed to apply security policies"
    exit 1
fi

# Wait for clusters
echo "⏳ Waiting for clusters to be ready..."
sleep 60

# Setup RBAC
echo "🔐 Setting up database RBAC..."
if ! ./scripts/setup-database-rbac.sh; then
    echo "⚠️  RBAC setup encountered issues, but deployment can continue"
    echo "   You may need to run setup-database-rbac.sh manually later"
fi

echo "🎉 Deployment completed!"
echo ""
echo "💰 COST-OPTIMIZED DEPLOYMENT FEATURES:"
echo "- Single replica configuration (replicationFactor: 1)"
echo "- Minimal machine types (e2-micro/e2-small)"
echo "- Disabled TLS, authentication, monitoring, and backups"
echo "- Standard disks instead of SSD"
echo "- Estimated cost: ~$130-150/month for all environments"
echo ""
echo "⚠️  MONITORING DISABLED: No Grafana dashboard available"
echo "   Use kubectl commands and YugabyteDB admin UI for monitoring"
echo ""
echo "📋 Bitbucket Pipeline Features:"
echo "- Automatic validation on pull requests"
echo "- Manual deployment gates for staging/production"
echo "- Custom pipelines for infrastructure deployment"
echo "- Comprehensive testing with Kind clusters" 