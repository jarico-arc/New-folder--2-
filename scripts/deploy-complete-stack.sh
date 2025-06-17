#!/bin/bash

# Complete YugabyteDB Stack Deployment Script
# This script deploys the entire production-ready YugabyteDB stack

set -e

echo "🚀 Starting complete YugabyteDB stack deployment..."

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
./scripts/generate-secrets.sh

# Deploy environments
echo "🌍 Deploying environments..."
./scripts/deploy-all-environments.sh

# Deploy monitoring
echo "📊 Deploying monitoring..."
kubectl apply -f manifests/monitoring/

# Apply security policies
echo "🔒 Applying security policies..."
kubectl apply -f manifests/policies/

# Wait for clusters
echo "⏳ Waiting for clusters to be ready..."
sleep 60

# Setup RBAC
echo "🔐 Setting up database RBAC..."
./scripts/setup-database-rbac.sh

echo "🎉 Deployment completed!"
echo "Access Grafana: kubectl port-forward -n monitoring svc/grafana 3000:3000"
echo ""
echo "📋 Bitbucket Pipeline Features:"
echo "- Automatic validation on pull requests"
echo "- Manual deployment gates for staging/production"
echo "- Custom pipelines for infrastructure deployment"
echo "- Comprehensive testing with Kind clusters" 