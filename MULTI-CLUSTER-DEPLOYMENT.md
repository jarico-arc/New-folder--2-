# YugabyteDB Multi-Cluster Deployment Guide

This guide provides step-by-step instructions for deploying 3 YugabyteDB clusters (`Codet-Dev-YB`, `Codet-Staging-YB`, `Codet-Prod-YB`) across multiple GKE regions using private VPC networking.

## Architecture Overview

- **Codet-Dev-YB**: Development cluster in `us-west1-b`
- **Codet-Staging-YB**: Staging cluster in `us-central1-b`  
- **Codet-Prod-YB**: Production cluster in `us-east1-b`

All clusters are connected in a multi-cluster configuration with private networking and no localhost access.

## Prerequisites

### Required Tools
- `gcloud` CLI (latest version)
- `kubectl` (v1.28+)
- `helm` (v3.12+)
- Active GCP project with billing enabled

### Required Permissions
- `Kubernetes Engine Admin`
- `Compute Network Admin`
- `Storage Admin`
- `Service Account Admin`

### Verify Prerequisites
```bash
# Run the prerequisite check
./scripts/create-multi-cluster-yugabytedb.sh prerequisites
```

## Quick Start

### 1. Complete Deployment
Deploy all components with a single command:
```bash
# Make script executable
chmod +x scripts/create-multi-cluster-yugabytedb.sh

# Deploy everything
./scripts/create-multi-cluster-yugabytedb.sh all
```

### 2. Step-by-Step Deployment
For more control, deploy components individually:

```bash
# 1. Create private VPC network
./scripts/create-multi-cluster-yugabytedb.sh vpc

# 2. Create GKE clusters
./scripts/create-multi-cluster-yugabytedb.sh clusters

# 3. Set up storage classes
./scripts/create-multi-cluster-yugabytedb.sh storage

# 4. Configure DNS
./scripts/create-multi-cluster-yugabytedb.sh dns

# 5. Create namespaces
./scripts/create-multi-cluster-yugabytedb.sh namespaces

# 6. Generate Helm override files
./scripts/create-multi-cluster-yugabytedb.sh overrides

# 7. Install YugabyteDB
./scripts/create-multi-cluster-yugabytedb.sh install

# 8. Configure replica placement
./scripts/create-multi-cluster-yugabytedb.sh placement

# 9. Validate deployment
./scripts/create-multi-cluster-yugabytedb.sh validate

# 10. Show connection info
./scripts/create-multi-cluster-yugabytedb.sh info
```

## Network Architecture

### VPC Configuration
- **VPC Name**: `yugabytedb-private-vpc`
- **Subnets**:
  - `dev-subnet`: `10.1.0.0/16` (us-west1)
  - `staging-subnet`: `10.2.0.0/16` (us-central1)
  - `prod-subnet`: `10.3.0.0/16` (us-east1)

### Firewall Rules
- Internal YugabyteDB communication (ports 7000, 7100, 9000, 9100, 5433, 9042, 6379)
- DNS resolution (port 53)
- HTTPS for updates (port 443)

### Security Features
- Private GKE clusters with no external IPs
- Internal load balancers only
- Network policies for traffic isolation
- Pod security policies enforced

## Cluster Specifications

### Development (Codet-Dev-YB)
- **Region**: us-west1
- **Zone**: us-west1-b
- **Nodes**: 1 (e2-standard-4)
- **Storage**: 100Gi SSD per volume
- **Resources**: 1 CPU, 2Gi RAM (master), 2 CPU, 4Gi RAM (tserver)
- **Security**: Basic auth disabled, TLS disabled
- **Backup**: Disabled

### Staging (Codet-Staging-YB)
- **Region**: us-central1
- **Zone**: us-central1-b
- **Nodes**: 2 (e2-standard-4)
- **Storage**: 200Gi SSD per volume
- **Resources**: 1.5 CPU, 3Gi RAM (master), 3 CPU, 6Gi RAM (tserver)
- **Security**: Auth enabled, TLS optional
- **Backup**: Daily at 3 AM, 7-day retention

### Production (Codet-Prod-YB)
- **Region**: us-east1
- **Zone**: us-east1-b
- **Nodes**: 3 (e2-standard-8)
- **Storage**: 500Gi SSD per volume
- **Resources**: 2 CPU, 4Gi RAM (master), 4 CPU, 8Gi RAM (tserver)
- **Security**: Full auth + TLS enabled, audit logging
- **Backup**: Daily at 2 AM, 30-day retention, encrypted

