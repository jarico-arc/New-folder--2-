#!/bin/bash

# YugabyteDB Multi-Cluster Connectivity Test Script
# Tests connectivity to all 3 YugabyteDB clusters

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Cluster configurations
CLUSTERS=(
    "codet-dev-yb:us-west1"
    "codet-staging-yb:us-central1"
    "codet-prod-yb:us-east1"
)

echo -e "${GREEN}🔗 YugabyteDB Multi-Cluster Connectivity Test${NC}"

# Function to test cluster connectivity
test_cluster_connectivity() {
    local cluster_name=$1
    local region=$2
    
    echo -e "\n${BLUE}Testing connectivity to $cluster_name ($region)${NC}"
    
    # Switch to cluster context
    if ! kubectl config use-context "${cluster_name}-context" &>/dev/null; then
        echo -e "${RED}❌ Cannot switch to context ${cluster_name}-context${NC}"
        return 1
    fi
    
    # Check if pods are running
    echo -e "${YELLOW}Checking pod status...${NC}"
    if ! kubectl get pods -n $cluster_name | grep -E "(yb-master|yb-tserver)" | grep Running; then
        echo -e "${RED}❌ Pods not running in $cluster_name${NC}"
        return 1
    fi
    
    # Test master connectivity
    echo -e "${YELLOW}Testing master connectivity...${NC}"
    if kubectl exec -n $cluster_name yb-master-0 -- bash -c "curl -s http://localhost:7000/api/v1/masters" | grep -q "leaders"; then
        echo -e "${GREEN}✅ Master connectivity successful${NC}"
    else
        echo -e "${RED}❌ Master connectivity failed${NC}"
        return 1
    fi
    
    # Test tserver connectivity
    echo -e "${YELLOW}Testing tserver connectivity...${NC}"
    if kubectl exec -n $cluster_name yb-tserver-0 -- bash -c "curl -s http://localhost:9000/api/v1/tablet-servers" | grep -q "tablet_servers"; then
        echo -e "${GREEN}✅ TServer connectivity successful${NC}"
    else
        echo -e "${RED}❌ TServer connectivity failed${NC}"
        return 1
    fi
    
    # Test YSQL connectivity
    echo -e "${YELLOW}Testing YSQL connectivity...${NC}"
    if kubectl exec -n $cluster_name yb-tserver-0 -- ysqlsh -h localhost -c "SELECT version();" | grep -q "PostgreSQL"; then
        echo -e "${GREEN}✅ YSQL connectivity successful${NC}"
    else
        echo -e "${RED}❌ YSQL connectivity failed${NC}"
        return 1
    fi
    
    # Test YCQL connectivity  
    echo -e "${YELLOW}Testing YCQL connectivity...${NC}"
    # FIXED: Made version check more flexible to support different YugabyteDB versions
    if kubectl exec -n $cluster_name yb-tserver-0 -- ycqlsh localhost -e "SELECT release_version FROM system.local;" | grep -q "2\.[0-9][0-9]"; then
        echo -e "${GREEN}✅ YCQL connectivity successful${NC}"
    else
        echo -e "${RED}❌ YCQL connectivity failed${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ All connectivity tests passed for $cluster_name${NC}"
    return 0
}

# Function to test multi-cluster connectivity
test_multi_cluster_connectivity() {
    echo -e "\n${BLUE}Testing multi-cluster connectivity...${NC}"
    
    # Use dev cluster as the test base
    kubectl config use-context "codet-dev-yb-context"
    
    # Test if dev cluster can reach other clusters
    echo -e "${YELLOW}Testing cross-cluster master connectivity...${NC}"
    
    local master_addresses="yb-master-0.yb-masters.codet-dev-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-staging-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100"
    
    if kubectl exec -n codet-dev-yb yb-master-0 -- yb-admin --master_addresses=$master_addresses list_all_tablet_servers | grep -q "tablet_servers"; then
        echo -e "${GREEN}✅ Multi-cluster connectivity successful${NC}"
    else
        echo -e "${RED}❌ Multi-cluster connectivity failed${NC}"
        return 1
    fi
    
    # Test replica placement
    echo -e "${YELLOW}Testing replica placement...${NC}"
    if kubectl exec -n codet-dev-yb yb-master-0 -- yb-admin --master_addresses=$master_addresses get_universe_config | grep -q "placement_cloud"; then
        echo -e "${GREEN}✅ Replica placement configured correctly${NC}"
    else
        echo -e "${RED}❌ Replica placement configuration issue${NC}"
        return 1
    fi
}

