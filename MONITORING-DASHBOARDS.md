# YugabyteDB Multi-Cluster Monitoring Dashboards

## 📊 Overview

This document describes the comprehensive monitoring dashboards for the YugabyteDB multi-cluster deployment across Development, Staging, and Production environments.

## 🎯 Dashboard Architecture

### Dashboard Structure
```
Grafana Dashboards
├── 🌍 Multi-Cluster Overview
│   ├── Cluster Health Status
│   ├── Cross-Region Replication
│   ├── Performance Metrics
│   └── Resource Utilization
├── 🔍 Environment Details
│   ├── Per-Environment Deep Dive
│   ├── Resource Monitoring
│   ├── Database Specific Metrics
│   └── Backup Status
└── ☸️ Kubernetes Infrastructure
    ├── Node Health
    ├── Pod Status
    ├── Network & Storage
    └── Cluster Events
```

## 📈 Dashboard Details

### 1. YugabyteDB Multi-Cluster Overview

**Purpose**: High-level view of all three clusters (Dev, Staging, Production)

#### Key Panels:
- **Cluster Health Status**: Real-time status of all masters and tservers
- **Cross-Region Replication Lag**: Monitoring replication latency between regions
- **Regional Distribution**: Visual representation of cluster distribution
- **Database Connections**: Active connections across environments
- **Operations Per Second**: CRUD operations rate by cluster
- **Memory Usage**: Memory consumption across all environments
- **Tablet Servers Status**: Current tablet server count and health
- **Query Latency P99**: Performance metrics with P95/P99 percentiles

#### Key Metrics:
```promql
# Cluster Health
up{job=~"yugabyte-master-helm", kubernetes_namespace=~"codet-.*"}
up{job=~"yugabyte-tserver-helm", kubernetes_namespace=~"codet-.*"}

# Performance
rate(yugabytedb_sql_selects{kubernetes_namespace=~"codet-.*"}[5m])
histogram_quantile(0.99, rate(yugabytedb_sql_latency_bucket[5m]))

# Replication
yugabytedb_cdc_max_apply_index_lag_ms{kubernetes_namespace=~"codet-.*"}
```

#### Alerts Integration:
- **Green**: All systems operational
- **Yellow**: Performance degradation or warnings
- **Red**: Critical issues requiring immediate attention

### 2. YugabyteDB Environment Details

**Purpose**: Deep-dive monitoring for individual environments with drill-down capabilities

#### Environment Selection:
- Dynamic dropdown to select specific cluster (Dev/Staging/Production)
- Environment-specific thresholds and configurations

#### Key Panels:
- **Environment Overview**: Status summary for selected environment
- **Master/TServer Node Status**: Individual node health monitoring
- **SQL Operations Rate**: Detailed CRUD operation breakdown
- **Response Time Distribution**: P50, P95, P99 latency analysis
- **CPU/Memory/Disk Usage**: Resource utilization per pod
- **Tablet Distribution**: Tablet count and distribution metrics
- **RPC Queue Size**: Internal queue monitoring for performance
- **Backup Status**: Production backup monitoring (when applicable)

#### Environment-Specific Features:
```yaml
Development:
  - Refresh: 30s
  - Retention: 1h
  - Alerts: Low priority

Staging:
  - Refresh: 15s  
  - Retention: 6h
  - Alerts: Medium priority
  - Auth monitoring enabled

Production:
  - Refresh: 10s
  - Retention: 24h
  - Alerts: High priority
  - Full security monitoring
  - Backup status tracking
```

### 3. Kubernetes Infrastructure

**Purpose**: Underlying Kubernetes cluster health and resource monitoring

#### Key Panels:
- **Cluster Resource Overview**: Node count, CPU cores, memory, running pods
- **Resource Utilization**: CPU and memory usage by node
- **Network Traffic**: Inter-node network I/O monitoring
- **Disk I/O**: Storage performance metrics
- **Pod Status Distribution**: Pod lifecycle status across namespaces
- **Pod Restarts**: Container restart frequency and patterns
- **Persistent Volume Usage**: Storage utilization and capacity planning
- **Cluster Events**: Kubernetes events and warnings

