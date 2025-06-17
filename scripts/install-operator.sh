#!/bin/bash

# YugabyteDB Operator Installation Script
# This script installs the YugabyteDB operator in your GKE cluster

set -e

echo "🚀 Starting YugabyteDB Operator installation..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if we can connect to the cluster
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
fi

echo "✅ kubectl connection verified"

# Create operator namespace
echo "📦 Creating YugabyteDB operator namespace..."
kubectl apply -f manifests/operator/namespace.yaml

# Add YugabyteDB Helm repository
echo "📥 Adding YugabyteDB Helm repository..."
if ! command -v helm &> /dev/null; then
    echo "❌ Helm is not installed. Please install Helm first."
    exit 1
fi

helm repo add yugabytedb https://charts.yugabyte.com
helm repo update

# Install the YugabyteDB operator
echo "⚙️  Installing YugabyteDB operator..."
helm install yugabyte-operator yugabytedb/yugabyte-k8s-operator \
    --namespace yb-operator \
    --create-namespace \
    --wait \
    --timeout=10m

# Verify installation
echo "🔍 Verifying operator installation..."
kubectl wait --for=condition=ready pod -l app=yugabyte-k8s-operator -n yb-operator --timeout=300s

if kubectl get pods -n yb-operator | grep -q "Running"; then
    echo "✅ YugabyteDB operator installed successfully!"
    echo "📋 Operator status:"
    kubectl get pods -n yb-operator
else
    echo "❌ Operator installation failed"
    exit 1
fi

echo ""
echo "🎉 YugabyteDB operator is ready!"
echo "Next steps:"
echo "  1. Run './scripts/deploy-all-environments.sh' to deploy database instances"
echo "  2. Configure database security with './scripts/setup-database-rbac.sh'" 