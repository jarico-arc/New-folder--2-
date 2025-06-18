# YugabyteDB Multi-Environment Deployment on GKE

This repository contains all the necessary configuration files and scripts to deploy three separate YugabyteDB instances (dev, staging, prod) on a single Google Kubernetes Engine (GKE) cluster using the YugabyteDB Operator.

## Architecture Overview

- **Private GKE Cluster**: Database nodes secured within a private VPC
- **YugabyteDB Operator**: Automates deployment and management of database clusters
- **Kubernetes Namespaces**: Logical separation for dev, staging, and prod environments
- **Database RBAC**: Enforces security at the database level

## Prerequisites

### Existing Infrastructure
- Private VPC: `yugabyte-tf-vpc`
- Subnetwork: `yugabyte-subnet-us-central1` (us-central1 region)
- IP Range: `10.0.1.0/24`

### Required GKE Cluster Configuration
1. **Private GKE Cluster** with nodes in the private VPC
2. **Private Google Access** enabled on the subnet
3. **Cloud NAT** configured for outbound connectivity
4. **Cluster Autoscaler** enabled for automatic scaling

## Deployment Options

### Option 1: Complete Stack Deployment (Recommended)
Deploy everything in one command - includes infrastructure, operator, environments, and security:

```bash
# Complete automated deployment
./scripts/deploy-complete-stack.sh
```

### Option 2: Step-by-Step Deployment
For more control over the deployment process:

```bash
# 1. Set up the YugabyteDB Operator
./scripts/install-operator.sh

# 2. Create namespaces and deploy YugabyteDB instances
./scripts/deploy-all-environments.sh

# 3. Configure database security (RBAC)
./scripts/setup-database-rbac.sh
```

### Option 3: Infrastructure + Database Deployment
If you need to deploy infrastructure first:

```bash
# Deploy infrastructure and complete stack
cd terraform && terraform init && terraform apply -auto-approve && cd ..
./scripts/deploy-complete-stack.sh --skip-terraform
```

## GCP Cloud Shell Deployment

This project is optimized for deployment using GCP Cloud Shell with VPC-native connectivity:

1. **Open Cloud Shell** in the Google Cloud Console
2. **Clone your repository**:
   ```bash
   git clone <your-repo-url>
   cd <your-repo-name>
   ```
3. **Connect to your GKE cluster**:
   ```bash
   gcloud container clusters get-credentials <cluster-name> --zone <zone> --project <project-id>
   ```
4. **Run deployment**:
   ```bash
   ./scripts/deploy-complete-stack.sh
   ```

All required tools (`kubectl`, `helm`, `gcloud`, `terraform`) are pre-installed in Cloud Shell.

### VPC Connectivity
Applications will connect through the private VPC network using internal service DNS names:
- `codet-dev-yb-yb-tserver-service.codet-dev-yb.svc.cluster.local:5433`
- `codet-staging-yb-yb-tserver-service.codet-staging-yb.svc.cluster.local:5433`  
- `codet-prod-yb-yb-tserver-service.codet-prod-yb.svc.cluster.local:5433`

## File Structure

```
├── manifests/
│   ├── operator/
│   │   └── namespace.yaml
│   ├── namespaces/
│   │   └── environments.yaml
│   ├── clusters/
│   │   ├── codet-dev-yb-cluster.yaml
│   │   ├── codet-staging-yb-cluster.yaml
│   │   └── codet-prod-yb-cluster.yaml
│   ├── monitoring/
│   │   ├── alert-rules.yaml
│   │   └── prometheus-stack.yaml
│   └── policies/
│       ├── network-policies.yaml
│       └── pod-disruption-budgets.yaml
├── scripts/
│   ├── deploy-complete-stack.sh
│   ├── install-operator.sh
│   ├── deploy-all-environments.sh
│   ├── setup-database-rbac.sh
│   ├── scale-cluster.sh
│   └── generate-secrets.sh
├── sql/
│   ├── rbac-setup.sql
│   └── example-procedures.sql
└── terraform/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
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
- Grafana dashboards (deployed with monitoring stack)

Access monitoring:
```bash
# Access Grafana
kubectl port-forward -n monitoring svc/grafana 3000:3000
# Open: http://localhost:3000

# Access YugabyteDB web UI
kubectl port-forward -n codet-dev-yb svc/codet-dev-yb-yb-master-ui 7000:7000
# Open: http://localhost:7000
```

## CI/CD with Bitbucket Pipelines

The included `bitbucket-pipelines.yml` provides:
- **Automatic validation** on pull requests
- **Manual deployment gates** for staging/production
- **Infrastructure deployment** pipelines
- **Testing with Kind clusters**

## Support

For issues or questions, refer to the [YugabyteDB documentation](https://docs.yugabyte.com/) or the [Kubernetes Operator guide](https://docs.yugabyte.com/latest/deploy/kubernetes/single-zone/oss/yugabyte-operator/). 