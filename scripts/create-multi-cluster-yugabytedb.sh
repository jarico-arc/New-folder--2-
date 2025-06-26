#!/bin/bash

# Multi-Cluster YugabyteDB Deployment Script
# Creates 3 YugabyteDB clusters: Codet-Dev-YB, Codet-Staging-YB, Codet-Prod-YB
# Following: https://docs.yugabyte.com/preview/deploy/kubernetes/multi-cluster/gke/helm-chart/

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION_DEV="us-west1"
REGION_STAGING="us-central1" 
REGION_PROD="us-east1"
ZONE_DEV="us-west1-b"
ZONE_STAGING="us-central1-b"
ZONE_PROD="us-east1-b"
YUGABYTE_VERSION="2.25.2"

# Cluster configurations
CLUSTERS=(
    "codet-dev-yb:${REGION_DEV}:${ZONE_DEV}:dev"
    "codet-staging-yb:${REGION_STAGING}:${ZONE_STAGING}:staging"
    "codet-prod-yb:${REGION_PROD}:${ZONE_PROD}:prod"
)

echo -e "${GREEN}🚀 Multi-Cluster YugabyteDB Deployment${NC}"
echo -e "${BLUE}Project: ${PROJECT_ID}${NC}"
echo -e "${BLUE}YugabyteDB Version: ${YUGABYTE_VERSION}${NC}"

# Function to check prerequisites
check_prerequisites() {
    echo -e "\n${YELLOW}📋 Checking prerequisites...${NC}"
    
    local missing=0
    for cmd in gcloud kubectl helm; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}❌ $cmd is not installed${NC}"
            missing=1
        else
            echo -e "${GREEN}✅ $cmd is installed${NC}"
        fi
    done
    
    if [ $missing -eq 1 ]; then
        echo -e "${RED}Please install missing prerequisites${NC}"
        exit 1
    fi
    
    # Check if user is authenticated
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 > /dev/null; then
        echo -e "${RED}❌ Please authenticate with gcloud: gcloud auth login${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✅ All prerequisites met${NC}"
}

# Function to create private VPC network
create_vpc_network() {
    echo -e "\n${YELLOW}🌐 Creating private VPC network...${NC}"
    
    local vpc_name="yugabytedb-private-vpc"
    
    # Create VPC network
    if ! gcloud compute networks describe $vpc_name &>/dev/null; then
        echo -e "${BLUE}Creating VPC network: $vpc_name${NC}"
        gcloud compute networks create $vpc_name \
            --subnet-mode=custom \
            --bgp-routing-mode=global
    else
        echo -e "${GREEN}✅ VPC network $vpc_name already exists${NC}"
    fi
    
    # Create subnets for each environment with non-overlapping secondary ranges
    local subnets=(
        "dev-subnet:${REGION_DEV}:10.1.0.0/16:172.16.0.0/14:172.20.0.0/20"
        "staging-subnet:${REGION_STAGING}:10.2.0.0/16:172.24.0.0/14:172.28.0.0/20"
        "prod-subnet:${REGION_PROD}:10.3.0.0/16:172.32.0.0/14:172.36.0.0/20"
    )
    
    for subnet_config in "${subnets[@]}"; do
        IFS=':' read -r subnet_name region cidr pods_range services_range <<< "$subnet_config"
        
        if ! gcloud compute networks subnets describe $subnet_name --region=$region &>/dev/null; then
            echo -e "${BLUE}Creating subnet: $subnet_name in $region${NC}"
            gcloud compute networks subnets create $subnet_name \
                --network=$vpc_name \
                --region=$region \
                --range=$cidr \
                --secondary-range=pods=$pods_range,services=$services_range
        else
            echo -e "${GREEN}✅ Subnet $subnet_name already exists${NC}"
        fi
    done
    
    # Create firewall rules for internal communication
    local firewall_rules=(
        "allow-yugabytedb-internal:10.0.0.0/8:tcp:7000,tcp:7100,tcp:9000,tcp:9100,tcp:5433,tcp:9042,tcp:6379"
        "allow-ssh-private:10.0.0.0/8:tcp:22"
        "allow-dns-private:10.0.0.0/8:tcp:53,udp:53"
    )
    
    for rule_config in "${firewall_rules[@]}"; do
        IFS=':' read -r rule_name source_range protocols <<< "$rule_config"
        
        if ! gcloud compute firewall-rules describe $rule_name &>/dev/null; then
            echo -e "${BLUE}Creating firewall rule: $rule_name${NC}"
            gcloud compute firewall-rules create $rule_name \
                --network=$vpc_name \
                --allow=$protocols \
                --source-ranges=$source_range \
                --target-tags=yugabytedb
        else
            echo -e "${GREEN}✅ Firewall rule $rule_name already exists${NC}"
        fi
    done
    
    echo -e "${GREEN}✅ Private VPC network setup complete${NC}"
}

