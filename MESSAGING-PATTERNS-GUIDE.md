# YugabyteDB Messaging Patterns Guide

Complete guide to implementing all four messaging patterns with YugabyteDB + CDC/Kafka stack.

## Overview

Your YugabyteDB deployment now supports four complementary messaging patterns:

| Pattern | Latency | Durability | Throughput | Use Case | Monthly Cost |
|---------|---------|------------|------------|----------|--------------|
| **LISTEN/NOTIFY** | <1ms | Fire-and-forget | Thousands/sec | Real-time UI, cache invalidation | $0 |
| **Job Queue + SKIP LOCKED** | 10-50ms | ACID guaranteed | Hundreds/sec | Background jobs, email sending | $0 |
| **CDC → Kafka** | ~100ms | Replicated | Very high | Event sourcing, analytics | +$25-29/mo |
| **Logical Replication** | Variable | Durable | High | Database sync, read replicas | $0 |

## Setup and Deployment

### Quick Start

```bash
# 1. Setup messaging patterns in YugabyteDB
./scripts/setup-messaging-patterns.sh

# 2. Deploy CDC + Kafka stack (optional, for event streaming)
./scripts/deploy-cdc-kafka-stack.sh

# 3. Test all patterns
python examples/messaging-patterns-demo.py --pattern all
```

### Individual Pattern Setup

```bash
# Just messaging patterns (no Kafka)
./scripts/setup-messaging-patterns.sh codet-dev-yb

# Test specific patterns
python examples/messaging-patterns-demo.py --pattern listen-notify
python examples/messaging-patterns-demo.py --pattern job-queue --worker-id worker-1
python examples/messaging-patterns-demo.py --pattern cdc-events
```

## Pattern Implementation Details

### 1. LISTEN/NOTIFY Pattern

**Best for**: Real-time notifications, cache invalidation, live UI updates
**Latency**: Sub-millisecond within single AZ
**Durability**: Messages lost if subscriber disconnected

#### SQL Usage

```sql
-- Publisher (cache invalidation)
SELECT pg_notify('cache_invalidate', json_build_object(
    'key', 'product:123',
    'action', 'update',
    'timestamp', now(),
    'reason', 'price_change'
)::text);

-- Publisher (UI notification)
SELECT pg_notify('user_notification', json_build_object(
    'user_id', 456,
    'type', 'new_message',
    'count', 5
)::text);
```

#### Application Implementation

```python
import psycopg2
import json

class NotificationListener:
    def __init__(self, connection_params):
        self.conn = psycopg2.connect(**connection_params)
        self.conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
        
    def listen(self, channels):
        cursor = self.conn.cursor()
        for channel in channels:
            cursor.execute(f"LISTEN {channel}")
        
        while True:
            self.conn.poll()
            while self.conn.notifies:
                notify = self.conn.notifies.pop(0)
                self.handle_notification(notify.channel, notify.payload)
    
    def handle_notification(self, channel, payload):
        data = json.loads(payload)
        
        if channel == 'cache_invalidate':
            self.invalidate_cache(data['key'])
        elif channel == 'user_notification':
            self.send_websocket_update(data['user_id'], data)

# Usage
listener = NotificationListener(db_config)
listener.listen(['cache_invalidate', 'user_notification'])
```

#### Performance Tips

- Keep payloads under 8KB for optimal performance
- Use a single channel per topic for ordered delivery
- Place LISTEN connections close to the tablet leader (same AZ)

### 2. Job Queue Pattern

**Best for**: Background processing, email sending, image processing, report generation
**Latency**: 10-50ms with proper tablet placement
**Durability**: Full ACID guarantees with retry logic

#### Advanced Job Management

```sql
-- Enqueue with priority and delay
SELECT enqueue_job(
    'send_email',                    -- job_type
    json_build_object(               -- payload
        'to', 'user@example.com',
        'template', 'welcome',
        'data', json_build_object('name', 'John', 'signup_date', now())
    ),
    1,                               -- priority (1=high, 0=normal)
    300                              -- delay_seconds (5 minutes)
);

-- Enqueue batch job
SELECT enqueue_job(
    'generate_monthly_report',
    json_build_object(
        'month', '2024-01',
        'department', 'sales',
        'recipients', ARRAY['manager@company.com', 'ceo@company.com']
    ),
    2,                               -- highest priority
    0                                -- immediate
);
```

#### Worker Implementation