# Function to test load balancer connectivity
test_load_balancer_connectivity() {
    echo -e "\n${BLUE}Testing load balancer connectivity...${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region <<< "$cluster_config"
        
        echo -e "${YELLOW}Testing load balancers for $cluster_name...${NC}"
        kubectl config use-context "${cluster_name}-context"
        
        # Get master UI load balancer
        local master_ip=$(kubectl get svc -n $cluster_name yb-master-ui -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        if [ "$master_ip" != "pending" ] && [ "$master_ip" != "" ]; then
            echo -e "${GREEN}✅ Master UI LB: $master_ip${NC}"
        else
            echo -e "${YELLOW}⏳ Master UI LB IP pending${NC}"
        fi
        
        # Get tserver load balancer
        local tserver_ip=$(kubectl get svc -n $cluster_name yb-tserver-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
        if [ "$tserver_ip" != "pending" ] && [ "$tserver_ip" != "" ]; then
            echo -e "${GREEN}✅ TServer LB: $tserver_ip${NC}"
        else
            echo -e "${YELLOW}⏳ TServer LB IP pending${NC}"
        fi
    done
}

# Function to show connection information
show_connection_info() {
    echo -e "\n${BLUE}=== Connection Information ===${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region <<< "$cluster_config"
        
        echo -e "\n${YELLOW}$cluster_name ($region):${NC}"
        kubectl config use-context "${cluster_name}-context"
        
        # Get service information
        echo "Services:"
        kubectl get svc -n $cluster_name | grep -E "(yb-master|yb-tserver)"
        
        echo -e "\n${GREEN}Connection commands:${NC}"
        echo "# YSQL Shell"
        echo "kubectl exec -n $cluster_name -it yb-tserver-0 -- ysqlsh -h yb-tserver-0.yb-tservers.$cluster_name"
        echo ""
        echo "# YCQL Shell"
        echo "kubectl exec -n $cluster_name -it yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.$cluster_name"
        echo ""
    done
}

# Function to perform comprehensive health check
comprehensive_health_check() {
    echo -e "\n${BLUE}=== Comprehensive Health Check ===${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region <<< "$cluster_config"
        
        echo -e "\n${YELLOW}Health check for $cluster_name:${NC}"
        kubectl config use-context "${cluster_name}-context"
        
        # Check pod status
        echo "Pod Status:"
        kubectl get pods -n $cluster_name -o wide
        
        # Check persistent volumes
        echo -e "\nPersistent Volumes:"
        kubectl get pvc -n $cluster_name
        
        # Check resource usage
        echo -e "\nResource Usage:"
        kubectl top pods -n $cluster_name --no-headers 2>/dev/null || echo "Metrics server not available"
        
        # Check events
        echo -e "\nRecent Events:"
        kubectl get events -n $cluster_name --sort-by='.lastTimestamp' | tail -5
    done
}

# Main execution
main() {
    local test_type="${1:-all}"
    
    case $test_type in
        "connectivity")
            for cluster_config in "${CLUSTERS[@]}"; do
                IFS=':' read -r cluster_name region <<< "$cluster_config"
                test_cluster_connectivity $cluster_name $region
            done
            ;;
        "multi-cluster")
            test_multi_cluster_connectivity
            ;;
        "load-balancer")
            test_load_balancer_connectivity
            ;;
        "health")
            comprehensive_health_check
            ;;
        "info")
            show_connection_info
            ;;
        "all")
            # Run all tests
            for cluster_config in "${CLUSTERS[@]}"; do
                IFS=':' read -r cluster_name region <<< "$cluster_config"
                test_cluster_connectivity $cluster_name $region
            done
            test_multi_cluster_connectivity
            test_load_balancer_connectivity
            show_connection_info
            ;;
        *)
            echo "Usage: $0 [connectivity|multi-cluster|load-balancer|health|info|all]"
            echo ""
            echo "Test types:"
            echo "  connectivity   - Test basic connectivity to each cluster"
            echo "  multi-cluster  - Test cross-cluster connectivity"
            echo "  load-balancer  - Test load balancer status"
            echo "  health         - Comprehensive health check"
            echo "  info           - Show connection information"
            echo "  all            - Run all tests (default)"
            exit 1
            ;;
    esac
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl is not installed or not in PATH${NC}"
    exit 1
fi

# Run main function
main "$@"

echo -e "\n${GREEN}🎉 Connectivity tests completed!${NC}"