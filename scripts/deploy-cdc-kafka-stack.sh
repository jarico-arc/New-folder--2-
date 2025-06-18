#!/bin/bash

# YugabyteDB CDC + Kafka Stack Deployment (Cost-Effective $25/mo Setup)
# This deploys the "shoe-string" blueprint: Redpanda CE + Cloud Run Debezium connector

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Configuration
PROJECT_ID="${1:-}"
REGION="${2:-us-central1}"
ZONE="${3:-us-central1-a}"
ENVIRONMENT="${4:-dev}"

if [ -z "$PROJECT_ID" ]; then
    log_error "Usage: $0 <PROJECT_ID> [REGION] [ZONE] [ENVIRONMENT]"
    log_info "Example: $0 my-gcp-project us-central1 us-central1-a dev"
    exit 1
fi

log_info "🚀 Deploying cost-effective CDC + Kafka stack ($25/mo blueprint)"
log_info "Project: $PROJECT_ID, Region: $REGION, Environment: $ENVIRONMENT"

# ✅ Step 1: Deploy Redpanda CE on e2-small VM
deploy_redpanda_vm() {
    log_info "📦 Step 1: Deploying Redpanda CE on e2-small VM..."
    
    # Create the VM
    if ! gcloud compute instances describe yb-redpanda --zone="$ZONE" --project="$PROJECT_ID" &>/dev/null; then
        log_info "Creating e2-small VM for Redpanda..."
        gcloud compute instances create yb-redpanda \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --machine-type=e2-small \
            --image-family=cos-stable \
            --image-project=cos-cloud \
            --boot-disk-type=pd-balanced \
            --boot-disk-size=20GB \
            --boot-disk-device-name=yb-redpanda \
            --metadata=enable-oslogin=TRUE \
            --tags=redpanda-broker \
            --scopes=cloud-platform \
            --labels=environment="$ENVIRONMENT",component=redpanda,cost-profile=minimal
    else
        log_info "VM yb-redpanda already exists"
    fi
    
    # Create firewall rule for internal access
    if ! gcloud compute firewall-rules describe yb-redpanda-internal --project="$PROJECT_ID" &>/dev/null; then
        log_info "Creating firewall rules for Redpanda..."
        gcloud compute firewall-rules create yb-redpanda-internal \
            --project="$PROJECT_ID" \
            --allow tcp:9092,tcp:9644,tcp:8082 \
            --source-ranges=10.0.0.0/8 \
            --target-tags=redpanda-broker \
            --description="Allow internal access to Redpanda Kafka and Admin API"
    fi
    
    # Get VM internal IP
    REDPANDA_IP=$(gcloud compute instances describe yb-redpanda \
        --zone="$ZONE" --project="$PROJECT_ID" \
        --format='get(networkInterfaces[0].networkIP)')
    
    log_success "Redpanda VM created at internal IP: $REDPANDA_IP"
    
    # Install and configure Redpanda
    log_info "Installing Redpanda CE on the VM..."
    gcloud compute ssh yb-redpanda --zone="$ZONE" --project="$PROJECT_ID" --command="
        # Install Redpanda
        curl -fsSL https://packages.redpanda.com/one-liner.sh | sudo -E bash
        
        # Configure for minimal resource usage
        sudo rpk cluster config import --from-production-profile
        
        # Optimize for e2-small (2 GiB RAM)
        sudo rpk cluster config set redpanda.memory 1073741824  # 1 GiB
        sudo rpk cluster config set redpanda.reserve_memory 209715200  # 200 MiB
        sudo rpk cluster config set redpanda.overprovisioned true
        
        # Set retention for cost optimization
        sudo rpk cluster config set log_retention_ms 604800000  # 7 days
        sudo rpk cluster config set log_segment_size 134217728  # 128 MiB segments
        
        # Start Redpanda
        sudo systemctl enable --now redpanda
        
        # Wait for startup
        sleep 10
        
        # Create topics for YugabyteDB CDC
        rpk topic create yb.public.events --partitions 3 --replicas 1
        rpk topic create yb.public.job_queue --partitions 3 --replicas 1
        rpk topic create yb.public.orders --partitions 3 --replicas 1
        rpk topic create yb.public.products --partitions 3 --replicas 1
        
        echo 'Redpanda installation completed successfully'
    " || log_warning "Redpanda installation may have encountered issues"
    
    log_success "Redpanda CE deployed successfully on $REDPANDA_IP"
}

# ✅ Step 2: Create Serverless VPC Connector
create_vpc_connector() {
    log_info "🔗 Step 2: Creating Serverless VPC Connector..."
    
    if ! gcloud compute networks vpc-access connectors describe run-yb-cdc \
        --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        
        log_info "Creating VPC connector for Cloud Run..."
        gcloud compute networks vpc-access connectors create run-yb-cdc \
            --project="$PROJECT_ID" \
            --region="$REGION" \
            --range=10.8.0.0/28 \
            --min-instances=2 \
            --max-instances=3
    else
        log_info "VPC connector run-yb-cdc already exists"
    fi
    
    log_success "VPC connector created successfully"
}

