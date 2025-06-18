#!/bin/bash

# Deploy All YugabyteDB Environments Script
# This script creates namespaces and deploys all three YugabyteDB instances

set -e

echo "🚀 Starting deployment of all YugabyteDB environments..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if operator is running
echo "🔍 Checking if YugabyteDB operator is running..."
if ! kubectl get pods -n yb-operator | grep -q "Running"; then
    echo "❌ YugabyteDB operator is not running. Please run './scripts/install-operator.sh' first."
    exit 1
fi

echo "✅ YugabyteDB operator is running"

# Create namespaces for all environments
echo "📦 Creating namespaces for all environments..."
kubectl apply -f manifests/namespaces/environments.yaml

# Deploy Development environment
echo ""
echo "🔧 Deploying Development environment..."
kubectl apply -f manifests/clusters/codet-dev-yb-cluster.yaml

# Deploy Staging environment
echo ""
echo "🔧 Deploying Staging environment..."
kubectl apply -f manifests/clusters/codet-staging-yb-cluster.yaml

# Deploy Production environment
echo ""
echo "🔧 Deploying Production environment..."
kubectl apply -f manifests/clusters/codet-prod-yb-cluster.yaml

echo ""
echo "⏳ Waiting for all clusters to be ready..."
echo "This may take several minutes..."

# Function to check cluster status
check_cluster_status() {
    local namespace=$1
    local cluster_name=$2
    
    echo "🔍 Checking $cluster_name in $namespace..."
    
    # Wait for the cluster to be created
    timeout=600  # 10 minutes
    elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if kubectl get ybcluster $cluster_name -n $namespace &>/dev/null; then
            echo "✅ $cluster_name created successfully"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo "⏳ Waiting for $cluster_name to be created... (${elapsed}s/${timeout}s)"
    done
    
    if [ $elapsed -ge $timeout ]; then
        echo "❌ Timeout waiting for $cluster_name to be created"
        return 1
    fi
}

# Check all clusters
check_cluster_status "codet-dev-yb" "codet-dev-yb"
check_cluster_status "codet-staging-yb" "codet-staging-yb"
check_cluster_status "codet-prod-yb" "codet-prod-yb"

echo ""
echo "📋 Deployment Summary:"
echo "===================="

for env in dev staging prod; do
    namespace="codet-${env}-yb"
    cluster_name="codet-${env}-yb"
    
    echo ""
    echo "🌟 $env Environment ($namespace):"
    echo "   Cluster: $cluster_name"
    
    if kubectl get ybcluster $cluster_name -n $namespace &>/dev/null; then
        echo "   Status: ✅ Deployed"
        echo "   Pods:"
        kubectl get pods -n $namespace | grep -E "(master|tserver)" | head -5
    else
        echo "   Status: ❌ Failed"
    fi
done

echo ""
echo "🎉 All environments deployed!"
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
echo "Next steps:"
echo "  1. Wait for all pods to be in 'Running' state"
echo "  2. Configure database security with './scripts/setup-database-rbac.sh'"
echo "  3. Scale environments as needed with './scripts/scale-cluster.sh'" 