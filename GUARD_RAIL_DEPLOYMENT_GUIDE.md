# YugabyteDB Guard-Rail Solution Deployment Guide

This guide walks you through deploying the complete observability and governance solution for your YugabyteDB multi-cluster setup.

## 🎯 Solution Overview

Your guard-rail solution now includes:

### ✅ **Enhanced Observability**
- **Prometheus Stack** with node-exporter, SMART monitoring, and kubelet volume stats
- **PostgreSQL Exporter** for client activity tracking via `pg_stat_statements`
- **Advanced Alert Rules** for client governance, infrastructure health, and backup validation
- **Client Activity Dashboard** showing top clients by CPU usage, connections, and query patterns

### ✅ **Governance & Control**
- **Resource Quotas** per environment (Dev/Staging/Prod)
- **Limit Ranges** to prevent resource abuse
- **Network Policies** with graduated security (open dev → restricted prod)
- **Storage Classes** for different performance tiers
- **Pod Disruption Budgets** for availability control

---

## 🚀 Deployment Steps

### 1. **Prerequisites Setup**

First, enable `pg_stat_statements` in your YugabyteDB clusters:

```bash
# Connect to each cluster and enable pg_stat_statements
kubectl exec -n codet-dev-yb yb-tserver-0 -- ysqlsh -h localhost -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
kubectl exec -n codet-staging-yb yb-tserver-0 -- ysqlsh -h localhost -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
kubectl exec -n codet-prod-yb yb-tserver-0 -- ysqlsh -h localhost -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

### 2. **Update Database Connection Secrets**

Update the PostgreSQL exporter secrets with your actual YugabyteDB credentials:

```bash
# Get current yugabyte passwords
DEV_PASSWORD=$(kubectl get secret -n codet-dev-yb yugabyte-db-yugabyte-db-secret -o jsonpath='{.data.password}' | base64 -d)
STAGING_PASSWORD=$(kubectl get secret -n codet-staging-yb yugabyte-db-yugabyte-db-secret -o jsonpath='{.data.password}' | base64 -d)
PROD_PASSWORD=$(kubectl get secret -n codet-prod-yb yugabyte-db-yugabyte-db-secret -o jsonpath='{.data.password}' | base64 -d)

# Update the postgres-exporter secret
kubectl patch secret postgres-exporter-secret -n monitoring --type='merge' -p="{
  \"stringData\": {
    \"dev-connection\": \"postgresql://yugabyte:${DEV_PASSWORD}@yb-tservers.codet-dev-yb.svc.cluster.local:5433/yugabyte?sslmode=prefer\",
    \"staging-connection\": \"postgresql://yugabyte:${STAGING_PASSWORD}@yb-tservers.codet-staging-yb.svc.cluster.local:5433/yugabyte?sslmode=require\",
    \"prod-connection\": \"postgresql://yugabyte:${PROD_PASSWORD}@yb-tservers.codet-prod-yb.svc.cluster.local:5433/yugabyte?sslmode=require\"
  }
}"
```

### 3. **Deploy Enhanced Monitoring Stack**

```bash
# Deploy the enhanced Prometheus stack with all exporters
kubectl apply -f manifests/monitoring/prometheus-stack.yaml

# Deploy PostgreSQL exporters for client activity monitoring
kubectl apply -f manifests/monitoring/postgres-exporter.yaml

# Deploy enhanced alert rules
kubectl apply -f manifests/monitoring/yugabytedb-alerts.yaml

# Verify deployments
kubectl get pods -n monitoring
kubectl get servicemonitors -n monitoring
```

### 4. **Deploy Governance and Control Policies**

```bash
# Apply resource quotas and network policies
kubectl apply -f manifests/policies/resource-governance.yaml

# Verify resource quotas are applied
kubectl describe resourcequota -n codet-dev-yb
kubectl describe resourcequota -n codet-staging-yb  
kubectl describe resourcequota -n codet-prod-yb

# Check network policies
kubectl get networkpolicies --all-namespaces
```

### 5. **Configure Alertmanager Secrets**

Set up external alert integrations:

```bash
# Create PagerDuty integration key (replace YOUR_PAGERDUTY_KEY)
kubectl create secret generic pagerduty-key -n monitoring \
  --from-literal=pagerduty-key="YOUR_PAGERDUTY_INTEGRATION_KEY"

# Create Slack webhook URL secret (replace YOUR_SLACK_WEBHOOK)
kubectl create secret generic slack-webhook-url -n monitoring \
  --from-literal=slack-webhook-url="https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK"

# Mount secrets to AlertManager
kubectl patch statefulset alertmanager-kube-prometheus-stack-alertmanager -n monitoring \
  --patch '{"spec":{"template":{"spec":{"volumes":[{"name":"pagerduty-secret","secret":{"secretName":"pagerduty-key"}},{"name":"slack-secret","secret":{"secretName":"slack-webhook-url"}}],"containers":[{"name":"alertmanager","volumeMounts":[{"name":"pagerduty-secret","mountPath":"/etc/alertmanager/secrets","readOnly":true},{"name":"slack-secret","mountPath":"/etc/alertmanager/secrets","readOnly":true}]}]}}}}'