# Function to create GKE clusters
create_gke_clusters() {
    echo -e "\n${YELLOW}☸️ Creating GKE clusters...${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "\n${BLUE}Creating cluster: $cluster_name in $region${NC}"
        
        # Determine subnet name based on environment
        local subnet_name="${env}-subnet"
        
        # Set cluster size and master CIDR based on environment
        local node_count
        local machine_type
        local master_cidr

        if [ "$env" = "prod" ]; then
            node_count=3
            machine_type="e2-standard-8"
            master_cidr="192.168.3.0/28"
        elif [ "$env" = "staging" ]; then
            node_count=2
            machine_type="e2-standard-4"
            master_cidr="192.168.2.0/28"
        else # dev
            node_count=2 # Increased from 1 for monitoring stack
            machine_type="e2-standard-4"
            master_cidr="192.168.1.0/28"
        fi
        
        # Check if cluster already exists
        if gcloud container clusters describe $cluster_name --region=$region &>/dev/null; then
            echo -e "${GREEN}✅ Cluster $cluster_name already exists${NC}"

            # Ensure node count is correct for existing clusters
            echo -e "${BLUE}Ensuring node count for $cluster_name is set to $node_count...${NC}"
            gcloud container clusters resize $cluster_name \
                --region=$region \
                --num-nodes=$node_count \
                --quiet

            continue
        fi
        
        # Create private GKE cluster
        gcloud container clusters create $cluster_name \
            --region=$region \
            --node-locations=$zone \
            --num-nodes=$node_count \
            --machine-type=$machine_type \
            --disk-size=100GB \
            --disk-type=pd-ssd \
            --network=yugabytedb-private-vpc \
            --subnetwork=$subnet_name \
            --enable-private-nodes \
            --master-ipv4-cidr=$master_cidr \
            --enable-ip-alias \
            --enable-network-policy \
            --enable-shielded-nodes \
            --node-labels=environment=$env,cluster=$cluster_name \
            --tags=yugabytedb,$env \
            --workload-pool=${PROJECT_ID}.svc.id.goog \
            --release-channel=stable
        
        # Get cluster credentials
        gcloud container clusters get-credentials $cluster_name --region=$region
        
        # Add cluster context alias
        kubectl config rename-context \
            "gke_${PROJECT_ID}_${region}_${cluster_name}" \
            "${cluster_name}-context"
        
        echo -e "${GREEN}✅ Cluster $cluster_name created successfully${NC}"
    done
}

# Function to authorize external IP for kubectl access
authorize_kubectl_access() {
    echo -e "\n${YELLOW}🔐 Authorizing external IP for kubectl access...${NC}"

    # Get external IP of the current machine
    local external_ip=$(curl -s --fail ifconfig.me || curl -s --fail icanhazip.com)
    if [ -z "$external_ip" ]; then
        echo -e "${RED}❌ Could not determine external IP address. Please check your internet connection.${NC}"
        exit 1
    fi
    echo -e "${BLUE}Detected external IP: ${external_ip}${NC}"

    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"

        echo -e "${BLUE}Authorizing IP for $cluster_name...${NC}"
        gcloud container clusters update $cluster_name \
            --region=$region \
            --enable-master-authorized-networks \
            --master-authorized-networks="${external_ip}/32" \
            --quiet
    done

    echo -e "${GREEN}✅ External IP authorized for all clusters.${NC}"
}

# Function to create storage classes
create_storage_classes() {
    echo -e "\n${YELLOW}💾 Creating storage classes...${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "${BLUE}Creating storage class for $cluster_name${NC}"
        
        # Switch to cluster context
        kubectl config use-context "${cluster_name}-context"
        
        # Create storage class
        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: "standard-rwo"
  labels:
    environment: "${env}"
    cluster: "${cluster_name}"
provisioner: kubernetes.io/gce-pd
parameters:
  type: pd-ssd
  replication-type: regional-pd
  zones: "${zone}"
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
EOF
        
        echo -e "${GREEN}✅ Storage class created for $cluster_name${NC}"
    done
}

