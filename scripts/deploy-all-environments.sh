#!/bin/bash

# Deploy All YugabyteDB Environments Script
# This script creates namespaces and deploys all three YugabyteDB instances using Helm

set -euo pipefail

echo "🚀 Starting deployment of all YugabyteDB environments using Helm..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "❌ Helm is not installed or not in PATH"
    exit 1
fi

# Check if YugabyteDB repo is added
echo "🔍 Checking if YugabyteDB Helm repository is available..."
if ! helm repo list | grep -q yugabytedb; then
    echo "❌ YugabyteDB Helm repository not found. Please run './scripts/install-operator.sh' first."
    exit 1
fi

echo "✅ YugabyteDB Helm repository is available"

# Create namespaces for all environments
echo "📦 Creating namespaces for all environments..."
kubectl apply -f manifests/namespaces/environments.yaml

# Deploy Development environment
echo ""
echo "🔧 Deploying Development environment..."
helm install codet-dev-yb yugabytedb/yugabyte \
    --namespace codet-dev-yb \
    --values manifests/values/dev-values.yaml \
    --wait \
    --timeout=15m

# Deploy Staging environment
echo ""
echo "🔧 Deploying Staging environment..."
helm install codet-staging-yb yugabytedb/yugabyte \
    --namespace codet-staging-yb \
    --values manifests/values/staging-values.yaml \
    --wait \
    --timeout=15m

# Deploy Production environment
echo ""
echo "🔧 Deploying Production environment..."
helm install codet-prod-yb yugabytedb/yugabyte \
    --namespace codet-prod-yb \
    --values manifests/values/prod-values.yaml \
    --wait \
    --timeout=15m

echo ""
echo "⏳ Verifying all deployments..."

# Function to check deployment status
check_deployment_status() {
    local namespace=$1
    local release_name=$2
    
    echo "🔍 Checking $release_name in $namespace..."
    
    # Check Helm release status
    if helm status $release_name -n $namespace | grep -q "deployed"; then
        echo "✅ $release_name deployed successfully"
        
        # Check if pods are running
        local running_pods=$(kubectl get pods -n $namespace | grep -c "Running" || echo "0")
        local total_pods=$(kubectl get pods -n $namespace | grep -c "yb-" || echo "0")
        
        echo "   Pods: $running_pods/$total_pods running"
        return 0
    else
        echo "❌ $release_name deployment failed"
        return 1
    fi
}

# Check all deployments
check_deployment_status "codet-dev-yb" "codet-dev-yb"
check_deployment_status "codet-staging-yb" "codet-staging-yb"
check_deployment_status "codet-prod-yb" "codet-prod-yb"

echo ""
echo "📋 Deployment Summary:"
echo "===================="

for env in dev staging prod; do
    namespace="codet-${env}-yb"
    release_name="codet-${env}-yb"
    
    echo ""
    echo "🌟 $env Environment ($namespace):"
    echo "   Release: $release_name"
    
    if helm status $release_name -n $namespace | grep -q "deployed"; then
        echo "   Status: ✅ Deployed"
        echo "   Pods:"
        kubectl get pods -n $namespace | grep yb- | head -5
    else
        echo "   Status: ❌ Failed"
    fi
done

echo ""
echo "🎉 All environments deployed using Helm!"
echo ""
echo "📍 Access Information:"
echo "====================="
echo ""
echo "🔗 VPC Database Connections (from within cluster):"
echo ""
echo "Development:"
echo "  Host: codet-dev-yb-yb-tserver-service.codet-dev-yb.svc.cluster.local"
echo "  Port: 5433"
echo ""
echo "Staging:"
echo "  Host: codet-staging-yb-yb-tserver-service.codet-staging-yb.svc.cluster.local"
echo "  Port: 5433"
echo ""
echo "Production:"
echo "  Host: codet-prod-yb-yb-tserver-service.codet-prod-yb.svc.cluster.local"
echo "  Port: 5433"
echo ""
echo "🌐 Admin UI Access (via port-forward for management):"
echo ""
echo "Development:"
echo "  kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-master-ui 7000:7000"
echo "  Then access: http://localhost:7000"
echo ""
echo "Staging:"
echo "  kubectl port-forward -n codet-staging-yb svc/codet-staging-yb-yb-master-ui 7001:7000"
echo "  Then access: http://localhost:7001"
echo ""
echo "Production:"
echo "  kubectl port-forward -n codet-prod-yb svc/codet-prod-yb-yb-master-ui 7002:7000"
echo "  Then access: http://localhost:7002"
echo ""
echo "📋 Helm Management Commands:"
echo "=========================="
echo ""
echo "Check status:"
echo "  helm status codet-dev-yb -n codet-dev-yb"
echo ""
echo "Upgrade deployment:"
echo "  helm upgrade codet-dev-yb yugabytedb/yugabyte -n codet-dev-yb --values manifests/values/dev-values.yaml"
echo ""
echo "Uninstall deployment:"
echo "  helm uninstall codet-dev-yb -n codet-dev-yb"
echo ""
echo "Next steps:"
echo "  1. Wait for all pods to be in 'Running' state"
echo "  2. Configure database security with './scripts/setup-database-rbac.sh'"
echo "  3. Scale environments as needed with './scripts/scale-cluster.sh'" 