```python
import time
import json
import logging
from typing import Optional, List

class JobWorker:
    def __init__(self, worker_id: str, connection_params: dict, job_types: Optional[List[str]] = None):
        self.worker_id = worker_id
        self.job_types = job_types
        self.conn = psycopg2.connect(**connection_params)
        self.running = True
        
    def start(self):
        cursor = self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        
        while self.running:
            try:
                # Dequeue next job
                if self.job_types:
                    cursor.execute(
                        "SELECT * FROM dequeue_job(%s, %s)",
                        (self.worker_id, self.job_types)
                    )
                else:
                    cursor.execute("SELECT * FROM dequeue_job(%s)", (self.worker_id,))
                
                job = cursor.fetchone()
                
                if job:
                    self.process_job(cursor, job)
                else:
                    time.sleep(0.5)  # Back-off polling
                    
            except Exception as e:
                logging.error(f"Worker error: {e}")
                time.sleep(5)  # Back off on errors
    
    def process_job(self, cursor, job):
        job_id = job['job_id']
        job_type = job['job_type']
        payload = job['payload']
        
        try:
            logging.info(f"Processing job {job_id}: {job_type}")
            
            # Route to appropriate handler
            if job_type == 'send_email':
                self.send_email(payload)
            elif job_type == 'process_payment':
                self.process_payment(payload)
            elif job_type == 'generate_report':
                self.generate_report(payload)
            else:
                raise ValueError(f"Unknown job type: {job_type}")
            
            # Mark completed
            cursor.execute("SELECT complete_job(%s)", (job_id,))
            self.conn.commit()
            logging.info(f"Completed job {job_id}")
            
        except Exception as e:
            # Mark failed with retry
            cursor.execute(
                "SELECT fail_job(%s, %s, %s)",
                (job_id, str(e), True)
            )
            self.conn.commit()
            logging.error(f"Failed job {job_id}: {e}")
    
    def send_email(self, payload):
        # Simulate email sending
        time.sleep(1.0)  # Simulate SMTP time
        
    def process_payment(self, payload):
        # Simulate payment processing
        time.sleep(2.0)  # Simulate payment gateway time
        
    def generate_report(self, payload):
        # Simulate report generation
        time.sleep(5.0)  # Simulate complex report

# Usage - multiple workers for different job types
email_worker = JobWorker("email-worker-1", db_config, ["send_email", "send_sms"])
payment_worker = JobWorker("payment-worker-1", db_config, ["process_payment"])
report_worker = JobWorker("report-worker-1", db_config, ["generate_report"])
```

#### Monitoring and Operations

```sql
-- Monitor queue health
SELECT * FROM queue_monitor;

-- Get detailed job statistics
SELECT 
    job_type,
    COUNT(*) FILTER (WHERE processed = false AND failed = false) as pending,
    COUNT(*) FILTER (WHERE locked_by IS NOT NULL) as processing,
    COUNT(*) FILTER (WHERE failed = true) as failed,
    AVG(EXTRACT(EPOCH FROM (updated_at - created_at))) as avg_processing_seconds
FROM job_queue 
WHERE created_at > now() - interval '1 hour'
GROUP BY job_type;

-- Cleanup old jobs (run daily)
SELECT cleanup_old_jobs(7); -- Remove jobs older than 7 days
```

### 3. CDC Events Pattern

**Best for**: Event sourcing, audit logs, analytics, microservices communication
**Latency**: ~100ms to Kafka
**Durability**: Replicated across Kafka brokers

#### Event Emission

```sql
-- User registration event
SELECT emit_event(
    'user.registered',               -- event_type
    'user',                         -- entity_type
    '12345',                        -- entity_id
    json_build_object(              -- event_data
        'email', 'user@example.com',
        'plan', 'premium',
        'signup_method', 'google_oauth',
        'referrer', 'google_ads'
    ),
    json_build_object(              -- metadata
        'correlation_id', 'req_abc123',
        'user_agent', 'Chrome/91.0',
        'ip_address', '192.168.1.1',
        'version', '1.0'
    )
);

-- Order status change event
SELECT emit_event(
    'order.status_changed',
    'order',
    '67890',
    json_build_object(
        'previous_status', 'pending',
        'new_status', 'confirmed',
        'changed_by', 'payment_system',
        'total_amount', 99.99
    )
);
```

#### Event Triggers for Automatic Emission

