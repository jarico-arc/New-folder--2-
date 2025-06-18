# Project Structure Overview

This repository implements a comprehensive YugabyteDB multi-environment deployment on Google Kubernetes Engine (GKE) using the YugabyteDB Operator.

## 📁 Complete Directory Structure

```
├── README.md                          # Main project documentation
├── DEPLOYMENT-GUIDE.md               # Step-by-step deployment instructions
├── PROJECT-STRUCTURE.md              # This file - project overview
│
├── manifests/                        # Kubernetes manifests
│   ├── operator/
│   │   └── namespace.yaml            # YugabyteDB operator namespace
│   ├── namespaces/
│   │   └── environments.yaml         # Dev, staging, prod namespaces
│   └── clusters/
│       ├── codet-dev-yb-cluster.yaml     # Development environment cluster
│       ├── codet-staging-yb-cluster.yaml # Staging environment cluster
│       └── codet-prod-yb-cluster.yaml    # Production environment cluster
│
├── scripts/                          # Deployment automation scripts
│   ├── install-operator.sh           # Install YugabyteDB operator (Linux/macOS)
│   ├── deploy-all-environments.sh    # Deploy all three environments
  │   ├── scale-cluster.sh              # Scale individual clusters
  │   └── setup-database-rbac.sh       # Configure database security and RBAC
│
├── sql/                              # Database schema and security templates
│   ├── rbac-setup.sql               # RBAC setup template
│   └── example-procedures.sql        # Secure stored procedures examples
│
└── credentials/                      # Generated during deployment
    ├── codet-dev-credentials.txt     # Development environment credentials
    ├── codet-staging-credentials.txt # Staging environment credentials
    └── codet-prod-credentials.txt    # Production environment credentials
```

## 🏗️ Architecture Components

### 1. Infrastructure Layer (GKE + VPC)
- **Private GKE Cluster**: Nodes without public IP addresses
- **Private VPC**: `yugabyte-tf-vpc` with isolated networking
- **Subnetwork**: `yugabyte-subnet` (10.0.1.0/24)
- **Cloud NAT**: Enables outbound internet access
- **Private Google Access**: Access to Google services without public IPs

### 2. Kubernetes Layer
- **YugabyteDB Operator**: Manages database lifecycle in Kubernetes
- **Namespaces**: Logical isolation for each environment
- **Custom Resources**: YBCluster CRDs define database configurations
- **Services**: Internal load balancing and service discovery
- **Persistent Volumes**: Durable storage for database data

### 3. Database Layer (COST OPTIMIZED)
- **Master Nodes**: Cluster metadata and coordination (1 replica each)
- **TServer Nodes**: Data storage and query processing (1 replica per env)
- **Replication Factor**: 1x for cost savings (single point of failure)
- **TLS Encryption**: DISABLED for cost optimization
- **Authentication**: DISABLED for cost optimization

### 4. Security Layer
- **Network Isolation**: Private VPC with no public endpoints
- **Database RBAC**: Granular permissions at database level
- **Application Roles**: Restricted database access via stored procedures
- **Audit Logging**: All database operations tracked
- **TLS/SSL**: Encrypted connections and inter-node communication

## 🚀 Deployment Environments

| Environment | Purpose | Resources | Scaling Strategy |
|-------------|---------|-----------|------------------|
| **Development** | Developer testing, feature development | Minimal resources (0.5-1 CPU, 1-2Gi RAM per node) | Manual scaling for testing |
| **Staging** | Pre-production testing, integration tests | Minimal resources (0.5-1 CPU, 1-2Gi RAM per node) | Manual scaling for cost |
| **Production** | Live production workloads | Minimal resources (0.5-1 CPU, 1-2Gi RAM per node) | Manual scaling for cost |

## 🔐 Security Implementation

### Database-Level Security (COST OPTIMIZED)
⚠️ **NOTE**: Authentication and TLS are DISABLED for cost optimization

1. **Basic Network Security**: VPC isolation and network policies
2. **Application Roles**: Available but authentication disabled
3. **No Direct Table Access**: Enforced by application design (not DB auth)
4. **Stored Procedures**: Available for application use
5. **Audit Trail**: DISABLED for cost optimization

### Network Security
1. **Private Networking**: No public IP addresses on database nodes
2. **VPC Isolation**: Dedicated network segment for database traffic
3. **Service Mesh Ready**: Compatible with Istio for additional security
4. **TLS Everywhere**: Encrypted communication between all components

## 📋 Available Operations

### Deployment Operations
```bash
# Deploy complete stack
./scripts/deploy-complete-stack.sh

# Install operator only
./scripts/install-operator.sh

# Deploy all environments
./scripts/deploy-all-environments.sh

# Setup database security
./scripts/setup-database-rbac.sh dev
./scripts/setup-database-rbac.sh staging
./scripts/setup-database-rbac.sh prod
```

### Management Operations
```bash
# Check deployment status
kubectl get ybcluster --all-namespaces

# Scale a cluster
./scripts/scale-cluster.sh dev 3
./scripts/scale-cluster.sh staging 5

# Monitor resources
kubectl top pods -A | grep yb
```

### Database Operations
```sql
-- Create user (ALLOWED)
SELECT app_schema.create_user('john_doe', 'john@example.com');

-- Direct table access (DENIED)
SELECT * FROM app_schema.users;  -- Permission denied

-- Audit trail
SELECT * FROM app_schema.get_activity_summary(24);
```

## 🔧 Customization Points

### Resource Adjustments
- Modify CPU/memory limits in cluster manifests
- Adjust storage sizes for different workload requirements
- Configure backup retention policies

### Security Enhancements
- Add additional stored procedures for specific business logic
- Implement custom audit logging requirements
- Configure integration with external identity providers

### Monitoring Integration
- Prometheus metrics collection
- Grafana dashboard configuration
- Alert manager rules for critical events

## 📊 Monitoring and Observability

### Built-in Dashboards
- YugabyteDB Master UI: Cluster health and performance metrics
- Kubernetes Dashboard: Resource utilization and pod status
- Prometheus Metrics: Time-series data for alerting

### Health Checks
- Kubernetes liveness and readiness probes
- YugabyteDB internal health monitoring
- Application-level connection testing

## 🔄 Scaling and Performance

### Horizontal Scaling
- Add/remove TServer nodes dynamically
- Automatic data rebalancing
- Zero-downtime scaling operations

### Vertical Scaling
- Increase CPU/memory resources per node
- Storage expansion without downtime
- Performance tuning for specific workloads

## 🆘 Troubleshooting Resources

### Common Issues
1. **Pod Scheduling**: Check node resources and taints
2. **Network Connectivity**: Verify VPC and firewall rules
3. **Storage Issues**: Monitor PVC status and storage classes
4. **Performance**: Check resource limits and data distribution

### Debug Commands
```bash
# Check pod logs
kubectl logs -n codet-prod-yb <pod-name>

# Describe resources
kubectl describe ybcluster codet-prod-yb -n codet-prod-yb

# Check events
kubectl get events -n codet-prod-yb --sort-by='.lastTimestamp'
```

## 📚 Additional Resources

- [YugabyteDB Documentation](https://docs.yugabyte.com/)
- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/)
- [GKE Private Clusters Guide](https://cloud.google.com/kubernetes-engine/docs/concepts/private-cluster-concept)
- [Database Security Best Practices](https://docs.yugabyte.com/latest/secure/)

This architecture provides a production-ready, secure, and scalable database infrastructure that enforces the "no direct database access" security requirement while maintaining operational flexibility and observability. 