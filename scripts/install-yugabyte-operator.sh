#!/bin/bash

# Install YugabyteDB Kubernetes Operator
# This replaces the generic operator install with YB-specific operator

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🚀 Installing YugabyteDB Kubernetes Operator...${NC}"

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl is not installed${NC}"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo -e "${RED}❌ helm is not installed${NC}"
    exit 1
fi

# Add YugabyteDB Helm repository
echo -e "${YELLOW}📦 Adding YugabyteDB Helm repository...${NC}"
helm repo add yugabytedb https://charts.yugabyte.com
helm repo update

# Create operator namespace
echo -e "${YELLOW}📦 Creating operator namespace...${NC}"
kubectl create namespace yugabyte-operator --dry-run=client -o yaml | kubectl apply -f -

# Install the operator with specific version
OPERATOR_VERSION="2.22.0"
echo -e "${YELLOW}🔧 Installing YugabyteDB Operator v${OPERATOR_VERSION}...${NC}"
helm upgrade --install yb-operator yugabytedb/yugabyte-operator \
    --namespace yugabyte-operator \
    --version ${OPERATOR_VERSION} \
    --set image.tag=2.22.0.0-b15 \
    --set rbac.create=true \
    --set serviceAccount.create=true \
    --wait

# Verify operator is running
echo -e "${YELLOW}⏳ Waiting for operator to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=yugabyte-operator \
    -n yugabyte-operator --timeout=300s

echo -e "${GREEN}✅ YugabyteDB Operator installed successfully!${NC}"

# Display operator status
echo -e "\n${YELLOW}📋 Operator Status:${NC}"
kubectl get pods -n yugabyte-operator
kubectl get crd | grep yugabyte

echo -e "\n${YELLOW}📍 Next steps:${NC}"
echo "1. Create YBCluster resources in respective namespaces"
echo "2. Apply backup schedules for production"
echo "3. Configure monitoring integration" 