```sql
-- Automatic event emission on database changes
CREATE OR REPLACE FUNCTION emit_user_events() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM emit_event(
            'user.created',
            'user',
            NEW.user_id::text,
            row_to_json(NEW)::jsonb
        );
    ELSIF TG_OP = 'UPDATE' THEN
        PERFORM emit_event(
            'user.updated',
            'user',
            NEW.user_id::text,
            json_build_object(
                'previous', row_to_json(OLD)::jsonb,
                'current', row_to_json(NEW)::jsonb,
                'changed_fields', (
                    SELECT array_agg(key) 
                    FROM jsonb_each(row_to_json(NEW)::jsonb) 
                    WHERE value != (row_to_json(OLD)::jsonb ->> key)::jsonb
                )
            )
        );
    END IF;
    
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER user_events_trigger
    AFTER INSERT OR UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION emit_user_events();
```

#### Kafka Consumer Implementation

```python
from kafka import KafkaConsumer
import json
import logging

class EventProcessor:
    def __init__(self, kafka_config, topics):
        self.consumer = KafkaConsumer(
            *topics,
            bootstrap_servers=kafka_config['bootstrap_servers'],
            group_id=kafka_config['group_id'],
            value_deserializer=lambda m: json.loads(m.decode('utf-8')),
            auto_offset_reset='latest'
        )
        
    def start(self):
        for message in self.consumer:
            try:
                event = message.value
                self.process_event(event)
            except Exception as e:
                logging.error(f"Error processing event: {e}")
    
    def process_event(self, event):
        event_type = event.get('event_type')
        entity_type = event.get('entity_type')
        event_data = event.get('event_data', {})
        
        # Route events to appropriate handlers
        if event_type == 'user.registered':
            self.handle_user_registration(event_data)
        elif event_type == 'order.status_changed':
            self.handle_order_status_change(event_data)
        elif event_type.startswith('payment.'):
            self.handle_payment_event(event_type, event_data)
    
    def handle_user_registration(self, data):
        # Send welcome email, update analytics, etc.
        logging.info(f"New user registered: {data['email']}")
    
    def handle_order_status_change(self, data):
        # Update inventory, send notifications, etc.
        logging.info(f"Order status changed: {data}")
    
    def handle_payment_event(self, event_type, data):
        # Update accounting system, send receipts, etc.
        logging.info(f"Payment event: {event_type}")

# Usage
processor = EventProcessor(
    kafka_config={'bootstrap_servers': ['redpanda-ip:9092'], 'group_id': 'event-processor'},
    topics=['yb.public.events']
)
processor.start()
```

### 4. Hybrid Pattern Example: E-commerce System

Combine all patterns for a complete system:

```sql
-- Complete order processing function
CREATE OR REPLACE FUNCTION process_order_placement() RETURNS TRIGGER AS $$
BEGIN
    -- 1. LISTEN/NOTIFY: Immediate UI update (<1ms)
    PERFORM pg_notify('order_placed', json_build_object(
        'order_id', NEW.order_id,
        'customer_id', NEW.customer_id,
        'total', NEW.total
    )::text);
    
    -- 2. Job Queue: Critical background processing (10-50ms)
    PERFORM enqueue_job('process_payment', json_build_object(
        'order_id', NEW.order_id,
        'payment_method', NEW.payment_method,
        'amount', NEW.total
    ), 2); -- Highest priority
    
    PERFORM enqueue_job('reserve_inventory', json_build_object(
        'order_id', NEW.order_id,
        'items', NEW.items
    ), 1); -- High priority
    
    PERFORM enqueue_job('send_confirmation_email', json_build_object(
        'order_id', NEW.order_id,
        'customer_email', (SELECT email FROM customers WHERE id = NEW.customer_id)
    ), 0); -- Normal priority
    
    -- 3. CDC Event: Analytics and audit trail (~100ms to Kafka)
    PERFORM emit_event(
        'order.placed',
        'order',
        NEW.order_id::text,
        json_build_object(
            'customer_id', NEW.customer_id,
            'total', NEW.total,
            'items', NEW.items,
            'payment_method', NEW.payment_method,
            'shipping_address', NEW.shipping_address
        ),
        json_build_object(
            'source', 'web_app',
            'user_agent', current_setting('app.user_agent', true),
            'session_id', current_setting('app.session_id', true)
        )
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER order_placement_trigger
    AFTER INSERT ON orders
    FOR EACH ROW EXECUTE FUNCTION process_order_placement();
```

## Performance Optimization

### Tablet Placement Strategy

```sql
-- Co-locate frequently accessed tables
ALTER TABLE job_queue SET (colocated = true);
ALTER TABLE events SET (colocated = false);  -- Keep events distributed for CDC

-- Optimize job queue partitioning
CREATE INDEX CONCURRENTLY idx_job_queue_priority_optimized 
ON job_queue (priority DESC, run_after ASC, job_id ASC) 
WHERE processed = false AND failed = false;
```