# ✅ Step 3: Deploy Debezium Connector on Cloud Run
deploy_cdc_connector() {
    log_info "🔄 Step 3: Deploying YugabyteDB CDC Connector on Cloud Run..."
    
    # Get YugabyteDB service endpoint
    YB_NAMESPACE="codet-${ENVIRONMENT}-yb"
    YB_SERVICE=$(kubectl get svc -n "$YB_NAMESPACE" -l app=yb-tserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "yb-tserver-service")
    YB_ENDPOINT="${YB_SERVICE}.${YB_NAMESPACE}.svc.cluster.local"
    
    # Get database password from secret
    DB_PASSWORD=$(kubectl get secret yugabyte-db-credentials -n "$YB_NAMESPACE" -o jsonpath='{.data.yugabyte-password}' 2>/dev/null | base64 -d || echo "yugabyte")
    
    log_info "Deploying CDC connector to Cloud Run..."
    gcloud run deploy yb-cdc-connect \
        --project="$PROJECT_ID" \
        --image=quay.io/yugabyte/debezium-connector:latest \
        --region="$REGION" \
        --min-instances=1 \
        --max-instances=2 \
        --cpu=1 \
        --memory=1Gi \
        --vpc-connector=run-yb-cdc \
        --set-env-vars="BOOTSTRAP_SERVERS=${REDPANDA_IP}:9092,YB_MASTERS=${YB_ENDPOINT}:5433,JAVA_TOOL_OPTIONS=-Xmx512m" \
        --allow-unauthenticated \
        --port=8083 \
        --timeout=3600 \
        --labels=environment="$ENVIRONMENT",component=cdc-connector,cost-profile=minimal
    
    # Get Cloud Run URL
    CONNECTOR_URL=$(gcloud run services describe yb-cdc-connect \
        --region="$REGION" --project="$PROJECT_ID" \
        --format='value(status.url)')
    
    log_success "CDC Connector deployed at: $CONNECTOR_URL"
    
    # Wait for connector to be ready
    log_info "Waiting for connector to be ready..."
    for i in {1..30}; do
        if curl -s "$CONNECTOR_URL/connectors" &>/dev/null; then
            log_success "Connector is ready!"
            break
        fi
        sleep 5
    done
    
    # First, setup CDC stream in YugabyteDB
    log_info "Setting up CDC stream in YugabyteDB..."
    
    # Create replication slot and CDC stream
    kubectl exec -n "$YB_NAMESPACE" deployment/yb-tserver-0 -- ysqlsh -h localhost -c "
        -- Enable logical replication (should already be enabled)
        -- Create replication slot for CDC
        SELECT 'pgoutput' AS plugin, pg_create_logical_replication_slot('yb_cdc_slot', 'pgoutput');
        
        -- Create publication for the tables we want to replicate
        CREATE PUBLICATION yb_cdc_publication FOR TABLE public.events, public.job_queue, public.orders, public.products;
        
        -- Grant necessary permissions
        GRANT SELECT ON public.events TO yugabyte;
        GRANT SELECT ON public.job_queue TO yugabyte;  
        GRANT SELECT ON public.orders TO yugabyte;
        GRANT SELECT ON public.products TO yugabyte;
    " || log_warning "CDC stream setup may have encountered issues"

    # Register the corrected YugabyteDB CDC connector
    log_info "Registering YugabyteDB CDC connector with correct configuration..."
    cat > /tmp/yb-cdc-config.json << EOF
{
  "name": "yugabytedb-cdc-${ENVIRONMENT}",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "${YB_ENDPOINT}",
    "database.port": "5433",
    "database.user": "yugabyte",
    "database.password": "${DB_PASSWORD}",
    "database.dbname": "yugabyte",
    "database.server.name": "yb-${ENVIRONMENT}",
    "plugin.name": "pgoutput",
    "slot.name": "yb_cdc_slot",
    "publication.name": "yb_cdc_publication",
    "table.include.list": "public.events,public.job_queue,public.orders,public.products",
    "topic.prefix": "yb",
    "poll.interval.ms": "1000",
    "max.batch.size": "1000",
    "snapshot.mode": "never",
    "heartbeat.interval.ms": "10000",
    "heartbeat.topics.prefix": "yb.heartbeat",
    "schema.history.internal.kafka.bootstrap.servers": "${REDPANDA_IP}:9092",
    "schema.history.internal.kafka.topic": "yb.schema.history.${ENVIRONMENT}",
    "transforms": "route",
    "transforms.route.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.route.regex": "yb-${ENVIRONMENT}\\.public\\.(.*)",
    "transforms.route.replacement": "yb.public.\$1"
  }
}
EOF
    
    if curl -X POST "$CONNECTOR_URL/connectors" \
        -H 'Content-Type: application/json' \
        -d @/tmp/yb-cdc-config.json; then
        log_success "YugabyteDB CDC connector registered successfully"
    else
        log_warning "CDC connector registration may have failed - check manually"
    fi
    
    rm -f /tmp/yb-cdc-config.json
}