# Function to set up global DNS
setup_global_dns() {
    echo -e "\n${YELLOW}🌍 Setting up global DNS...${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "${BLUE}Configuring DNS for $cluster_name${NC}"
        
        # Switch to cluster context
        kubectl config use-context "${cluster_name}-context"
        
        # Create DNS configuration
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-dns
  namespace: kube-system
  labels:
    environment: "${env}"
data:
  stubDomains: |
    {
      "codet-dev-yb.local": ["10.1.0.10"],
      "codet-staging-yb.local": ["10.2.0.10"],
      "codet-prod-yb.local": ["10.3.0.10"]
    }
EOF
        
        # Restart kube-dns
        kubectl rollout restart deployment/kube-dns -n kube-system
        
        echo -e "${GREEN}✅ DNS configured for $cluster_name${NC}"
    done
}

# Function to create YugabyteDB namespaces
create_namespaces() {
    echo -e "\n${YELLOW}📦 Creating YugabyteDB namespaces...${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "${BLUE}Creating namespace for $cluster_name${NC}"
        
        # Switch to cluster context
        kubectl config use-context "${cluster_name}-context"
        
        # Create namespace
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: "${cluster_name}"
  labels:
    environment: "${env}"
    cluster: "${cluster_name}"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
EOF
        
        echo -e "${GREEN}✅ Namespace created for $cluster_name${NC}"
    done
}