#### Infrastructure Alerts:
- **Node Health**: Node readiness and availability
- **Resource Exhaustion**: CPU, memory, and storage thresholds
- **Network Issues**: Connectivity and throughput problems
- **Pod Issues**: Crash loops, failed starts, resource constraints

## 🚨 Alert Rules

### Critical Alerts (Immediate Response Required)
- **YugabyteDBMasterDown**: Master node unavailable (>2 min)
- **YugabyteDBTServerDown**: TServer node unavailable (>2 min)
- **YugabyteDBCrossRegionConnectivityLoss**: Multi-cluster connectivity issues
- **YugabyteDBBackupFailed**: Backup failure (>24 hours)

### Warning Alerts (Investigation Required)
- **YugabyteDBHighLatency**: P99 latency >1000ms (>5 min)
- **YugabyteDBHighReplicationLag**: Replication lag >5000ms (>5 min)
- **YugabyteDBHighConnectionCount**: Connection count >500 (>5 min)
- **YugabyteDBHighMemoryUsage**: Memory usage >85% (>10 min)
- **YugabyteDBLowDiskSpace**: Disk usage >80% (>10 min)

### Environment-Specific Alert Routing:
```yaml
Production:
  Critical: → Oncall Team (Email + Slack)
  Warning: → DevOps Team (Email)
  
Staging:
  All: → Staging Channel (Slack)
  
Development:
  All: → Development Webhook (Low priority)
```

## 🛠️ Deployment

### Prerequisites:
- Prometheus Operator installed
- Grafana deployed with dashboard provisioning
- Proper RBAC for metrics collection

### Deployment Commands:
```bash
# Deploy complete monitoring stack
make monitoring-full

# Deploy only dashboards
make deploy-dashboards

# Deploy monitoring stack
make deploy-monitoring
```

### Manual Deployment:
```bash
# Create monitoring namespace
kubectl create namespace monitoring

# Deploy datasources and providers
kubectl apply -f manifests/monitoring/grafana-datasources.yaml

# Deploy dashboard ConfigMaps
kubectl create configmap grafana-dashboard-yugabytedb-overview \
  --from-file=manifests/monitoring/dashboards/yugabytedb-cluster-overview.json \
  --namespace=monitoring

kubectl label configmap grafana-dashboard-yugabytedb-overview grafana_dashboard=1 -n monitoring

# Deploy alerts
kubectl apply -f manifests/monitoring/yugabytedb-alerts.yaml
```

### Dashboard Access:
After deployment, dashboards are available at:
- **Multi-Cluster Overview**: `http://grafana.local/d/yugabytedb-multi-cluster`
- **Environment Details**: `http://grafana.local/d/yugabytedb-environment-details`
- **Kubernetes Infrastructure**: `http://grafana.local/d/kubernetes-infrastructure`

## 📊 Data Sources

### Primary Data Sources:
- **Prometheus**: Main metrics collection and storage
- **YugabyteDB-Dev**: Development cluster specific metrics (30s interval)
- **YugabyteDB-Staging**: Staging cluster specific metrics (15s interval)
- **YugabyteDB-Prod**: Production cluster specific metrics (10s interval)
- **Loki-MultiCluster**: Log aggregation across all clusters

### Metric Collection:
```yaml
Scrape Targets:
  - yugabyte-master-helm: YugabyteDB masters (:7000/prometheus-metrics)
  - yugabyte-tserver-helm: YugabyteDB tservers (:9000/prometheus-metrics)
  - kubernetes-pods: Pod metrics via cAdvisor
  - kubernetes-nodes: Node metrics via node-exporter

Namespaces:
  - codet-dev-yb: Development environment
  - codet-staging-yb: Staging environment  
  - codet-prod-yb: Production environment
```