## Post-Deployment Configuration

### 1. Cluster Access
Get cluster contexts:
```bash
# List contexts
kubectl config get-contexts

# Switch to specific cluster
kubectl config use-context codet-dev-yb-context
kubectl config use-context codet-staging-yb-context
kubectl config use-context codet-prod-yb-context
```

### 2. Database Connections

#### Development Environment
```bash
# YSQL (PostgreSQL-compatible)
kubectl exec -n codet-dev-yb -it yb-tserver-0 -- ysqlsh -h yb-tserver-0.yb-tservers.codet-dev-yb

# YCQL (Cassandra-compatible)
kubectl exec -n codet-dev-yb -it yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.codet-dev-yb
```

#### Staging Environment
```bash
# YSQL with authentication
kubectl exec -n codet-staging-yb -it yb-tserver-0 -- ysqlsh -h yb-tserver-0.yb-tservers.codet-staging-yb -U yugabyte

# YCQL with authentication
kubectl exec -n codet-staging-yb -it yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.codet-staging-yb -u yugabyte
```

#### Production Environment
```bash
# YSQL with TLS and authentication
kubectl exec -n codet-prod-yb -it yb-tserver-0 -- ysqlsh "host=yb-tserver-0.yb-tservers.codet-prod-yb port=5433 dbname=yugabyte user=yugabyte sslmode=require"

# YCQL with TLS and authentication
kubectl exec -n codet-prod-yb -it yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.codet-prod-yb 9042 --ssl -u yugabyte
```

### 3. Web UI Access
Get load balancer IPs:
```bash
# Development
kubectl get svc -n codet-dev-yb yb-master-ui

# Staging
kubectl get svc -n codet-staging-yb yb-master-ui

# Production
kubectl get svc -n codet-prod-yb yb-master-ui
```

## Multi-Cluster Features

### Cross-Cluster Replication
The clusters are configured for cross-region replication:
- **Replication Factor**: 3 (across all regions)
- **Placement Policy**: 1 replica per region
- **Consistency**: Strong consistency with automatic failover

### Data Distribution
```bash
# Check cluster placement
kubectl exec -n codet-dev-yb yb-master-0 -- yb-admin --master_addresses=yb-master-0.yb-masters.codet-dev-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-staging-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 list_all_tablet_servers

# View universe configuration
kubectl exec -n codet-dev-yb yb-master-0 -- yb-admin --master_addresses=yb-master-0.yb-masters.codet-dev-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-staging-yb.svc.cluster.local:7100,yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 get_universe_config
```

## Monitoring and Observability

### Prometheus Metrics
All clusters expose metrics on port 9000 (master) and 9100 (tserver):
```bash
# Check metrics endpoints
kubectl get servicemonitor -n monitoring
```

### Logs
```bash
# View master logs
kubectl logs -n codet-dev-yb yb-master-0

# View tserver logs
kubectl logs -n codet-dev-yb yb-tserver-0

# Follow logs in real-time
kubectl logs -n codet-dev-yb -f yb-master-0
```

### Health Checks
```bash
# Check pod health
kubectl get pods -n codet-dev-yb
kubectl get pods -n codet-staging-yb
kubectl get pods -n codet-prod-yb

# Check services
kubectl get svc -n codet-dev-yb
kubectl get svc -n codet-staging-yb
kubectl get svc -n codet-prod-yb
```

## Backup and Recovery

### Automated Backups
- **Staging**: Daily backups at 3 AM UTC, 7-day retention
- **Production**: Daily backups at 2 AM UTC, 30-day retention with encryption

### Manual Backup
```bash
# Create manual backup (production)
kubectl exec -n codet-prod-yb yb-master-0 -- yb-admin --master_addresses=yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 create_snapshot ysql.yugabyte
```

### Backup Locations
- **Staging**: `gs://codet-staging-yb-backups`
- **Production**: `gs://codet-prod-yb-backups`

## Security Considerations

### Authentication
- **Development**: Disabled for easy access
- **Staging**: Enabled with basic credentials
- **Production**: Enabled with strong credentials and RBAC

### TLS Encryption
- **Development**: Disabled
- **Staging**: Optional
- **Production**: Mandatory for all communications

### Network Security
- All clusters use private IPs only
- Internal load balancers with VPC-native networking
- Network policies restrict cross-namespace communication
- Pod security policies enforce security contexts