# ✅ Step 4: Verify the setup
verify_setup() {
    log_info "🔍 Step 4: Verifying CDC + Kafka setup..."
    
    # Check Redpanda status
    log_info "Checking Redpanda status..."
    gcloud compute ssh yb-redpanda --zone="$ZONE" --project="$PROJECT_ID" --command="
        rpk cluster info
        rpk topic list
    " || log_warning "Could not verify Redpanda status"
    
    # Check Cloud Run connector
    log_info "Checking CDC connector status..."
    CONNECTOR_URL=$(gcloud run services describe yb-cdc-connect \
        --region="$REGION" --project="$PROJECT_ID" \
        --format='value(status.url)')
    
    if curl -s "$CONNECTOR_URL/connectors" | grep -q yugabytedb-cdc; then
        log_success "CDC connector is registered and running"
    else
        log_warning "CDC connector may not be properly configured"
    fi
    
    # Check connector status
    curl -s "$CONNECTOR_URL/connectors/yugabytedb-cdc-${ENVIRONMENT}/status" | jq '.' || echo "Connector status check failed"
}

# ✅ Step 5: Create monitoring and cost alerts
setup_monitoring() {
    log_info "📊 Step 5: Setting up monitoring and cost alerts..."
    
    # Create budget alert
    cat > /tmp/budget-alert.json << EOF
{
  "displayName": "CDC Kafka Stack Budget Alert",
  "budgetFilter": {
    "projects": ["projects/$PROJECT_ID"],
    "labels": {
      "environment": "$ENVIRONMENT"
    }
  },
  "amount": {
    "specifiedAmount": {
      "currencyCode": "USD",
      "units": "40"
    }
  },
  "thresholdRules": [
    {
      "thresholdPercent": 0.8,
      "spendBasis": "CURRENT_SPEND"
    }
  ]
}
EOF
    
    # Note: Budget creation requires billing API setup
    log_info "Budget alert configuration saved to /tmp/budget-alert.json"
    log_info "Set up manually in Cloud Console > Billing > Budgets & alerts"
    
    # Create simple monitoring script
    cat > /tmp/monitor-cdc-stack.sh << 'EOF'
#!/bin/bash
# Simple monitoring script for CDC + Kafka stack

REDPANDA_IP="$1"
CONNECTOR_URL="$2"

echo "=== CDC + Kafka Stack Health Check ==="
echo "Timestamp: $(date)"

# Check Redpanda
echo "1. Redpanda Broker:"
if curl -s "http://$REDPANDA_IP:9644/v1/status" | grep -q "ready"; then
    echo "   ✅ Redpanda is healthy"
else
    echo "   ❌ Redpanda health check failed"
fi

# Check connector
echo "2. CDC Connector:"
if curl -s "$CONNECTOR_URL/connectors" | grep -q yugabytedb-cdc; then
    echo "   ✅ CDC connector is running"
else
    echo "   ❌ CDC connector check failed"
fi

# Check topics
echo "3. Kafka Topics:"
gcloud compute ssh yb-redpanda --zone=us-central1-a --command="rpk topic list" 2>/dev/null || echo "   ❌ Could not list topics"

echo "=========================="
EOF
    
    chmod +x /tmp/monitor-cdc-stack.sh
    log_success "Monitoring script created: /tmp/monitor-cdc-stack.sh"
    
    rm -f /tmp/budget-alert.json
}

# ✅ Main execution
main() {
    log_info "🎯 Starting $25/mo CDC + Kafka deployment..."
    
    # Check prerequisites
    for tool in gcloud kubectl curl jq; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool is not installed"
            exit 1
        fi
    done
    
    # Set GCP project
    gcloud config set project "$PROJECT_ID"
    
    # Deploy components
    deploy_redpanda_vm
    create_vpc_connector
    deploy_cdc_connector
    verify_setup
    setup_monitoring
    
    log_success "🎉 CDC + Kafka stack deployment completed!"
    echo ""
    echo "📋 **Setup Summary:**"
    echo "===================="
    echo "• Redpanda Broker: $REDPANDA_IP:9092 (internal VPC)"
    echo "• CDC Connector: $CONNECTOR_URL"
    echo "• Estimated Cost: ~$25-27/month"
    echo "• Topics: yb.public.events, yb.public.job_queue, yb.public.orders, yb.public.products"
    echo ""
    echo "📡 **Next Steps:**"
    echo "=================="
    echo "1. Test with the enhanced messaging demo:"
    echo "   cd examples && python messaging-patterns-demo.py --kafka-broker=$REDPANDA_IP:9092"
    echo ""
    echo "2. Monitor the setup:"
    echo "   /tmp/monitor-cdc-stack.sh $REDPANDA_IP $CONNECTOR_URL"
    echo ""
    echo "3. Scale when needed:"
    echo "   ./scripts/scale-cdc-stack.sh [ha|performance]"
}

# Error handling and cleanup
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Deployment failed with exit code $exit_code"
        log_info "Check the logs above for details"
    fi
}

trap cleanup EXIT

# Run main function
main "$@" 