## 🔧 Customization

### Environment Variables:
```bash
# Customize cluster names
export DEV_CLUSTER="codet-dev-yb"
export STAGING_CLUSTER="codet-staging-yb"
export PROD_CLUSTER="codet-prod-yb"

# Customize alert thresholds
export LATENCY_THRESHOLD="1000"      # ms
export REPLICATION_LAG_THRESHOLD="5000"  # ms
export MEMORY_THRESHOLD="85"         # %
export DISK_THRESHOLD="80"           # %
```

### Dashboard Customization:
1. **Time Ranges**: Adjust default time ranges per environment
2. **Refresh Intervals**: Modify auto-refresh rates
3. **Thresholds**: Update alert thresholds based on SLAs
4. **Templating**: Add custom template variables
5. **Annotations**: Add deployment and maintenance annotations

### Adding Custom Panels:
```json
{
  "id": 99,
  "title": "Custom Metric",
  "type": "timeseries",
  "targets": [
    {
      "expr": "your_custom_metric{kubernetes_namespace=~\"codet-.*\"}",
      "legendFormat": "{{instance}}",
      "refId": "A"
    }
  ]
}
```

## 📋 Operational Procedures

### Daily Monitoring Checklist:
- [ ] Check multi-cluster overview dashboard
- [ ] Verify all clusters are healthy (green status)
- [ ] Review replication lag metrics
- [ ] Check resource utilization trends
- [ ] Verify backup completion (staging/production)

### Weekly Monitoring Review:
- [ ] Analyze performance trends
- [ ] Review alert frequency and patterns
- [ ] Check capacity planning metrics
- [ ] Update dashboard thresholds if needed
- [ ] Review and tune alert rules

### Incident Response:
1. **Check Multi-Cluster Overview** for immediate cluster status
2. **Switch to Environment Details** for affected cluster deep-dive
3. **Review Kubernetes Infrastructure** for underlying issues
4. **Check Alert History** for related warnings
5. **Use Runbook URLs** in alerts for specific troubleshooting

## 🔍 Troubleshooting

### Common Issues:

#### Missing Metrics:
```bash
# Check scrape targets
kubectl get servicemonitor -n monitoring

# Verify pod labels
kubectl get pods -n codet-dev-yb --show-labels

# Check Prometheus targets
curl http://prometheus:9090/api/v1/targets
```

#### Dashboard Not Loading:
```bash
# Check ConfigMap labels
kubectl get configmaps -n monitoring -l grafana_dashboard=1

# Verify Grafana provisioning
kubectl logs -n monitoring deployment/grafana
```

#### Alert Not Firing:
```bash
# Check PrometheusRule
kubectl get prometheusrule -n monitoring

# Verify alert expression
kubectl exec -n monitoring prometheus-0 -- promtool query instant "your_alert_expression"
```

### Performance Optimization:
- **Recording Rules**: Pre-calculate expensive queries
- **Retention Policies**: Set appropriate data retention per environment
- **Query Optimization**: Use efficient PromQL queries
- **Dashboard Optimization**: Limit concurrent queries

## 📚 References

### YugabyteDB Metrics:
- [YugabyteDB Monitoring Guide](https://docs.yugabyte.com/latest/explore/observability/)
- [Prometheus Metrics Reference](https://docs.yugabyte.com/latest/reference/configuration/yb-tserver/#prometheus-metrics)

### Grafana Resources:
- [Dashboard Best Practices](https://grafana.com/docs/grafana/latest/best-practices/)
- [Templating Guide](https://grafana.com/docs/grafana/latest/variables/)

### Prometheus:
- [PromQL Guide](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Alert Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)

---

**Dashboard Version**: 1.0  
**Last Updated**: Current  
**Maintained By**: DevOps Team  
**Support**: [Create an issue](https://github.com/your-org/yugabytedb-multi-cluster/issues) 