### Memory and Connection Tuning

```yaml
# In your YugabyteDB values file
gflags:
  tserver:
    # Optimize for messaging patterns
    ysql_max_connections: 500
    ysql_default_transaction_isolation: READ_COMMITTED
    
    # CDC-specific optimizations
    cdc_state_checkpoint_update_interval_ms: 15000
    cdc_checkpoint_opid_interval_ms: 60000
    
    # Job queue optimizations  
    ysql_sequence_cache_minval: 100  # Batch sequence generation
```

### Monitoring and Alerting

```sql
-- Create monitoring functions
CREATE OR REPLACE VIEW messaging_health AS
SELECT 
    'job_queue' as pattern,
    (SELECT COUNT(*) FROM job_queue WHERE processed = false AND run_after <= now()) as pending_count,
    (SELECT COUNT(*) FROM job_queue WHERE locked_by IS NOT NULL) as processing_count,
    (SELECT COUNT(*) FROM job_queue WHERE failed = true AND created_at > now() - interval '1 hour') as recent_failures
UNION ALL
SELECT 
    'events' as pattern,
    (SELECT COUNT(*) FROM events WHERE occurred_at > now() - interval '5 minutes') as recent_events,
    NULL as processing_count,
    NULL as recent_failures;

-- Alert conditions
SELECT * FROM messaging_health WHERE 
    (pattern = 'job_queue' AND pending_count > 1000) OR
    (pattern = 'job_queue' AND recent_failures > 50) OR
    (pattern = 'events' AND recent_events = 0);  -- No events in 5 minutes might indicate issues
```

## Cost Analysis

### Pattern Costs Breakdown

| Component | Monthly Cost | Notes |
|-----------|--------------|-------|
| **YugabyteDB cluster** | $25-30 | Base cost for all patterns |
| **LISTEN/NOTIFY** | $0 | No additional infrastructure |
| **Job Queue** | $0 | Uses existing YugabyteDB |
| **CDC Events (local)** | $0 | Events table in YugabyteDB |
| **Kafka Stack** | +$25-29 | Optional for external consumers |
| **Total (all patterns)** | **$50-59** | Complete event-driven system |

### Cost Optimization Strategies

```bash
# 1. Development: Use only internal patterns (no Kafka)
# Total cost: $25-30/month
./scripts/setup-messaging-patterns.sh
# Skip: ./scripts/deploy-cdc-kafka-stack.sh

# 2. Production: Add Kafka for external integrations
# Total cost: $50-59/month  
./scripts/deploy-cdc-kafka-stack.sh

# 3. Scale down during low usage
./scripts/manage-cdc-stack.sh stop    # Saves ~$20/month
./scripts/manage-cdc-stack.sh start   # Resume when needed
```

## Migration and Best Practices

### Development to Production Migration

1. **Enable Authentication and TLS**
```yaml
# manifests/values/prod-values.yaml
auth:
  enabled: true
tls:
  enabled: true
```

2. **Scale for Production Load**
```bash
# Scale YugabyteDB
kubectl scale statefulset yb-tserver --replicas=3 -n codet-prod-yb

# Scale Kafka stack
./scripts/manage-cdc-stack.sh scale-up
```

3. **Add Monitoring**
```bash
# Deploy monitoring stack
kubectl apply -f manifests/monitoring/
```

### Best Practices

1. **Pattern Selection**
   - Use LISTEN/NOTIFY for immediate UI updates
   - Use Job Queue for critical background processing
   - Use CDC Events for analytics and audit trails
   - Combine patterns for comprehensive workflows

2. **Error Handling**
   - Implement exponential backoff in job workers
   - Use dead letter queues for failed jobs
   - Monitor CDC lag and alert on issues

3. **Security**
   - Use connection pooling for database connections
   - Implement proper authentication for Kafka
   - Encrypt sensitive data in job payloads

4. **Performance**
   - Co-locate related tables for better performance
   - Use appropriate indexing strategies
   - Monitor and tune based on usage patterns

## Next Steps

1. **Setup Basic Patterns**
   ```bash
   ./scripts/setup-messaging-patterns.sh
   ```

2. **Test Implementation**
   ```bash
   python examples/messaging-patterns-demo.py --pattern all
   ```

3. **Add Kafka (Optional)**
   ```bash
   ./scripts/deploy-cdc-kafka-stack.sh
   ```

4. **Monitor and Scale**
   ```bash
   ./scripts/manage-cdc-stack.sh monitor
   ```

This gives you a complete, cost-effective event-driven architecture that scales from development to production! 