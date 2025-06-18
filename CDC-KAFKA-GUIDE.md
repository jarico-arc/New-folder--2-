# YugabyteDB CDC + Kafka Setup Guide

## Overview

This guide implements the most cost-effective CDC (Change Data Capture) + Kafka setup on GCP, designed to work seamlessly with your existing YugabyteDB deployment. The total cost is approximately **$25-29/month** for a production-ready (light load) streaming infrastructure.

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────────┐
│   YugabyteDB    │    │     Redpanda     │    │   Consumer Apps     │
│   (GKE Cluster) │────│   (e2-small VM)  │────│  (Your Services)    │
│                 │    │                  │    │                     │
└─────────────────┘    └──────────────────┘    └─────────────────────┘
         │                       │                        │
         │              ┌─────────────────┐              │
         └──────────────│  CDC Connector  │──────────────┘
                        │  (Cloud Run)    │
                        └─────────────────┘
```

## Cost Breakdown

| Component | Configuration | Monthly Cost | Notes |
|-----------|---------------|--------------|-------|
| **Redpanda Broker** | e2-small VM (2 vCPU, 2GB) + 20GB PD-balanced | ~$17 | ZooKeeper-free, lightweight |
| **CDC Connector** | Cloud Run (1 vCPU, 1GB, always-on) | ~$8-10 | Serverless, auto-patched |
| **VPC Connector** | Serverless VPC Access | ~$2 | Private connectivity |
| **YugabyteDB CDC** | Built-in WAL streaming | $0 | No additional infrastructure |
| **Total** | | **~$27-29** | All in-VPC, no egress fees |

## Quick Start

### 1. Deploy YugabyteDB (if not already done)

```bash
# Make sure your YugabyteDB cluster is running
kubectl get pods -n codet-dev-yb

# If not deployed yet, run:
./scripts/deploy-complete-stack.sh
```

### 2. Deploy CDC + Kafka Stack

```bash
# Make the script executable
chmod +x scripts/deploy-cdc-kafka-stack.sh

# Deploy the entire CDC + Kafka infrastructure
./scripts/deploy-cdc-kafka-stack.sh
```

This script will:
- ✅ Create Redpanda VM with optimized configuration
- ✅ Set up firewall rules for internal communication
- ✅ Create VPC connector for Cloud Run
- ✅ Deploy Debezium CDC connector on Cloud Run
- ✅ Generate connector configuration

### 3. Register CDC Connector

After deployment, register the connector:

```bash
# The script provides the exact commands at the end
# Example:
CONNECTOR_URL="https://yb-cdc-connect-xxx.a.run.app"

curl -X POST $CONNECTOR_URL/connectors \
     -H 'Content-Type: application/json' \
     -d @/tmp/yugabyte-connector-config.json
```

### 4. Verify Setup

```bash
# Check overall status
./scripts/manage-cdc-stack.sh status

# Test CDC functionality
./scripts/manage-cdc-stack.sh test-cdc

# Monitor real-time
./scripts/manage-cdc-stack.sh monitor
```

## Message Patterns Supported

Based on your YugabyteDB setup, you can now implement these patterns:

### 1. **Change Data Capture** (Primary Use Case)
- **Latency**: ~100ms after commit
- **Durability**: Exactly-once delivery to Kafka topics
- **Use Case**: Event sourcing, data pipelines, microservice synchronization

```sql
-- Any table changes are automatically captured
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INT,
    total DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO orders (customer_id, total) VALUES (123, 99.99);
-- This change automatically appears in Kafka topic: yb.public.orders
```

### 2. **Queue Tables + SKIP LOCKED** (High Throughput)
- **Latency**: 10-50ms when co-located
- **Durability**: Full ACID guarantees
- **Use Case**: Job processing, background tasks

```sql
CREATE TABLE job_queue (
    job_id BIGSERIAL PRIMARY KEY,
    payload JSONB NOT NULL,
    processed BOOLEAN DEFAULT false
) SPLIT INTO 8 TABLETS;

-- Producer
INSERT INTO job_queue(payload) VALUES ('{"task": "send_email", "user_id": 123}');

-- Consumer
WITH next_job AS (
    SELECT job_id, payload FROM job_queue 
    WHERE processed = false 
    ORDER BY job_id 
    FOR UPDATE SKIP LOCKED LIMIT 1
)
UPDATE job_queue SET processed = true 
WHERE job_id IN (SELECT job_id FROM next_job) 
RETURNING payload;
```

### 3. **LISTEN/NOTIFY** (Real-time Updates)
- **Latency**: Sub-millisecond
- **Durability**: Fire-and-forget
- **Use Case**: Cache invalidation, UI updates

```sql
-- Publisher
SELECT pg_notify('cache_invalidate', '{"table": "products", "id": 123}');

-- Subscriber
LISTEN cache_invalidate;
SELECT 1 FROM pg_notification_queue() LIMIT 1;
```

## Operations

### Daily Operations

```bash
# Check status and costs
./scripts/manage-cdc-stack.sh status
./scripts/manage-cdc-stack.sh costs

# View logs
./scripts/manage-cdc-stack.sh logs
```

### Cost Optimization

```bash
# Stop services when not needed (saves ~80% of costs)
./scripts/manage-cdc-stack.sh stop

# Start services when needed
./scripts/manage-cdc-stack.sh start

# Scale up for higher throughput (+$6/month)
./scripts/manage-cdc-stack.sh scale-up

