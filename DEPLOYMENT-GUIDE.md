# YugabyteDB Multi-Environment Deployment Guide

This guide will walk you through deploying three separate YugabyteDB instances (dev, staging, prod) on your GKE cluster within the existing private VPC infrastructure.

## Prerequisites Verification

According to your existing infrastructure, you have:
- ✅ Private VPC: `yugabyte-secure-vpc`
- ✅ Subnetwork: `yugabyte-subnet-us-central1` (us-central1 region)
- ✅ IP Range: `10.0.1.0/24`

### Required Tools
Ensure you have these tools installed:
- `kubectl` - Kubernetes command-line tool
- `helm` - Kubernetes package manager
- `psql` - PostgreSQL client (for database operations)
- `gcloud` - Google Cloud CLI

## Step 1: Verify GKE Cluster Access

```bash
# Check cluster connection
kubectl cluster-info

# Verify nodes are private (should show private IPs)
kubectl get nodes -o wide
```

## Step 2: Install YugabyteDB Operator

```bash
# Windows PowerShell
./scripts/install-operator.sh

# Linux/macOS
chmod +x scripts/*.sh
./scripts/install-operator.sh
```

**Expected Output:**
- Operator namespace created
- Helm repository added
- YugabyteDB operator deployed
- Pods running in `yb-operator` namespace

## Step 3: Deploy All Environments

```bash
./scripts/deploy-all-environments.sh
```

**This will:**
- Create namespaces: `codet-dev-yb`, `codet-staging-yb`, `codet-prod-yb`
- Deploy YugabyteDB clusters in each namespace
- Wait for clusters to be ready

**Expected Timeline:** 10-15 minutes for all clusters to be fully operational

## Step 4: Monitor Deployment Progress

```bash
# Watch all pods across environments
kubectl get pods --all-namespaces | grep yb

# Check specific environment
kubectl get pods -n codet-dev-yb -w

# Check cluster status
kubectl get ybcluster -A
```

## Step 5: Configure Database Security (RBAC)

```bash
./scripts/setup-database-rbac.sh
```

**This will:**
- Create admin and application roles for each environment
- Set up example tables and stored procedures
- Configure strict permissions (no direct table access)
- Generate credential files in `credentials/` directory

## Step 6: Verify Security Implementation

Connect to each environment and test the security:

```bash
# Port forward to development environment
kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-tserver-service 5433:5433

# In another terminal, test with application credentials
psql -h localhost -p 5433 -U codet_dev_app -d codet_dev
```

**Security Tests:**
```sql
-- This should WORK (function call)
SELECT app_schema.create_user('testuser', 'test@example.com');

-- This should FAIL (direct table access)
SELECT * FROM app_schema.users;
```

## Step 7: Access Database UIs

Each environment has a web-based admin interface:

```bash
# Development
kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-master-ui 7000:7000
# Open: http://localhost:7000

# Staging
kubectl port-forward -n codet-staging-yb svc/codet-staging-yb-yb-master-ui 7001:7000
# Open: http://localhost:7001

# Production
kubectl port-forward -n codet-prod-yb svc/codet-prod-yb-yb-master-ui 7002:7000
# Open: http://localhost:7002
```

## Scaling Operations

### Scale a Cluster Horizontally

```bash
# Scale staging to 5 nodes
./scripts/scale-cluster.sh staging 5

# Scale production to 7 nodes
./scripts/scale-cluster.sh prod 7
```

### Infrastructure Auto-Scaling

Your GKE cluster should have Cluster Autoscaler enabled. When you scale YugabyteDB:
1. New pods request resources
2. If nodes are full, autoscaler adds new GKE nodes
3. Pods get scheduled on new nodes
4. YugabyteDB automatically rebalances data

## Connection Information

### Database Connection Endpoints

For applications running inside the cluster:

```yaml
# Development
host: codet-dev-yb-yb-tserver-service.codet-dev-yb.svc.cluster.local
port: 5433

# Staging  
host: codet-staging-yb-yb-tserver-service.codet-staging-yb.svc.cluster.local
port: 5433

# Production
host: codet-prod-yb-yb-tserver-service.codet-prod-yb.svc.cluster.local
port: 5433
```

### Credentials

Check the `credentials/` directory for:
- `codet-dev-credentials.txt`
- `codet-staging-credentials.txt`
- `codet-prod-credentials.txt`

## Resource Configuration Summary

| Environment | Master Nodes | TServer Nodes | Storage/Node | CPU/Node | Memory/Node |
|-------------|--------------|---------------|--------------|----------|-------------|
| Development | 3            | 3             | 50Gi         | 2 CPU    | 4Gi         |
| Staging     | 3            | 3             | 100Gi        | 3-4 CPU  | 6-8Gi       |
| Production  | 3            | 5             | 500Gi        | 4-6 CPU  | 8-12Gi      |

## Security Implementation

### Application Role Restrictions

Each environment has a restricted application role that:
- ✅ **CAN** execute pre-defined stored procedures
- ❌ **CANNOT** run direct SQL against tables
- ❌ **CANNOT** create/drop database objects
- ❌ **CANNOT** access other schemas or databases

### Available Functions

All environments provide these secure functions:
- `app_schema.create_user(username, email)` - Create new user
- `app_schema.get_user_by_username(username)` - Retrieve user info
- `app_schema.update_user_email(user_id, email)` - Update email
- `app_schema.deactivate_user(user_id, reason)` - Soft delete user
- `app_schema.search_users(term, offset, limit)` - Search users
- `app_schema.get_user_audit_log(user_id, limit)` - View audit trail
- `app_schema.get_activity_summary(hours)` - Activity reports

## Monitoring and Maintenance

### Health Checks

```bash
# Check cluster health
kubectl get ybcluster -A

# Check pod status
kubectl get pods -A | grep yb

# Check resource usage
kubectl top pods -A | grep yb
```

### Backup Considerations

YugabyteDB provides built-in backup capabilities:
- Point-in-time recovery
- Cross-region replication
- Automated backup scheduling

### Troubleshooting

Common issues and solutions:

1. **Pods stuck in Pending**: Check node resources and autoscaler
2. **Connection refused**: Verify port-forward and service endpoints
3. **Permission denied**: Ensure using correct application credentials
4. **Slow performance**: Check CPU/memory limits and consider scaling

## Next Steps

1. **Configure Application**: Update your application connection strings
2. **Set up Monitoring**: Configure Prometheus/Grafana for metrics
3. **Backup Strategy**: Implement regular backup procedures
4. **CI/CD Integration**: Add database deployments to your pipelines
5. **Security Hardening**: Review and customize RBAC procedures

## Support and Documentation

- [YugabyteDB Documentation](https://docs.yugabyte.com/)
- [Kubernetes Operator Guide](https://docs.yugabyte.com/latest/deploy/kubernetes/)
- [RBAC Configuration](https://docs.yugabyte.com/latest/secure/authorization/)

For issues specific to this deployment, check the generated credential files and ensure all prerequisites are met. 