# Function to create override files
create_override_files() {
    echo -e "\n${YELLOW}📄 Creating Helm override files...${NC}"
    
    # Create overrides directory
    mkdir -p manifests/values/multi-cluster
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "${BLUE}Creating override file for $cluster_name${NC}"
        
        # Build master addresses for multi-cluster setup
        local master_addresses=""
        for other_cluster in "${CLUSTERS[@]}"; do
            IFS=':' read -r other_name other_region other_zone other_env <<< "$other_cluster"
            if [ -n "$master_addresses" ]; then
                master_addresses="${master_addresses},"
            fi
            master_addresses="${master_addresses}yb-master-0.yb-masters.${other_name}.svc.cluster.local:7100"
        done
        
        # Set resources based on environment
        local master_cpu="1000m"
        local master_memory="2Gi"
        local tserver_cpu="2000m"
        local tserver_memory="4Gi"
        local storage_size="100Gi"
        
        if [ "$env" = "prod" ]; then
            master_cpu="2000m"
            master_memory="4Gi"
            tserver_cpu="4000m"
            tserver_memory="8Gi"
            storage_size="500Gi"
        elif [ "$env" = "staging" ]; then
            master_cpu="1500m"
            master_memory="3Gi"
            tserver_cpu="3000m"
            tserver_memory="6Gi"
            storage_size="200Gi"
        fi
        
        # Create override file
        cat > "manifests/values/multi-cluster/overrides-${cluster_name}.yaml" <<EOF
# YugabyteDB Multi-Cluster Override File for ${cluster_name}
# Environment: ${env}
# Region: ${region}, Zone: ${zone}

isMultiAz: true
AZ: ${zone}

# Multi-cluster master addresses
masterAddresses: "${master_addresses}"

# Storage configuration
storage:
  master:
    storageClass: "standard-rwo"
    size: "${storage_size}"
  tserver:
    storageClass: "standard-rwo"
    size: "${storage_size}"

# Replica configuration
replicas:
  master: 1
  tserver: 1
  totalMasters: 3

# Resource configuration
resource:
  master:
    requests:
      cpu: "${master_cpu}"
      memory: "${master_memory}"
    limits:
      cpu: "${master_cpu}"
      memory: "${master_memory}"
  tserver:
    requests:
      cpu: "${tserver_cpu}"
      memory: "${tserver_memory}"
    limits:
      cpu: "${tserver_cpu}"
      memory: "${tserver_memory}"

# Global flags for multi-cluster setup
gflags:
  master:
    placement_cloud: "gke"
    placement_region: "${region}"
    placement_zone: "${zone}"
    leader_failure_max_missed_heartbeat_periods: 10
    raft_heartbeat_interval_ms: 1000
    enable_ysql: true
    default_memory_limit_to_ram_ratio: 0.85
  tserver:
    placement_cloud: "gke"
    placement_region: "${region}"
    placement_zone: "${zone}"
    leader_failure_max_missed_heartbeat_periods: 10
    raft_heartbeat_interval_ms: 1000
    enable_ysql: true
    default_memory_limit_to_ram_ratio: 0.85
    # CDC configuration
    cdc_max_stream_intent_records: 10000

# Security configuration
auth:
  enabled: $([ "$env" = "prod" ] && echo "true" || echo "false")
  useSecretFile: $([ "$env" = "prod" ] && echo "true" || echo "false")

tls:
  enabled: $([ "$env" = "prod" ] && echo "true" || echo "false")
  nodeToNode: $([ "$env" = "prod" ] && echo "true" || echo "false")
  clientToServer: $([ "$env" = "prod" ] && echo "true" || echo "false")

# Service configuration
services:
  master:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-internal: "true"
      cloud.google.com/load-balancer-type: "Internal"
  tserver:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-internal: "true"
      cloud.google.com/load-balancer-type: "Internal"

# Pod configuration
pod:
  master:
    tolerations:
      - key: "environment"
        operator: "Equal"
        value: "${env}"
        effect: "NoSchedule"
    nodeSelector:
      environment: "${env}"
    annotations:
      cluster.name: "${cluster_name}"
      environment: "${env}"
  tserver:
    tolerations:
      - key: "environment"
        operator: "Equal"
        value: "${env}"
        effect: "NoSchedule"
    nodeSelector:
      environment: "${env}"
    annotations:
      cluster.name: "${cluster_name}"
      environment: "${env}"

# Network policy
networkPolicy:
  enabled: true

# Monitoring
serviceMonitor:
  enabled: false

# Environment-specific configurations
$(if [ "$env" = "dev" ]; then cat <<DEV_EOF

# Development specific settings
domainName: codet-dev-yb.local
image:
  tag: "2.25.2-b0"
DEV_EOF
elif [ "$env" = "staging" ]; then cat <<STAGING_EOF

# Staging specific settings  
domainName: codet-staging-yb.local
image:
  tag: "2.25.2"
STAGING_EOF
elif [ "$env" = "prod" ]; then cat <<PROD_EOF

# Production specific settings
domainName: codet-prod-yb.local
image:
  tag: "2.25.2"

# Production backup configuration
backups:
  enabled: true
  schedule: "0 2 * * *"  # Daily at 2 AM
  retention: "30d"
PROD_EOF
fi)
EOF
        
        echo -e "${GREEN}✅ Override file created: manifests/values/multi-cluster/overrides-${cluster_name}.yaml${NC}"
    done
}

# Function to install YugabyteDB
install_yugabytedb() {
    echo -e "\n${YELLOW}🗄️ Installing YugabyteDB clusters...${NC}"
    
    # Add Helm repository
    helm repo add yugabytedb https://charts.yugabyte.com
    helm repo update
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "\n${BLUE}Installing YugabyteDB in $cluster_name${NC}"
        
        # Switch to cluster context
        kubectl config use-context "${cluster_name}-context"
        
        # Install YugabyteDB
        helm upgrade --install $cluster_name yugabytedb/yugabyte \
            --version $YUGABYTE_VERSION \
            --namespace $cluster_name \
            --create-namespace \
            -f "manifests/values/multi-cluster/overrides-${cluster_name}.yaml" \
            --wait \
            --timeout=20m
        
        echo -e "${GREEN}✅ YugabyteDB installed in $cluster_name${NC}"
    done
}

# Function to configure region-aware replica placement
configure_replica_placement() {
    echo -e "\n${YELLOW}⚙️ Configuring region-aware replica placement...${NC}"
    
    # Use the first cluster (dev) to configure placement
    local first_cluster="codet-dev-yb"
    kubectl config use-context "${first_cluster}-context"
    
    # Build placement info
    local placement_info=""
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        if [ -n "$placement_info" ]; then
            placement_info="${placement_info},"
        fi
        placement_info="${placement_info}gke.${region}.${zone}"
    done
    
    echo -e "${BLUE}Setting replica placement: $placement_info${NC}"
    
    # Configure replica placement
    kubectl exec -it -n $first_cluster yb-master-0 -- bash -c \
        "/home/yugabyte/master/bin/yb-admin \
        --master_addresses yb-master-0.yb-masters.codet-dev-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-staging-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 \
        modify_placement_info $placement_info 3"
    
    echo -e "${GREEN}✅ Region-aware replica placement configured${NC}"
}

