# YugabyteDB Multi-Environment Deployment on GKE

This repository contains all the necessary configuration files and scripts to deploy three separate YugabyteDB instances (dev, staging, prod) on a single Google Kubernetes Engine (GKE) cluster using the YugabyteDB Operator.

## Architecture Overview

- **Private GKE Cluster**: Database nodes secured within a private VPC
- **YugabyteDB Operator**: Automates deployment and management of database clusters
- **Kubernetes Namespaces**: Logical separation for dev, staging, and prod environments
- **Database RBAC**: Enforces security at the database level

## Prerequisites

### Existing Infrastructure
- Private VPC: `yugabyte-secure-vpc`
- Subnetwork: `yugabyte-subnet-us-central1` (us-central1 region)
- IP Range: `10.0.1.0/24`

### Required GKE Cluster Configuration
1. **Private GKE Cluster** with nodes in the private VPC
2. **Private Google Access** enabled on the subnet
3. **Cloud NAT** configured for outbound connectivity
4. **Cluster Autoscaler** enabled for automatic scaling

## Quick Start

### 1. Set up the YugabyteDB Operator
```bash
./scripts/install-operator.sh
```

### 2. Create namespaces and deploy YugabyteDB instances
```bash
./scripts/deploy-all-environments.sh
```

### 3. Configure database security (RBAC)
```bash
./scripts/setup-database-rbac.sh
```

## File Structure

```
├── manifests/
│   ├── operator/
│   │   └── namespace.yaml
│   ├── namespaces/
│   │   └── environments.yaml
│   └── clusters/
│       ├── codet-dev-yb-cluster.yaml
│       ├── codet-staging-yb-cluster.yaml
│       └── codet-prod-yb-cluster.yaml
├── scripts/
│   ├── install-operator.sh
│   ├── deploy-all-environments.sh
│   ├── setup-database-rbac.sh
│   └── scale-cluster.sh
└── sql/
    ├── rbac-setup.sql
    └── example-procedures.sql
```

## Scaling

### Database Scaling (Horizontal)
To scale a specific environment:
```bash
./scripts/scale-cluster.sh <environment> <new-replica-count>
# Example: ./scripts/scale-cluster.sh staging 5
```

### Infrastructure Scaling
The GKE Cluster Autoscaler will automatically provision new nodes when needed.

## Security

This deployment enforces the "no db.execute()" rule through:
- Role-based access control at the database level
- Application roles with only stored procedure execution permissions
- No direct table access for application connections

## Monitoring and Management

Each YugabyteDB instance includes:
- Built-in web UI for monitoring
- Prometheus metrics endpoints
- Kubernetes-native health checks

## Support

For issues or questions, refer to the [YugabyteDB documentation](https://docs.yugabyte.com/) or the [Kubernetes Operator guide](https://docs.yugabyte.com/latest/deploy/kubernetes/single-zone/oss/yugabyte-operator/). 