```

---

## 📊 Accessing Your Guard-Rail Dashboards

### 1. **Port Forward to Grafana**

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

### 2. **Login to Grafana**

- URL: http://localhost:3000
- Username: `admin`  
- Password: Get from secret:
  ```bash
  kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
  ```

### 3. **Import Client Activity Dashboard**

The client activity dashboard is automatically provisioned, showing:
- **Top Clients by CPU Usage** - identify resource-hungry clients
- **Active Connections per Client** - spot connection leaks
- **Query Rate and Latency** - performance impact per client
- **Buffer Cache Hit Ratios** - efficiency metrics
- **Resource Quota Usage** - governance compliance
- **Active Governance Alerts** - real-time issues

---

## 🔍 Key Monitoring Queries

### **Identify Noisy Clients**
```promql
topk(10, 
  (
    sum by(client_ip, kubernetes_namespace) (
      rate(pg_stat_statements_total_time_seconds_total[5m])
    ) 
    / 
    sum by(kubernetes_namespace) (
      rate(node_cpu_seconds_total{mode!="idle"}[5m])
    )
  ) * 100
)
```

### **Client Connection Count**
```promql
sum by(client_ip, kubernetes_namespace) (
  pg_stat_activity_connections{state="active"}
)
```

### **Disk Health Status**
```promql
smartctl_device_smart_healthy == 0
```

### **Volume Space Usage**
```promql
(
  kubelet_volume_stats_used_bytes{namespace=~"codet-.*"} 
  / 
  kubelet_volume_stats_capacity_bytes{namespace=~"codet-.*"}
) * 100
```

---

## ⚠️ Alert Response Playbook

### **Client Governance Alerts**

#### `YugabyteDBNoisyClient` 
**Trigger:** Client consuming >40% cluster CPU
**Response:**
1. Check client IP and query patterns in Grafana
2. Review `pg_stat_statements` for expensive queries
3. Contact client team for optimization
4. Consider connection limits: `ALTER ROLE username CONNECTION LIMIT 50;`
5. Apply namespace resource quota if needed

#### `YugabyteDBHighClientConnections`
**Trigger:** Client >100 active connections
**Response:**
1. Investigate connection pooling setup
2. Check for connection leaks in application
3. Set user-level connection limits
4. Consider pgbouncer deployment for connection pooling

### **Infrastructure Alerts**

#### `DiskHealthDegraded`
**Trigger:** SMART health check failed
**Response:**
1. **IMMEDIATE:** Check disk replacement schedule
2. Migrate data to healthy nodes if possible
3. Contact infrastructure team for hardware replacement
4. Monitor backup status to ensure data safety

#### `VolumeInodeExhaustion` 
**Trigger:** >90% inodes used
**Response:**
1. Identify files consuming inodes: `find /mnt/data -type f | wc -l`
2. Clean up temporary files and old log files
3. Consider volume expansion or data cleanup
4. Check for file descriptor leaks in applications

---

## 🎛️ Governance Actions

### **Throttle Noisy Client**
```bash
# Option 1: Reduce connection limit
kubectl exec -n codet-prod-yb yb-tserver-0 -- ysqlsh -c "ALTER ROLE clientuser CONNECTION LIMIT 10;"

# Option 2: Reduce namespace resource quota
kubectl patch resourcequota codet-prod-yb-quota -n codet-prod-yb --type='merge' -p='{"spec":{"hard":{"requests.cpu":"8","limits.cpu":"16"}}}'
```

### **Emergency Circuit Breaker**
```bash
# Block problematic client via network policy
kubectl patch networkpolicy codet-prod-yb-netpol -n codet-prod-yb --type='merge' -p='{
  "spec": {
    "ingress": [{
      "from": [{
        "podSelector": {
          "matchExpressions": [{
            "key": "client-ip",
            "operator": "NotIn", 
            "values": ["PROBLEM_CLIENT_IP"]
          }]
        }
      }]
    }]
  }
}'
```

---

## 🔧 Maintenance Operations

### **Scale Monitoring Resources**
```bash
# Increase Prometheus retention for long-term analysis
kubectl patch prometheus kube-prometheus-stack-prometheus -n monitoring --type='merge' -p='{"spec":{"retention":"60d","retentionSize":"200GiB"}}'

# Scale up Grafana for multiple users
kubectl scale deployment kube-prometheus-stack-grafana -n monitoring --replicas=2
```

### **Backup Monitoring Data**
```bash
# Create Prometheus snapshot for backup
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  curl -XPOST http://localhost:9090/api/v1/admin/tsdb/snapshot
```

---

## ✅ Verification Checklist

After deployment, verify:

- [ ] All exporters are running and being scraped by Prometheus
- [ ] Client activity metrics are appearing in Grafana dashboard
- [ ] Alert rules are loaded and evaluating correctly  
- [ ] Resource quotas are enforced (test by creating oversized pod)
- [ ] Network policies are blocking unauthorized traffic
- [ ] SMART monitoring is collecting disk health data
- [ ] Backup alerts are configured and functioning
- [ ] AlertManager is routing alerts to correct channels

---

## 🔄 Next Steps

1. **Train your team** on the new dashboards and alert responses
2. **Set up regular reviews** of client resource usage patterns
3. **Tune alert thresholds** based on your specific workload patterns
4. **Implement automated remediation** for common governance scenarios
5. **Extend client tagging** for better categorization and billing

Your complete guard-rail solution is now deployed! You have full visibility into client activity and the control mechanisms to maintain optimal resource utilization across your YugabyteDB multi-cluster deployment. 