# Function to validate deployment
validate_deployment() {
    echo -e "\n${YELLOW}✅ Validating deployment...${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "\n${BLUE}Validating $cluster_name${NC}"
        
        # Switch to cluster context
        kubectl config use-context "${cluster_name}-context"
        
        # Check pods
        echo "Pods:"
        kubectl get pods -n $cluster_name
        
        # Check services
        echo -e "\nServices:"
        kubectl get services -n $cluster_name
        
        # Check if YugabyteDB is ready
        kubectl wait --for=condition=ready pod -l app=yb-master -n $cluster_name --timeout=300s
        kubectl wait --for=condition=ready pod -l app=yb-tserver -n $cluster_name --timeout=300s
        
        echo -e "${GREEN}✅ $cluster_name validation complete${NC}"
    done
}

# Function to show connection information
show_connection_info() {
    echo -e "\n${YELLOW}🔗 Connection Information${NC}"
    
    for cluster_config in "${CLUSTERS[@]}"; do
        IFS=':' read -r cluster_name region zone env <<< "$cluster_config"
        
        echo -e "\n${BLUE}=== $cluster_name ($env) ===${NC}"
        
        # Switch to cluster context
        kubectl config use-context "${cluster_name}-context"
        
        # Get external IPs
        local master_ui_ip=$(kubectl get service yb-master-ui -n $cluster_name -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Pending")
        local tserver_ip=$(kubectl get service yb-tserver-service -n $cluster_name -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Pending")
        
        echo -e "${GREEN}Master UI: https://${master_ui_ip}:7000${NC}"
        echo -e "${GREEN}YSQL: ${tserver_ip}:5433${NC}"
        echo -e "${GREEN}YCQL: ${tserver_ip}:9042${NC}"
        echo -e "${GREEN}Redis: ${tserver_ip}:6379${NC}"
        
        echo -e "\n${YELLOW}Connection commands:${NC}"
        echo "# YSQL Shell"
        echo "kubectl exec -n $cluster_name -it yb-tserver-0 -- ysqlsh -h yb-tserver-0.yb-tservers.$cluster_name"
        echo ""
        echo "# YCQL Shell"
        echo "kubectl exec -n $cluster_name -it yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.$cluster_name"
    done
}

# Main execution
main() {
    echo -e "${GREEN}Starting multi-cluster YugabyteDB deployment...${NC}"
    
    check_prerequisites
    create_vpc_network
    create_gke_clusters
    authorize_kubectl_access
    create_storage_classes
    setup_global_dns
    create_namespaces
    create_override_files
    install_yugabytedb
    configure_replica_placement
    validate_deployment
    show_connection_info
    
    echo -e "\n${GREEN}🎉 Multi-cluster YugabyteDB deployment completed successfully!${NC}"
    echo -e "${BLUE}You now have 3 YugabyteDB clusters running in private VPC:${NC}"
    echo -e "${GREEN}- Codet-Dev-YB (${REGION_DEV})${NC}"
    echo -e "${GREEN}- Codet-Staging-YB (${REGION_STAGING})${NC}"
    echo -e "${GREEN}- Codet-Prod-YB (${REGION_PROD})${NC}"
}

# Handle script arguments
case "${1:-all}" in
    "prerequisites")
        check_prerequisites
        ;;
    "vpc")
        create_vpc_network
        ;;
    "clusters")
        create_gke_clusters
        authorize_kubectl_access
        ;;
    "storage")
        create_storage_classes
        ;;
    "dns")
        setup_global_dns
        ;;
    "namespaces")
        create_namespaces
        ;;
    "overrides")
        create_override_files
        ;;
    "install")
        install_yugabytedb
        ;;
    "placement")
        configure_replica_placement
        ;;
    "validate")
        validate_deployment
        ;;
    "info")
        show_connection_info
        ;;
    "all")
        main
        ;;
    *)
        echo "Usage: $0 [prerequisites|vpc|clusters|storage|dns|namespaces|overrides|install|placement|validate|info|all]"
        exit 1
        ;;
esac 