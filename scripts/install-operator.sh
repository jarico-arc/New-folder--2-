#!/bin/bash

# YugabyteDB Helm Repository Setup Script
# This script prepares the YugabyteDB Helm repository for deployment

set -euo pipefail

echo "🚀 Setting up YugabyteDB Helm repository..."

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

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "❌ Helm is not installed. Please install Helm first."
    exit 1
fi

echo "✅ Helm is available"

# Add YugabyteDB Helm repository
echo "📥 Adding YugabyteDB Helm repository..."
helm repo add yugabytedb https://charts.yugabyte.com
helm repo update

# Verify repository is added
echo "🔍 Verifying YugabyteDB charts are available..."
if helm search repo yugabytedb/yugabyte | grep -q yugabyte; then
    echo "✅ YugabyteDB charts are available"
    helm search repo yugabytedb/yugabyte | head -5
else
    echo "❌ YugabyteDB charts not found"
    exit 1
fi

echo ""
echo "🎉 YugabyteDB Helm repository setup completed!"
echo ""
echo "📋 Available deployment options:"
echo "  • Direct Helm deployment (recommended)"
echo "  • File-based deployment using values files"
echo ""
echo "Next steps:"
echo "  1. Run './scripts/deploy-all-environments.sh' to deploy database instances"
echo "  2. Configure database security with './scripts/setup-database-rbac.sh'" 