### Secrets Management
```bash
# View existing secrets (don't display values)
kubectl get secrets -n codet-dev-yb
kubectl get secrets -n codet-staging-yb
kubectl get secrets -n codet-prod-yb

# Update production credentials (example)
kubectl create secret generic codet-prod-yb-credentials \
  --from-literal=yugabyte.password=NEW_SECURE_PASSWORD \
  --from-literal=postgres.password=NEW_SECURE_PASSWORD \
  -n codet-prod-yb \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Troubleshooting

### Common Issues

#### Pods Not Starting
```bash
# Check pod events
kubectl describe pod -n codet-dev-yb yb-master-0

# Check resource constraints
kubectl top nodes
kubectl top pods -n codet-dev-yb
```

#### Network Connectivity Issues
```bash
# Test internal DNS
kubectl exec -n codet-dev-yb yb-master-0 -- nslookup yb-master-0.yb-masters.codet-staging-yb.svc.cluster.local

# Check network policies
kubectl get networkpolicy -n codet-dev-yb
```

#### Storage Issues
```bash
# Check PVCs
kubectl get pvc -n codet-dev-yb

# Check storage classes
kubectl get storageclass
```

### Recovery Procedures

#### Cluster Recovery
```bash
# Restart specific components
kubectl rollout restart statefulset/yb-master -n codet-dev-yb
kubectl rollout restart statefulset/yb-tserver -n codet-dev-yb

# Check rollout status
kubectl rollout status statefulset/yb-master -n codet-dev-yb
```

#### Data Recovery
```bash
# List available snapshots
kubectl exec -n codet-prod-yb yb-master-0 -- yb-admin --master_addresses=yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 list_snapshots

# Restore from snapshot
kubectl exec -n codet-prod-yb yb-master-0 -- yb-admin --master_addresses=yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 restore_snapshot <snapshot_id>
```

## Scaling Operations

### Horizontal Scaling
```bash
# Scale tservers (example for staging)
helm upgrade codet-staging-yb yugabytedb/yugabyte \
  --namespace codet-staging-yb \
  -f manifests/values/multi-cluster/overrides-codet-staging-yb.yaml \
  --set replicas.tserver=3
```

### Vertical Scaling
Update resource specifications in the override files and upgrade:
```bash
# Update resources in override file, then:
helm upgrade codet-staging-yb yugabytedb/yugabyte \
  --namespace codet-staging-yb \
  -f manifests/values/multi-cluster/overrides-codet-staging-yb.yaml
```

## Maintenance

### Regular Tasks
1. **Daily**: Check cluster health and backup status
2. **Weekly**: Review metrics and logs for anomalies
3. **Monthly**: Update Helm charts and security patches
4. **Quarterly**: Review and rotate credentials

### Upgrade Procedures
```bash
# Upgrade YugabyteDB version
helm repo update yugabytedb

# Upgrade staging first (test)
helm upgrade codet-staging-yb yugabytedb/yugabyte \
  --namespace codet-staging-yb \
  -f manifests/values/multi-cluster/overrides-codet-staging-yb.yaml \
  --version NEW_VERSION

# Then production (after validation)
helm upgrade codet-prod-yb yugabytedb/yugabyte \
  --namespace codet-prod-yb \
  -f manifests/values/multi-cluster/overrides-codet-prod-yb.yaml \
  --version NEW_VERSION
```

## Cost Optimization

### Resource Monitoring
```bash
# Check resource usage
kubectl top nodes
kubectl top pods --all-namespaces

# Review persistent volume usage
kubectl get pv -o custom-columns=NAME:.metadata.name,CAPACITY:.spec.capacity.storage,STATUS:.status.phase
```

### Optimization Recommendations
1. **Development**: Use preemptible nodes during off-hours
2. **Staging**: Scale down during weekends
3. **Production**: Enable cluster autoscaler for demand-based scaling
4. **Storage**: Use regional persistent disks for production
5. **Networking**: Optimize data transfer with regional placement

## Support and Documentation

### Official Resources
- [YugabyteDB Documentation](https://docs.yugabyte.com/)
- [Kubernetes Multi-Cluster Guide](https://docs.yugabyte.com/preview/deploy/kubernetes/multi-cluster/)
- [GKE Documentation](https://cloud.google.com/kubernetes-engine/docs)

### Internal Resources
- Configuration files: `manifests/clusters/`
- Helm overrides: `manifests/values/multi-cluster/`
- Deployment scripts: `scripts/`
- Monitoring configs: `manifests/monitoring/`

For issues or questions, refer to the troubleshooting section or contact the platform team. 