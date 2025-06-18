#!/bin/bash

# Scale YugabyteDB Cluster Script
# This script scales a specific YugabyteDB cluster by updating tserver replicas

set -e

# Function to display usage
usage() {
    echo "Usage: $0 <environment> <new-replica-count>"
    echo ""
    echo "Environments: dev, staging, prod"
    echo "Example: $0 staging 5"
    echo ""
    echo "This will scale the staging environment to 5 tserver replicas"
    exit 1
}

# Check arguments
if [ $# -ne 2 ]; then
    usage
fi

ENVIRONMENT=$1
NEW_REPLICAS=$2

# Validate environment
case $ENVIRONMENT in
    dev|staging|prod)
        ;;
    *)
        echo "❌ Invalid environment: $ENVIRONMENT"
        usage
        ;;
esac

# Validate replica count
if ! [[ "$NEW_REPLICAS" =~ ^[0-9]+$ ]] || [ "$NEW_REPLICAS" -lt 1 ]; then
    echo "❌ Invalid replica count: $NEW_REPLICAS (must be a positive integer)"
    exit 1
fi

# Set variables based on environment
NAMESPACE="codet-${ENVIRONMENT}-yb"
CLUSTER_NAME="codet-${ENVIRONMENT}-yb"
MANIFEST_FILE="manifests/clusters/codet-${ENVIRONMENT}-yb-cluster.yaml"

echo "🚀 Scaling $ENVIRONMENT environment..."
echo "   Namespace: $NAMESPACE"
echo "   Cluster: $CLUSTER_NAME"
echo "   New tserver replicas: $NEW_REPLICAS"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is not installed or not in PATH"
    exit 1
fi

# Check if cluster exists
if ! kubectl get ybcluster $CLUSTER_NAME -n $NAMESPACE &>/dev/null; then
    echo "❌ Cluster $CLUSTER_NAME not found in namespace $NAMESPACE"
    echo "Please deploy the environment first with './scripts/deploy-all-environments.sh'"
    exit 1
fi

# Get current replica count
CURRENT_REPLICAS=$(kubectl get ybcluster $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.spec.tserver.replicas}')
echo "📊 Current tserver replicas: $CURRENT_REPLICAS"

if [ "$CURRENT_REPLICAS" -eq "$NEW_REPLICAS" ]; then
    echo "ℹ️  Cluster is already at the desired replica count ($NEW_REPLICAS)"
    exit 0
fi

# Create a backup of the current manifest
cp "$MANIFEST_FILE" "${MANIFEST_FILE}.backup.$(date +%Y%m%d-%H%M%S)"

# Update the manifest file
echo "📝 Updating manifest file: $MANIFEST_FILE"

# Use a more robust approach to update the replicas count
# First, try a simple replacement of the specific tserver replicas line
if sed -i.tmp "/tserver:/,/replicas:/ {
    s/replicas: $CURRENT_REPLICAS/replicas: $NEW_REPLICAS/
}" "$MANIFEST_FILE" 2>/dev/null; then
    echo "✅ Successfully updated replicas from $CURRENT_REPLICAS to $NEW_REPLICAS"
else
    echo "❌ Failed to update manifest file"
    exit 1
fi

# Clean up temporary file
rm -f "${MANIFEST_FILE}.tmp"

# Apply the updated manifest
echo "🔧 Applying updated configuration..."
kubectl apply -f "$MANIFEST_FILE"

# Monitor the scaling process
echo "⏳ Monitoring scaling progress..."
echo "This may take several minutes depending on the scale of change..."

# Wait for the scaling operation to complete
timeout=900  # 15 minutes
elapsed=0

while [ $elapsed -lt $timeout ]; do
    # Get current status
    READY_REPLICAS=$(kubectl get ybcluster $CLUSTER_NAME -n $NAMESPACE -o jsonpath='{.status.tserver.replicas}' 2>/dev/null || echo "0")
    
    if [ "$READY_REPLICAS" = "$NEW_REPLICAS" ]; then
        echo "✅ Scaling completed successfully!"
        break
    fi
    
    echo "⏳ Scaling in progress... Ready: $READY_REPLICAS/$NEW_REPLICAS (${elapsed}s/${timeout}s)"
    sleep 30
    elapsed=$((elapsed + 30))
done

if [ $elapsed -ge $timeout ]; then
    echo "⚠️  Scaling operation timeout reached. Check cluster status manually."
    echo "   Current status: $READY_REPLICAS/$NEW_REPLICAS replicas ready"
fi

# Show final cluster status
echo ""
echo "📋 Final Cluster Status:"
echo "======================="
kubectl get ybcluster $CLUSTER_NAME -n $NAMESPACE
echo ""
echo "Pod Status:"
kubectl get pods -n $NAMESPACE | grep tserver

echo ""
if [ "$NEW_REPLICAS" -gt "$CURRENT_REPLICAS" ]; then
    echo "🎉 Cluster scaled UP from $CURRENT_REPLICAS to $NEW_REPLICAS tserver replicas"
    echo "💡 Data rebalancing will happen automatically in the background"
else
    echo "🎉 Cluster scaled DOWN from $CURRENT_REPLICAS to $NEW_REPLICAS tserver replicas"
    echo "💡 Data rebalancing will happen automatically in the background"
fi

echo ""
echo "📍 Monitor cluster status with:"
echo "   kubectl get pods -n $NAMESPACE -w"
echo "   kubectl get ybcluster $CLUSTER_NAME -n $NAMESPACE -w" 