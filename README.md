# YugabyteDB Multi-Cluster Kubernetes Deployment

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.28+-blue.svg)](https://kubernetes.io/)
[![YugabyteDB](https://img.shields.io/badge/YugabyteDB-2.25.2-green.svg)](https://yugabyte.com/)

Enterprise-grade multi-cluster YugabyteDB deployment on Google Kubernetes Engine (GKE) with private networking, comprehensive security, and professional DevOps practices.

## 🏗️ Architecture Overview

This project deploys **2 YugabyteDB clusters** across multiple GCP regions in a multi-cluster configuration:

- **Codet-Dev-YB**: Development cluster in `us-west1-b`
- **Codet-Prod-YB**: Production cluster in `us-east1-b`

### Key Features

✅ **Multi-Cluster Architecture**: 2 clusters with cross-region capabilities  
✅ **Private VPC Networking**: No public IPs, internal load balancers only  
✅ **Enterprise Security**: TLS encryption, RBAC, Pod Security Standards  
✅ **Automated Backups**: Scheduled backups with encryption  
✅ **Professional CI/CD**: GitHub Actions, security scanning, testing  
✅ **Comprehensive Monitoring**: Prometheus, Grafana, alerting  
✅ **Infrastructure as Code**: Helm charts, Kubernetes manifests  

## 🚀 Quick Start

### Prerequisites

- **GCP Project** with billing enabled
- **Required Tools**: `gcloud`, `kubectl`, `helm`
- **Permissions**: Kubernetes Engine Admin, Compute Network Admin

### 1. Install Dependencies

```bash
# Install all required tools
make install

# Or install manually
curl https://get.helm.sh/helm-v3.13.0-linux-amd64.tar.gz | tar -xz
sudo mv linux-amd64/helm /usr/local/bin/

# Add Helm repositories
helm repo add yugabytedb https://charts.yugabyte.com
helm repo update
```

### 2. Deploy Multi-Cluster Setup

```bash
# Complete deployment (both clusters)
make multi-cluster-deploy

# Or step-by-step deployment
./scripts/create-multi-cluster-yugabytedb.sh vpc        # Create VPC
./scripts/create-multi-cluster-yugabytedb.sh clusters  # Create clusters
./scripts/create-multi-cluster-yugabytedb.sh install   # Install YugabyteDB
```

### 3. Validate Deployment

```bash
# Test connectivity and functionality
make multi-cluster-test

# Check status
make multi-cluster-status

# Show connection information
make multi-cluster-info
```

## 📋 Cluster Specifications

| Environment | Region | Nodes | CPU/RAM | Storage | Security | Backup |
|-------------|--------|-------|---------|---------|----------|---------|
| **Development** | us-west1 | 2 | 2C/4GB | 100GB SSD | Basic | Disabled |
| **Production** | us-east1 | 3 | 4C/8GB | 500GB SSD | Full TLS + Audit | Daily + Encrypted |

## 🌐 Network Architecture

### Private VPC Configuration
- **VPC**: `yugabytedb-private-vpc`
- **Subnets**: 
  - Dev: `10.1.0.0/16` (us-west1)
  - Production: `10.3.0.0/16` (us-east1)

### Security Features
- Private GKE clusters (no external IPs)
- Internal load balancers only
- Network policies for traffic isolation
- Firewall rules for YugabyteDB ports only
- Pod Security Standards enforced

## 🔧 Development Workflow

### Common Operations

```bash
# Switch between environments
make context-dev        # Development
make context-prod       # Production

# Database access
make ysql-dev          # PostgreSQL-compatible interface
make ycql-prod         # Cassandra-compatible interface

# Monitoring
make logs-prod         # View logs
make multi-cluster-status  # Check health
```

### Scaling Operations

```bash
# Scale production cluster  
make scale-prod

# Manual scaling
helm upgrade codet-prod-yb yugabytedb/yugabyte \
  --namespace codet-prod-yb \
  -f manifests/values/multi-cluster/overrides-codet-prod-yb.yaml \
  --set replicas.tserver=5
```

## 🔒 Security Features

### Authentication & Authorization
- **Development**: Open access for development ease
- **Production**: Full RBAC + TLS + audit logging

### Network Security
- Private VPC with no internet access
- Internal load balancers only
- Network policies restricting pod-to-pod communication
- Firewall rules for YugabyteDB ports only

### Secrets Management
```bash
# Update production credentials
kubectl create secret generic codet-prod-yb-credentials \
  --from-literal=yugabyte.password=NEW_SECURE_PASSWORD \
  --from-literal=postgres.password=NEW_SECURE_PASSWORD \
  -n codet-prod-yb \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 📊 Monitoring & Observability

### Prometheus Metrics
All clusters expose metrics for monitoring:
- Master metrics: `:7000/prometheus-metrics`
- TServer metrics: `:9000/prometheus-metrics`

### Log Management
```bash
# View logs by environment
make logs-dev
make logs-prod

# Follow logs in real-time
kubectl logs -f -n codet-prod-yb yb-master-0
```

### Health Checks
```bash
# Comprehensive health check
make multi-cluster-status

# Test specific functionality
./scripts/test-yugabytedb-connectivity.sh connectivity
./scripts/test-yugabytedb-connectivity.sh multi-cluster
```

## 💾 Backup & Recovery

### Automated Backups
- **Production**: Daily at 2 AM UTC, 30-day retention with encryption

### Manual Backup
```bash
# Create snapshot
kubectl exec -n codet-prod-yb yb-master-0 -- \
  yb-admin --master_addresses=yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 \
  create_snapshot ysql.yugabyte

# List snapshots
kubectl exec -n codet-prod-yb yb-master-0 -- \
  yb-admin --master_addresses=yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local:7100 \
  list_snapshots
```

### Backup Locations
- **Production**: `gs://codet-prod-yb-backups`

## 🛠️ Troubleshooting

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
kubectl exec -n codet-dev-yb yb-master-0 -- \
  nslookup yb-master-0.yb-masters.codet-prod-yb.svc.cluster.local

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

## 📂 Project Structure

```
.
├── scripts/
│   ├── create-multi-cluster-yugabytedb.sh    # Main deployment script
│   ├── test-yugabytedb-connectivity.sh       # Connectivity testing
│   └── security-scan.sh                      # Security scanning
├── manifests/
│   ├── clusters/                              # Cluster configurations
│   │   ├── codet-dev-yb-cluster.yaml
│   │   └── codet-prod-yb-cluster.yaml
│   ├── values/
│   │   └── multi-cluster/                     # Helm override files
│   │       └── overrides-codet-prod-yb.yaml
│   ├── monitoring/                            # Monitoring configs
│   ├── backup/                                # Backup strategies
│   └── policies/                              # Security policies
├── cloud-functions/                           # BI consumer function
├── .github/workflows/                         # CI/CD pipelines
├── Makefile                                   # Automation targets
└── README.md                                  # This file
```

## 🔧 Configuration Files

### Cluster Configurations
- `manifests/clusters/`: Kubernetes manifests for each cluster
- `manifests/values/multi-cluster/`: Helm values for YugabyteDB

### Security Policies
- `manifests/policies/pod-security-policies.yaml`: Pod security standards
- `manifests/policies/network-policies-enhanced.yaml`: Network isolation
- `manifests/policies/resource-quotas.yaml`: Resource limits

### Monitoring
- `manifests/monitoring/prometheus-stack.yaml`: Complete monitoring setup
- `manifests/monitoring/alert-rules.yaml`: Custom alerting rules

## 🚀 CI/CD Pipeline

The project includes a comprehensive GitHub Actions pipeline:

- **Linting**: YAML, shell scripts, Python code
- **Security Scanning**: Container images, Kubernetes manifests, secrets
- **Testing**: Unit tests, integration tests, connectivity tests
- **Deployment**: Automated deployment to staging, manual approval for production

## 📈 Performance Optimization

### Resource Allocation
- **Development**: Minimal resources for cost efficiency
- **Production**: High-performance configuration with HA

### Storage Optimization
- Regional SSD persistent disks for production
- Standard SSD for development
- Automatic volume expansion enabled

## 🔐 Compliance & Standards

### Security Compliance
- **CIS Kubernetes Benchmark**: Pod Security Standards
- **NIST Cybersecurity Framework**: Risk management
- **SOC 2 Type II**: Data protection controls

### Best Practices
- Infrastructure as Code (IaC)
- GitOps deployment methodology
- Comprehensive monitoring and alerting
- Automated backup and disaster recovery

## 📚 Documentation

- [Multi-Cluster Deployment Guide](MULTI-CLUSTER-DEPLOYMENT.md): Detailed deployment instructions
- [Security Documentation](SECURITY.md): Security policies and procedures
- [Contributing Guidelines](CONTRIBUTING.md): Development workflow
- [Changelog](CHANGELOG.md): Version history

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`make test`)
4. Run security scan (`make security`)
5. Commit changes (`git commit -m 'Add amazing feature'`)
6. Push to branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- **Documentation**: Check the `docs/` directory for detailed guides
- **Issues**: Create GitHub issues for bugs or feature requests
- **Security**: Report security vulnerabilities via security@company.com

## 🎯 Roadmap

- [ ] Multi-region disaster recovery
- [ ] Automatic failover testing
- [ ] Advanced monitoring dashboards
- [ ] Performance benchmarking suite
- [ ] Cost optimization automation

---

**Built with ❤️ for enterprise-grade YugabyteDB deployments** 