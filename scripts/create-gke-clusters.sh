#!/bin/bash

# GKE Cluster Creation Script - June 2025 Blueprint
# Creates production-ready clusters with enhanced security and auto-scaling

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)

# Environment configurations
declare -A ENVIRONMENTS=(
  ["dev"]="us-central1 us-central1-a,us-central1-b,us-central1-c e2-standard-2 1-5"
  ["staging"]="us-central1 us-central1-a,us-central1-b,us-central1-c e2-standard-4 3-10" 
  ["prod"]="us-central1 us-central1-a,us-central1-b,us-central1-c e2-standard-4 3-15"
  ["dr"]="us-east1 us-east1-b,us-east1-c,us-east1-d e2-standard-4 3-10"
)

echo -e "${GREEN}🚀 Creating GKE Clusters - June 2025 Blueprint${NC}"
echo -e "${BLUE}Project: ${PROJECT_ID}${NC}"

# Function to create a single cluster
create_cluster() {
    local env=$1
    local config=${ENVIRONMENTS[$env]}
    read -r region zones machine_type scale_range <<< "$config"
    IFS='-' read -r min_nodes max_nodes <<< "$scale_range"
    
    local cluster_name="codet-${env}-gke"
    
    echo -e "\n${YELLOW}🔧 Creating ${env} cluster: ${cluster_name}${NC}"
    echo -e "${BLUE}Region: ${region}, Zones: ${zones}${NC}"
    echo -e "${BLUE}Machine: ${machine_type}, Scale: ${min_nodes}-${max_nodes}${NC}"
    
    if gcloud container clusters describe $cluster_name --region=$region &>/dev/null; then
        echo -e "${GREEN}✅ Cluster ${cluster_name} already exists${NC}"
        return 0
    fi
    
    # Create regional cluster with enhanced security
    gcloud container clusters create $cluster_name \
        --region $region \
        --node-locations $zones \
        --machine-type=$machine_type \
        --enable-autoscaling --min-nodes=$min_nodes --max-nodes=$max_nodes \
        --enable-autoprovisioning --max-cpu=2000 --max-memory=6000Gi \
        --enable-shielded-nodes --enable-network-policy \
        --workload-pool=${PROJECT_ID}.svc.id.goog \
        --release-channel=regular --enable-autoupgrade --enable-autorepair \
        --disk-size=200 --disk-type=pd-ssd \
        --enable-stackdriver-kubernetes \
        --enable-ip-alias \
        --enable-private-nodes --master-ipv4-cidr-block=10.1.0.0/28 \
        --cluster-secondary-range-name=pods-range \
        --services-secondary-range-name=services-range \
        --maintenance-window-start="2023-01-01T05:00:00Z" \
        --maintenance-window-end="2023-01-01T07:00:00Z" \
        --maintenance-window-recurrence="FREQ=WEEKLY;BYDAY=SU" \
        --labels=environment=${env},team=platform,security=enabled,cost-center=db \
        --tags=yugabyte-cluster,${env}-cluster
    
    # Create specialized node pools for production/staging
    if [[ "$env" == "prod" || "$env" == "staging" ]]; then
        create_node_pools $cluster_name $region $machine_type
    fi
    
    echo -e "${GREEN}✅ ${env} cluster created successfully${NC}"
}

# Function to create specialized node pools
create_node_pools() {
    local cluster_name=$1
    local region=$2
    local base_machine_type=$3
    
    echo -e "\n${YELLOW}🔧 Creating specialized node pools for ${cluster_name}${NC}"
    
    # YugabyteDB dedicated pool
    echo -e "${BLUE}Creating baseline pool for YB masters/tservers...${NC}"
    if ! gcloud container node-pools describe baseline --cluster=$cluster_name --region=$region &>/dev/null; then
        gcloud container node-pools create baseline \
            --cluster=$cluster_name \
            --region=$region \
            --machine-type=$base_machine_type \
            --num-nodes=3 \
            --min-nodes=3 \
            --max-nodes=15 \
            --enable-autoscaling \
            --node-labels=tier=base,workload-type=database \
            --disk-size=500 \
            --disk-type=pd-ssd \
            --enable-autorepair \
            --enable-autoupgrade
    fi
    
    # Surge pool for burst workloads
    echo -e "${BLUE}Creating surge pool for burst CPU...${NC}"
    if ! gcloud container node-pools describe surge --cluster=$cluster_name --region=$region &>/dev/null; then
        gcloud container node-pools create surge \
            --cluster=$cluster_name \
            --region=$region \
            --machine-type=c2-standard-8 \
            --num-nodes=0 \
            --min-nodes=0 \
            --max-nodes=5 \
            --enable-autoscaling \
            --node-labels=tier=surge,workload-type=burst \
            --disk-size=200 \
            --disk-type=pd-ssd \
            --enable-autorepair \
            --enable-autoupgrade
    fi
    
    # Spot pool for cost optimization
    echo -e "${BLUE}Creating spot pool for stateless workloads...${NC}"
    if ! gcloud container node-pools describe spot --cluster=$cluster_name --region=$region &>/dev/null; then
        gcloud container node-pools create spot \
            --cluster=$cluster_name \
            --region=$region \
            --machine-type=e2-medium \
            --num-nodes=0 \
            --min-nodes=0 \
            --max-nodes=10 \
            --enable-autoscaling \
            --preemptible \
            --node-labels=tier=spot,workload-type=stateless \
            --node-taints=spot=true:PreferNoSchedule \
            --disk-size=100 \
            --disk-type=pd-standard \
            --enable-autorepair \
            --enable-autoupgrade
    fi
}

# Function to configure security settings
configure_security() {
    local cluster_name=$1
    local region=$2
    
    echo -e "\n${YELLOW}🔒 Configuring security for ${cluster_name}${NC}"
    
    # Get cluster credentials
    gcloud container clusters get-credentials $cluster_name --region=$region
    
    # Apply Pod Security Standards
    echo -e "${BLUE}Applying Pod Security Standards...${NC}"
    kubectl label namespace default pod-security.kubernetes.io/enforce=restricted
    kubectl label namespace default pod-security.kubernetes.io/audit=restricted
    kubectl label namespace default pod-security.kubernetes.io/warn=restricted
}

# Main execution
main() {
    echo -e "\n${YELLOW}📋 Available environments: ${!ENVIRONMENTS[*]}${NC}"
    
    if [ $# -eq 0 ]; then
        echo -e "${BLUE}Creating all environments...${NC}"
        for env in "${!ENVIRONMENTS[@]}"; do
            create_cluster $env
            configure_security "codet-${env}-gke" $(echo ${ENVIRONMENTS[$env]} | cut -d' ' -f1)
        done
    else
        for env in "$@"; do
            if [[ -n "${ENVIRONMENTS[$env]:-}" ]]; then
                create_cluster $env
                configure_security "codet-${env}-gke" $(echo ${ENVIRONMENTS[$env]} | cut -d' ' -f1)
            else
                echo -e "${RED}❌ Unknown environment: $env${NC}"
                echo -e "${BLUE}Available: ${!ENVIRONMENTS[*]}${NC}"
                exit 1
            fi
        done
    fi
    
    echo -e "\n${GREEN}🎉 GKE cluster creation completed!${NC}"
    echo -e "${BLUE}Next steps:${NC}"
    echo -e "${BLUE}1. Deploy YugabyteDB with Helm${NC}"
    echo -e "${BLUE}2. Set up monitoring and alerting${NC}"
    echo -e "${BLUE}3. Configure backup and DR${NC}"
}

# Execute main function with all arguments
main "$@" 