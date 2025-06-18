#!/bin/bash

# Manage CDC + Kafka Stack Operations
# Monitoring, cost controls, and operational commands

set -euo pipefail

# Configuration
ZONE="us-central1-a"
REGION="us-central1"
VM_NAME="yb-redpanda"
CONNECTOR_NAME="yb-cdc-connect"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

show_usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  status          - Show status of all components"
    echo "  costs           - Show current month costs"
    echo "  monitor         - Start monitoring dashboard"
    echo "  scale-up        - Scale up for higher throughput"
    echo "  scale-down      - Scale down to save costs"
    echo "  backup          - Create backup snapshots"
    echo "  cleanup         - Clean up old data"
    echo "  restart         - Restart all services"
    echo "  logs            - Show recent logs"
    echo "  test-cdc        - Test CDC functionality"
    echo "  stop            - Stop all services (cost saving)"
    echo "  start           - Start all services"
    echo "  destroy         - Destroy entire stack"
    echo ""
}

check_status() {
    log_info "Checking CDC + Kafka stack status..."
    
    # Check Redpanda VM
    log_info "Redpanda VM Status:"
    if gcloud compute instances describe $VM_NAME --zone=$ZONE --format="table(name,status,machineType.scope(machineTypes),networkInterfaces[0].networkIP)" 2>/dev/null; then
        log_success "Redpanda VM is running"
        
        # Check Redpanda container
        REDPANDA_STATUS=$(gcloud compute ssh $VM_NAME --zone=$ZONE --command='docker ps --filter name=redpanda --format "table {{.Names}}\t{{.Status}}"' 2>/dev/null || echo "Connection failed")
        if [[ $REDPANDA_STATUS == *"Up"* ]]; then
            log_success "Redpanda container is running"
        else
            log_error "Redpanda container issue: $REDPANDA_STATUS"
        fi
    else
        log_error "Redpanda VM not found"
    fi
    
    # Check Cloud Run connector
    log_info "CDC Connector Status:"
    if gcloud run services describe $CONNECTOR_NAME --region=$REGION --format="table(metadata.name,status.conditions[0].type,status.url)" 2>/dev/null; then
        log_success "CDC Connector is deployed"
    else
        log_error "CDC Connector not found"
    fi
    
    # Check YugabyteDB
    log_info "YugabyteDB Status:"
    if kubectl get pods -n codet-dev-yb 2>/dev/null | grep Running; then
        log_success "YugabyteDB is running"
    else
        log_warning "YugabyteDB not found or not running"
    fi
    
    # Check connector registration
    CONNECTOR_URL=$(gcloud run services describe $CONNECTOR_NAME --region=$REGION --format="value(status.url)" 2>/dev/null || echo "")
    if [ ! -z "$CONNECTOR_URL" ]; then
        log_info "Checking connector registration..."
        CONNECTORS=$(curl -s $CONNECTOR_URL/connectors 2>/dev/null || echo "[]")
        if [[ $CONNECTORS == *"yugabyte-cdc-connector"* ]]; then
            log_success "CDC Connector is registered and active"
        else
            log_warning "CDC Connector is not registered"
        fi
    fi
}

show_costs() {
    log_info "Estimating current month costs..."
    
    # Get VM uptime
    VM_CREATION=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format="value(creationTimestamp)" 2>/dev/null || echo "")
    if [ ! -z "$VM_CREATION" ]; then
        DAYS_RUNNING=$(( ($(date +%s) - $(date -d "$VM_CREATION" +%s)) / 86400 ))
        VM_COST=$(echo "scale=2; $DAYS_RUNNING * 0.56" | bc -l)  # $17/month ≈ $0.56/day
        log_info "Redpanda VM (running $DAYS_RUNNING days): ~\$${VM_COST}"
    fi
    
    # Cloud Run costs (approximate)
    CONNECTOR_COST=$(echo "scale=2; $DAYS_RUNNING * 0.33" | bc -l)  # $10/month ≈ $0.33/day
    log_info "CDC Connector: ~\$${CONNECTOR_COST}"
    
    # VPC Connector
    VPC_COST=$(echo "scale=2; $DAYS_RUNNING * 0.07" | bc -l)  # $2/month ≈ $0.07/day
    log_info "VPC Connector: ~\$${VPC_COST}"
    
    TOTAL_COST=$(echo "scale=2; $VM_COST + $CONNECTOR_COST + $VPC_COST" | bc -l)
    log_success "Estimated total so far: ~\$${TOTAL_COST}"
}

monitor_dashboard() {
    log_info "Starting monitoring dashboard..."
    
    # Get Redpanda IP
    REDPANDA_IP=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format="get(networkInterfaces[0].networkIP)" 2>/dev/null || echo "")
    CONNECTOR_URL=$(gcloud run services describe $CONNECTOR_NAME --region=$REGION --format="value(status.url)" 2>/dev/null || echo "")
    
    echo ""
    log_info "📊 Real-time Monitoring Dashboard"
    echo "================================="
    echo ""
    
    while true; do
        clear
        echo "🕒 $(date)"
        echo ""
        
        # Redpanda metrics
        if [ ! -z "$REDPANDA_IP" ]; then
            log_info "📈 Redpanda Metrics:"
            gcloud compute ssh $VM_NAME --zone=$ZONE --command='docker exec redpanda rpk cluster info' 2>/dev/null | head -10 || log_error "Failed to get Redpanda metrics"
            echo ""
            
            log_info "📋 Topic List:"
            gcloud compute ssh $VM_NAME --zone=$ZONE --command='docker exec redpanda rpk topic list' 2>/dev/null || log_error "Failed to list topics"
            echo ""
        fi
        
        # Connector status
        if [ ! -z "$CONNECTOR_URL" ]; then
            log_info "🔗 Connector Status:"
            curl -s $CONNECTOR_URL/connectors/yugabyte-cdc-connector/status 2>/dev/null | jq '.' || log_error "Failed to get connector status"
            echo ""
        fi
        
        # YugabyteDB status
        log_info "🗃️  YugabyteDB Pods:"
        kubectl get pods -n codet-dev-yb 2>/dev/null || log_error "Failed to get YB status"
        echo ""
        
        echo "Press Ctrl+C to exit monitoring..."
        sleep 10
    done
}