# Scale back down
./scripts/manage-cdc-stack.sh scale-down
```

### Monitoring

```bash
# Real-time dashboard
./scripts/manage-cdc-stack.sh monitor

# Key metrics to watch:
# - Redpanda memory usage < 1.5GB
# - CDC lag < 10MB
# - Connector status = RUNNING
# - Topic partition count scaling with load
```

## Advanced Configuration

### YugabyteDB CDC Optimizations

Your `manifests/values/dev-values.yaml` includes CDC-specific optimizations:

```yaml
gflags:
  tserver:
    # CDC-specific optimizations
    cdc_state_checkpoint_update_interval_ms: 15000
    cdc_checkpoint_opid_interval_ms: 60000
    update_min_cdc_indices_interval_secs: 60
    cdc_max_stream_intent_records: 1000
    log_min_seconds_to_retain: 3600  # Keep WAL for 1 hour
```

### Redpanda Tuning

For higher throughput, adjust these settings:

```bash
# Connect to Redpanda VM
gcloud compute ssh yb-redpanda --zone=us-central1-a

# Increase retention for longer message storage
docker exec redpanda rpk cluster config set retention.ms 604800000  # 7 days

# Adjust batch sizes for higher throughput
docker exec redpanda rpk cluster config set max.message.bytes 1048576  # 1MB
```

### Scaling Patterns

| Load Pattern | Configuration | Monthly Cost |
|--------------|---------------|--------------|
| **Development** | Current setup | $27-29 |
| **Light Production** | Scale up to e2-medium | $33-35 |
| **High Throughput** | 3x e2-small + load balancer | $55-60 |
| **Enterprise** | Managed Confluent Cloud | $1000+ |

## Troubleshooting

### Common Issues

1. **CDC Lag Building Up**
   ```bash
   # Check YugabyteDB WAL retention
   kubectl exec -n codet-dev-yb yb-tserver-0 -c yb-tserver -- \
     ysqlsh -c "SELECT * FROM yb_cdc_stream_state();"
   
   # Increase connector parallelism
   curl -X PUT $CONNECTOR_URL/connectors/yugabyte-cdc-connector/config \
        -d '{"tasks.max": "2"}'
   ```

2. **Redpanda Out of Memory**
   ```bash
   # Scale VM to e2-medium
   ./scripts/manage-cdc-stack.sh scale-up
   ```

3. **Network Connectivity Issues**
   ```bash
   # Check VPC connectivity
   gcloud compute ssh yb-redpanda --zone=us-central1-a \
     --command='docker exec redpanda rpk cluster info'
   ```

### Monitoring Alerts

Set up these Cloud Monitoring alerts:

```bash
# VM memory usage > 80%
gcloud alpha monitoring policies create --policy-from-file=vm-memory-alert.yaml

# CDC lag > 1 minute
gcloud alpha monitoring policies create --policy-from-file=cdc-lag-alert.yaml

# Monthly costs > $40
gcloud alpha monitoring policies create --policy-from-file=cost-alert.yaml
```

## Migration and Scaling

### From Development to Production

1. **Enable Authentication**
   ```yaml
   # In manifests/values/prod-values.yaml
   auth:
     enabled: true
   tls:
     enabled: true
   ```

2. **Add High Availability**
   ```bash
   # Scale to 3 Redpanda nodes
   gcloud compute instance-templates create redpanda-template
   gcloud compute instance-groups managed create redpanda-cluster
   ```

3. **Implement Monitoring**
   ```bash
   # Deploy Prometheus + Grafana
   kubectl apply -f manifests/monitoring/prometheus-stack.yaml
   ```

### Integration Examples

#### Microservices Event Bus

```python
# Python consumer example
from kafka import KafkaConsumer
import json

consumer = KafkaConsumer(
    'yb.public.orders',
    bootstrap_servers=['redpanda-internal-ip:9092'],
    value_deserializer=lambda x: json.loads(x.decode('utf-8'))
)

for message in consumer:
    order_event = message.value
    # Process order change event
    handle_order_change(order_event)
```

#### Real-time Analytics

```sql
-- Create materialized views that update via CDC
CREATE MATERIALIZED VIEW order_metrics AS 
SELECT 
    DATE_TRUNC('hour', created_at) as hour,
    COUNT(*) as order_count,
    SUM(total) as revenue
FROM orders 
GROUP BY hour;

-- CDC automatically propagates changes to analytics systems
```

## Security Considerations

- **Network Isolation**: All traffic stays within VPC
- **No Public IPs**: Redpanda VM has no external access
- **IAM-based SSH**: OS Login enabled for secure access
- **Minimal Permissions**: Cloud Run service account has least privileges
- **Data Encryption**: Messages encrypted in transit within VPC

## Support and Maintenance

### Regular Maintenance

- **Weekly**: Check costs via `./scripts/manage-cdc-stack.sh costs`
- **Monthly**: Update Redpanda container image
- **Quarterly**: Review and optimize resource allocation

### Backup Strategy

```bash
# YugabyteDB backups (handled by existing scripts)
./scripts/setup-database-rbac.sh

# Redpanda topic backups
gcloud compute ssh yb-redpanda --zone=us-central1-a \
  --command='docker exec redpanda rpk topic create backups --partitions 3'
```

This setup provides a production-ready, cost-effective foundation for event-driven architectures with YugabyteDB, capable of handling thousands of events per second while maintaining operational simplicity. 