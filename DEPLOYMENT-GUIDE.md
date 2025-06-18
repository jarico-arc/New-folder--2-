# YugabyteDB Multi-Environment Deployment Guide

This guide will walk you through deploying three separate YugabyteDB instances (dev, staging, prod) on your GKE cluster using GCP Cloud Shell and the YugabyteDB Operator.

## Prerequisites Verification

According to your existing infrastructure, you have:
- ✅ Private VPC: `yugabyte-tf-vpc`
- ✅ Subnetwork: `yugabyte-subnet` (us-central1 region)
- ✅ IP Range: `10.0.1.0/24`

### GCP Cloud Shell Setup
Open Google Cloud Shell in your browser - all required tools are pre-installed:
- `kubectl` - Kubernetes command-line tool
- `helm` - Kubernetes package manager
- `psql` - PostgreSQL client (for database operations)
- `gcloud` - Google Cloud CLI
- `terraform` - Infrastructure as code

## Step 1: Connect to Your GKE Cluster

```bash
# Connect to your GKE cluster
gcloud container clusters get-credentials <your-cluster-name> --zone <your-zone> --project <your-project-id>

# Verify cluster connection
kubectl cluster-info

# Verify nodes are private (should show private IPs)
kubectl get nodes -o wide
```

## Step 2: Clone and Prepare Repository

```bash
# Clone your repository
git clone <your-repo-url>
cd <your-repo-name>

# Make scripts executable
chmod +x scripts/*.sh
```

## Deployment Options

### Option 1: Complete Automated Deployment (Recommended)

Deploy everything with one command:

```bash
./scripts/deploy-complete-stack.sh
```

This will:
- Deploy infrastructure (if not using --skip-terraform)
- Install YugabyteDB operator
- Generate secure credentials
- Deploy all three environments
- Set up monitoring stack
- Apply security policies
- Configure database RBAC

**Expected Timeline:** 15-20 minutes for complete deployment

### Option 2: Step-by-Step Deployment

For more control over the process:

```bash
# Step 1: Install YugabyteDB Operator
./scripts/install-operator.sh

# Step 2: Deploy All Environments
./scripts/deploy-all-environments.sh

# Step 3: Configure Database Security (RBAC)
./scripts/setup-database-rbac.sh
```

## Step 3: Monitor Deployment Progress

```bash
# Watch all pods across environments
kubectl get pods --all-namespaces | grep yb

# Check specific environment
kubectl get pods -n codet-dev-yb -w

# Check cluster status
kubectl get ybcluster -A

# Check YugabyteDB operator status
kubectl get pods -n yb-operator
```

## Step 4: Verify Deployment

### Check Cluster Health
```bash
# Verify all clusters are running
kubectl get ybcluster -A

# Check pod status
kubectl get pods -A | grep yb | grep Running
```

### Test Database Connectivity
```bash
# Port forward to development environment
# For VPC connections (recommended for production apps)
# Deploy a test pod in the cluster:
kubectl run postgres-client --rm -i --tty --image postgres:13 -- bash
# Then connect directly via VPC:
psql -h codet-dev-yb-yb-tserver-service.codet-dev-yb.svc.cluster.local -p 5433 -U yugabyte -d yugabyte -c "SELECT version();"

# For external testing (development only)
kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-tserver-service 5433:5433 &
# Test connection (in another terminal)
psql -h localhost -p 5433 -U yugabyte -d yugabyte -c "SELECT version();"
```

## Step 5: Access Database UIs

Each environment has a web-based admin interface:

```bash
# Development UI
kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-master-ui 7000:7000 &
# Open: http://localhost:7000

# Use Cloud Shell Web Preview for easy access
# Click "Web Preview" button in Cloud Shell, then "Preview on port 7000"
```

For staging and production:
```bash
# Staging UI
kubectl port-forward -n codet-staging-yb svc/codet-staging-yb-yb-master-ui 7001:7000 &

# Production UI  
kubectl port-forward -n codet-prod-yb svc/codet-prod-yb-yb-master-ui 7002:7000 &
```

## Step 6: Monitoring (DISABLED FOR COST OPTIMIZATION)

⚠️ **MONITORING DISABLED**: Grafana and Prometheus are not deployed in this cost-optimized configuration.

**Alternative monitoring options:**
```bash
# Use YugabyteDB admin UI for basic monitoring
kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-master-ui 7000:7000 &

# Use kubectl for resource monitoring
kubectl top pods -A | grep yb
kubectl get ybcluster -A
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

### VPC Database Connection Endpoints

**For applications running inside the GKE cluster:**

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

**For applications running on GCE instances in the same VPC:**

```bash
# Get the internal load balancer IP for each environment
kubectl get svc codet-dev-yb-yb-tserver-service -n codet-dev-yb
kubectl get svc codet-staging-yb-yb-tserver-service -n codet-staging-yb  
kubectl get svc codet-prod-yb-yb-tserver-service -n codet-prod-yb

# Then connect using the internal IP
psql -h <internal-lb-ip> -p 5433 -U <username> -d <database>
```

### Credentials

After deployment, check the `credentials/` directory for:
- `codet-dev-credentials.txt`
- `codet-staging-credentials.txt`
- `codet-prod-credentials.txt`

## Resource Configuration Summary (COST OPTIMIZED)

| Environment | Master Nodes | TServer Nodes | Master Storage | TServer Storage | CPU/Node | Memory/Node |
|-------------|--------------|---------------|----------------|-----------------|----------|-------------|
| Development | 1            | 1             | 10Gi           | 20Gi            | 0.5-1 CPU | 1-2Gi      |
| Staging     | 1            | 1             | 10Gi           | 20Gi            | 0.5-1 CPU | 1-2Gi      |
| Production  | 1            | 1             | 10Gi           | 20Gi            | 0.5-1 CPU | 1-2Gi      |

**Note**: ALL environments use minimal resources and single replica (replicationFactor: 1) for cost optimization. TLS, authentication, monitoring, and backups are DISABLED to minimize costs.

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
   ```bash
   kubectl describe pod <pod-name> -n <namespace>
   kubectl get nodes -o wide
   ```

2. **Connection refused**: Verify port-forward and service endpoints
   ```bash
   kubectl get svc -A | grep yb
   kubectl get endpoints -A | grep yb
   ```

3. **Permission denied**: Ensure using correct application credentials
   ```bash
   # Check if credentials file exists
   ls -la credentials/
   ```

4. **Slow performance**: Check CPU/memory limits and consider scaling
   ```bash
   kubectl top pods -A | grep yb
   kubectl describe node <node-name>
   ```

## Next Steps

1. **Configure CI/CD**: Use the included `bitbucket-pipelines.yml` for automated deployments
2. **Set up alerts**: Configure monitoring alerts for production environments
3. **Backup strategy**: Implement regular backup schedules
4. **Performance tuning**: Adjust resource limits based on workload requirements

## Clean Up

To remove all resources:

```bash
# Delete all YugabyteDB clusters
kubectl delete ybcluster --all --all-namespaces

# Delete namespaces
kubectl delete ns codet-dev-yb codet-staging-yb codet-prod-yb

# Delete operator
helm uninstall yugabyte-operator -n yb-operator
kubectl delete ns yb-operator
``` 