scale_up() {
    log_info "Scaling up for higher throughput..."
    
    # Resize VM to e2-medium
    gcloud compute instances stop $VM_NAME --zone=$ZONE
    gcloud compute instances set-machine-type $VM_NAME --zone=$ZONE --machine-type=e2-medium
    gcloud compute instances start $VM_NAME --zone=$ZONE
    
    # Update Cloud Run to 2 CPUs
    gcloud run services update $CONNECTOR_NAME --region=$REGION --cpu=2 --memory=2Gi
    
    log_success "Scaled up (additional ~\$6/month cost)"
}

scale_down() {
    log_info "Scaling down to save costs..."
    
    # Resize VM back to e2-small
    gcloud compute instances stop $VM_NAME --zone=$ZONE
    gcloud compute instances set-machine-type $VM_NAME --zone=$ZONE --machine-type=e2-small
    gcloud compute instances start $VM_NAME --zone=$ZONE
    
    # Update Cloud Run back to 1 CPU
    gcloud run services update $CONNECTOR_NAME --region=$REGION --cpu=1 --memory=1Gi
    
    log_success "Scaled down to minimal cost configuration"
}

test_cdc() {
    log_info "Testing CDC functionality..."
    
    # Create a test table and insert data
    YB_POD=$(kubectl get pods -n codet-dev-yb -l app=yb-tserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ ! -z "$YB_POD" ]; then
        log_info "Creating test table..."
        kubectl exec -n codet-dev-yb $YB_POD -c yb-tserver -- ysqlsh -h localhost -c "
            CREATE TABLE IF NOT EXISTS test_cdc (
                id SERIAL PRIMARY KEY,
                name VARCHAR(100),
                created_at TIMESTAMP DEFAULT NOW()
            );
            INSERT INTO test_cdc (name) VALUES ('CDC Test $(date +%s)');
        " 2>/dev/null
        
        log_success "Test data inserted"
        
        # Check if data appears in Kafka topics
        sleep 5
        log_info "Checking Kafka topics for CDC data..."
        gcloud compute ssh $VM_NAME --zone=$ZONE --command='docker exec redpanda rpk topic consume yb.public.test_cdc --num 1' 2>/dev/null || log_warning "No CDC data found yet"
    else
        log_error "YugabyteDB pod not found"
    fi
}

stop_services() {
    log_info "Stopping services to save costs..."
    
    # Stop VM
    gcloud compute instances stop $VM_NAME --zone=$ZONE
    
    # Scale Cloud Run to 0
    gcloud run services update $CONNECTOR_NAME --region=$REGION --min-instances=0
    
    log_success "Services stopped. Restart with './scripts/manage-cdc-stack.sh start'"
}

start_services() {
    log_info "Starting services..."
    
    # Start VM
    gcloud compute instances start $VM_NAME --zone=$ZONE
    
    # Scale Cloud Run back to 1
    gcloud run services update $CONNECTOR_NAME --region=$REGION --min-instances=1
    
    log_success "Services started"
}

show_logs() {
    log_info "Showing recent logs..."
    
    echo "📋 Redpanda Logs:"
    gcloud compute ssh $VM_NAME --zone=$ZONE --command='docker logs redpanda --tail 20' 2>/dev/null || log_error "Failed to get Redpanda logs"
    
    echo ""
    echo "📋 Cloud Run Logs:"
    gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=$CONNECTOR_NAME" --limit=10 --format="table(timestamp,textPayload)" || log_error "Failed to get Cloud Run logs"
}

destroy_stack() {
    log_warning "This will destroy the entire CDC + Kafka stack!"
    read -p "Are you sure? (type 'yes' to confirm): " confirm
    
    if [ "$confirm" = "yes" ]; then
        log_info "Destroying CDC + Kafka stack..."
        
        # Delete Cloud Run service
        gcloud run services delete $CONNECTOR_NAME --region=$REGION --quiet || true
        
        # Delete VM
        gcloud compute instances delete $VM_NAME --zone=$ZONE --quiet || true
        
        # Delete VPC connector
        gcloud compute networks vpc-access connectors delete run-yb --region=$REGION --quiet || true
        
        # Delete firewall rule
        gcloud compute firewall-rules delete yb-redpanda-internal --quiet || true
        
        log_success "CDC + Kafka stack destroyed"
    else
        log_info "Destruction cancelled"
    fi
}

# Main command handling
case "${1:-}" in
    "status")
        check_status
        ;;
    "costs")
        show_costs
        ;;
    "monitor")
        monitor_dashboard
        ;;
    "scale-up")
        scale_up
        ;;
    "scale-down")
        scale_down
        ;;
    "test-cdc")
        test_cdc
        ;;
    "stop")
        stop_services
        ;;
    "start")
        start_services
        ;;
    "logs")
        show_logs
        ;;
    "destroy")
        destroy_stack
        ;;
    *)
        show_usage
        ;;
esac 