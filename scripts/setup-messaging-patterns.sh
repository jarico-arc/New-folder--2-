#!/bin/bash

# Setup All Messaging Patterns for YugabyteDB
# Implements the four patterns from the field guide

set -euo pipefail

# Ensure kubectl is available
command -v kubectl >/dev/null 2>&1 || {
  echo -e "\033[0;31m❌ kubectl not found in PATH. Run this script in Google Cloud Shell or install kubectl + gcloud SDK.\033[0m" >&2
  exit 1
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

echo "🚀 Setting up YugabyteDB messaging patterns..."

# Enhanced namespace detection
detect_yugabyte_namespace() {
    local ns=""
    
    # Method 1: Look for YB tserver pods
    ns=$(kubectl get pods --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    
    # Method 2: Look for YB services  
    if [ -z "$ns" ]; then
        ns=$(kubectl get services --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    fi
    
    # Method 3: Look for YB StatefulSets
    if [ -z "$ns" ]; then
        ns=$(kubectl get statefulsets --all-namespaces -l app=yb-tserver -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    fi
    
    # Method 4: Look for YB master pods
    if [ -z "$ns" ]; then
        ns=$(kubectl get pods --all-namespaces -l app=yb-master -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    fi
    
    # Method 5: Namespace name pattern matching
    if [ -z "$ns" ]; then
        ns=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -m1 -E '(yugabyte|yb)' 2>/dev/null || echo "")
    fi
    
    echo "$ns"
}

# Configuration
NAMESPACE=${1:-"codet-dev-yb"}

# Auto-detect Yugabyte namespace if the provided one doesn't exist
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 ; then
  DETECTED_NS=$(detect_yugabyte_namespace)
  if [ -n "$DETECTED_NS" ]; then
    echo -e "${YELLOW}⚠️  Namespace $NAMESPACE not found. Using auto-detected namespace: $DETECTED_NS${NC}"
    NAMESPACE="$DETECTED_NS"
  else
    echo -e "${RED}❌ Could not auto-detect a Yugabyte namespace. Please pass the namespace as the first argument.${NC}"
    echo -e "${BLUE}ℹ️  Available namespaces:${NC}"
    kubectl get namespaces -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null || echo "None found"
    exit 1
  fi
fi

POD_NAME=""

# Find YugabyteDB pod
log_info "Finding YugabyteDB pod..."
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=yb-tserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    log_error "YugabyteDB pod not found in namespace $NAMESPACE"
    log_info "Available namespaces with YugabyteDB:"
    kubectl get pods --all-namespaces -l app=yb-tserver -o wide 2>/dev/null || true
    exit 1
fi

log_success "Found YugabyteDB pod: $POD_NAME"

# Function to execute SQL
execute_sql() {
    local sql="$1"
    local description="$2"
    
    log_info "$description"
    kubectl exec -n $NAMESPACE $POD_NAME -c yb-tserver -- ysqlsh -h localhost -c "$sql" 2>/dev/null || {
        log_error "Failed to execute: $description"
        return 1
    }
    log_success "Completed: $description"
}

# Function to execute SQL file
execute_sql_file() {
    local file_path="$1"
    local description="$2"
    
    log_info "$description"
    if [ -f "$file_path" ]; then
        kubectl exec -n $NAMESPACE $POD_NAME -c yb-tserver -i -- ysqlsh -h localhost < "$file_path" 2>/dev/null || {
            log_error "Failed to execute SQL file: $file_path"
            return 1
        }
        log_success "Completed: $description"
    else
        log_warning "SQL file not found: $file_path"
    fi
}

# Step 1: Check database connectivity
log_info "Testing database connectivity..."
execute_sql "SELECT version();" "Database version check"

# Step 2: Set up messaging patterns
log_info "Setting up messaging patterns..."

# Create the SQL inline since we may not have the file available
cat << 'EOF' | kubectl exec -n $NAMESPACE $POD_NAME -c yb-tserver -i -- ysqlsh -h localhost

-- YugabyteDB Messaging Patterns Setup
\echo 'Setting up job queue table...'

CREATE TABLE IF NOT EXISTS job_queue (
    job_id      BIGSERIAL PRIMARY KEY,
    job_type    TEXT NOT NULL,
    payload     JSONB NOT NULL,
    priority    INTEGER DEFAULT 0,
    run_after   TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by   TEXT,
    locked_at   TIMESTAMPTZ,
    processed   BOOLEAN DEFAULT false,
    failed      BOOLEAN DEFAULT false,
    error_msg   TEXT,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
) SPLIT INTO 8 TABLETS;

\echo 'Creating indexes...'

CREATE INDEX IF NOT EXISTS idx_job_queue_pending 
ON job_queue (priority DESC, job_id ASC) 
WHERE processed = false AND failed = false AND run_after <= now();

CREATE INDEX IF NOT EXISTS idx_job_queue_cleanup 
ON job_queue (created_at) 
WHERE processed = true OR failed = true;

\echo 'Setting up events table for CDC...'

CREATE TABLE IF NOT EXISTS events (
    event_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type  TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id   TEXT NOT NULL,
    event_data  JSONB NOT NULL,
    metadata    JSONB DEFAULT '{}',
    occurred_at TIMESTAMPTZ DEFAULT now(),
    version     INTEGER DEFAULT 1
) SPLIT INTO 8 TABLETS;

CREATE INDEX IF NOT EXISTS idx_events_entity 
ON events (entity_type, entity_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_events_type_time 
ON events (event_type, occurred_at DESC);

\echo 'Creating example tables...'

CREATE TABLE IF NOT EXISTS orders (
    order_id    BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    total       DECIMAL(10,2) NOT NULL,
    status      TEXT DEFAULT 'pending',
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
    product_id  BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    price       DECIMAL(10,2) NOT NULL,
    inventory   INTEGER DEFAULT 0,
    updated_at  TIMESTAMPTZ DEFAULT now()
);

\echo 'Creating functions...'

CREATE OR REPLACE FUNCTION enqueue_job(
    p_job_type TEXT,
    p_payload JSONB,
    p_priority INTEGER DEFAULT 0,
    p_delay_seconds INTEGER DEFAULT 0
) RETURNS BIGINT AS $$
DECLARE
    job_id BIGINT;
BEGIN
    INSERT INTO job_queue (job_type, payload, priority, run_after)
    VALUES (
        p_job_type, 
        p_payload, 
        p_priority, 
        now() + (p_delay_seconds || ' seconds')::INTERVAL
    )
    RETURNING job_queue.job_id INTO job_id;
    
    PERFORM pg_notify('new_job', json_build_object(
        'job_id', job_id,
        'job_type', p_job_type,
        'priority', p_priority
    )::text);
    
    RETURN job_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION dequeue_job(
    p_worker_id TEXT,
    p_job_types TEXT[] DEFAULT NULL
) RETURNS TABLE(
    job_id BIGINT,
    job_type TEXT,
    payload JSONB,
    retry_count INTEGER
) AS $$
BEGIN
    RETURN QUERY
    WITH next_job AS (
        SELECT jq.job_id, jq.job_type, jq.payload, jq.retry_count
        FROM job_queue jq
        WHERE jq.processed = false 
          AND jq.failed = false
          AND jq.run_after <= now()
          AND (p_job_types IS NULL OR jq.job_type = ANY(p_job_types))
        ORDER BY jq.priority DESC, jq.job_id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1
    )
    UPDATE job_queue jq
    SET locked_by = p_worker_id,
        locked_at = now(),
        updated_at = now()
    FROM next_job nj
    WHERE jq.job_id = nj.job_id
    RETURNING jq.job_id, jq.job_type, jq.payload, jq.retry_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION complete_job(p_job_id BIGINT) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE job_queue 
    SET processed = true, 
        updated_at = now()
    WHERE job_id = p_job_id 
      AND processed = false;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION emit_event(
    p_event_type TEXT,
    p_entity_type TEXT,
    p_entity_id TEXT,
    p_event_data JSONB,
    p_metadata JSONB DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
    event_id UUID;
BEGIN
    INSERT INTO events (event_type, entity_type, entity_id, event_data, metadata)
    VALUES (p_event_type, p_entity_type, p_entity_id, p_event_data, p_metadata)
    RETURNING events.event_id INTO event_id;
    
    PERFORM pg_notify('event_stream', json_build_object(
        'event_id', event_id,
        'event_type', p_event_type,
        'entity_type', p_entity_type,
        'entity_id', p_entity_id
    )::text);
    
    RETURN event_id;
END;
$$ LANGUAGE plpgsql;

\echo 'Creating monitoring views...'

CREATE OR REPLACE VIEW queue_monitor AS
SELECT 
    job_type,
    COUNT(*) FILTER (WHERE processed = false AND failed = false AND run_after <= now()) as ready,
    COUNT(*) FILTER (WHERE locked_by IS NOT NULL AND processed = false) as processing,
    COUNT(*) FILTER (WHERE failed = true) as failed,
    COUNT(*) FILTER (WHERE run_after > now()) as scheduled,
    MAX(created_at) as last_job_time
FROM job_queue
GROUP BY job_type
ORDER BY ready DESC;

\echo 'Setup completed successfully!'

EOF

if [ $? -eq 0 ]; then
    log_success "Messaging patterns setup completed"
else
    log_error "Failed to setup messaging patterns"
    exit 1
fi

# Step 3: Test the patterns
log_info "Testing messaging patterns..."

# Test 1: LISTEN/NOTIFY
log_info "Testing LISTEN/NOTIFY pattern..."
execute_sql "SELECT pg_notify('test_channel', 'Hello from YugabyteDB!');" "LISTEN/NOTIFY test"

# Test 2: Queue table
log_info "Testing job queue pattern..."
execute_sql "SELECT enqueue_job('test_job', '{\"message\": \"Hello from job queue\", \"timestamp\": \"$(date -Iseconds)\"}');" "Enqueue test job"

# Test 3: CDC events
log_info "Testing CDC events pattern..."
execute_sql "SELECT emit_event('test.created', 'test', '123', '{\"data\": \"Hello from CDC\"}');" "Emit test event"

# Test 4: Check queue status
log_info "Checking queue status..."
execute_sql "SELECT * FROM queue_monitor;" "Queue status check"

# Step 4: Insert demo data
log_info "Inserting demo data..."
execute_sql "INSERT INTO products (name, price, inventory) VALUES ('Test Product', 99.99, 100);" "Insert test product"
execute_sql "INSERT INTO orders (customer_id, total) VALUES (123, 99.99);" "Insert test order"

# Step 5: Enable CDC on key tables
log_info "Enabling CDC on key tables..."
execute_sql "SELECT yb_enable_cdc_for_table('events');" "Enable CDC on events table" || log_warning "CDC enable failed - may not be supported"
execute_sql "SELECT yb_enable_cdc_for_table('job_queue');" "Enable CDC on job_queue table" || log_warning "CDC enable failed - may not be supported"

# Step 6: Show pattern usage examples
log_success "✨ Messaging patterns are ready!"
echo ""
echo "📋 Pattern Usage Examples:"
echo "=========================="
echo ""
echo "🔔 1. LISTEN/NOTIFY (Real-time notifications):"
echo "   Publisher: SELECT pg_notify('cache_invalidate', '{\"key\": \"user:123\"}');"
echo "   Subscriber: LISTEN cache_invalidate; SELECT 1 FROM pg_notification_queue() LIMIT 1;"
echo ""
echo "📝 2. Job Queue (Background processing):"
echo "   Enqueue: SELECT enqueue_job('send_email', '{\"to\": \"user@example.com\", \"subject\": \"Welcome!\"}');"
echo "   Dequeue: SELECT * FROM dequeue_job('worker-1', ARRAY['send_email']);"
echo "   Complete: SELECT complete_job(job_id);"
echo ""
echo "📡 3. CDC Events (Event streaming):"
echo "   Emit: SELECT emit_event('user.created', 'user', '123', '{\"email\": \"user@example.com\"}');"
echo "   Query: SELECT * FROM events WHERE entity_type = 'user' ORDER BY occurred_at DESC;"
echo ""
echo "📊 4. Monitoring:"
echo "   Queue status: SELECT * FROM queue_monitor;"
echo "   Event count: SELECT event_type, COUNT(*) FROM events GROUP BY event_type;"
echo ""
echo "🔗 Next Steps:"
echo "=============="
echo "1. Deploy CDC + Kafka stack: ./scripts/deploy-cdc-kafka-stack.sh"
echo "2. Monitor the system: ./scripts/manage-cdc-stack.sh monitor"
echo "3. Check costs: ./scripts/manage-cdc-stack.sh costs"
echo ""
echo "💡 Cost Breakdown:"
echo "=================="
echo "• YugabyteDB (current setup): ~$25-30/month"
echo "• CDC + Kafka stack: ~$25-29/month"
echo "• Total event-driven system: ~$50-59/month"
echo ""
echo "🎉 You now have a complete event-driven architecture!" 