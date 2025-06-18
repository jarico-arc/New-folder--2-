# YugabyteDB Deployment Modernization

This repository has been updated to use the modern YugabyteDB deployment approach using Helm charts instead of the deprecated operator-based method.

## Changes Made

### 1. Migration from Operator to Helm
- **Before**: Used `YBCluster` CRDs with YugabyteDB Operator
- **After**: Direct Helm chart deployment using `yugabytedb/yugabyte`

### 2. New File Structure
```
manifests/
├── values/                    # NEW: Helm values files
│   ├── dev-values.yaml       # Development environment configuration
│   ├── staging-values.yaml   # Staging environment configuration
│   └── prod-values.yaml      # Production environment configuration
├── clusters/                 # DEPRECATED: YBCluster CRDs (kept for reference)
├── namespaces/              # UNCHANGED: Namespace definitions
└── policies/                # UNCHANGED: Security policies
```

### 3. Updated Scripts
- `scripts/install-operator.sh` → Now sets up Helm repository instead of operator
- `scripts/deploy-all-environments.sh` → Uses Helm install instead of kubectl apply
- `scripts/deploy-complete-stack.sh` → Updated to use new Helm workflow

## Deployment Methods

### Option 1: Complete Stack (Recommended)
```bash
./scripts/deploy-complete-stack.sh
```

### Option 2: Step-by-Step
```bash
# 1. Setup Helm repository
./scripts/install-operator.sh

# 2. Deploy all environments
./scripts/deploy-all-environments.sh

# 3. Setup RBAC
./scripts/setup-database-rbac.sh
```

### Option 3: Manual Helm Commands
```bash
# Development environment
helm install codet-dev-yb yugabytedb/yugabyte \
    --namespace codet-dev-yb \
    --create-namespace \
    --values manifests/values/dev-values.yaml

# Staging environment
helm install codet-staging-yb yugabytedb/yugabyte \
    --namespace codet-staging-yb \
    --create-namespace \
    --values manifests/values/staging-values.yaml

# Production environment
helm install codet-prod-yb yugabytedb/yugabyte \
    --namespace codet-prod-yb \
    --create-namespace \
    --values manifests/values/prod-values.yaml
```

## Configuration

All environment configurations are now stored in Helm values files:

### Development (`manifests/values/dev-values.yaml`)
- Single master (replicas: 1)
- Single tserver (replicas: 1)
- Minimal resources (0.5 CPU, 1Gi RAM)
- 10Gi master storage, 20Gi tserver storage

### Staging (`manifests/values/staging-values.yaml`)
- Same as development for cost optimization
- Separate namespace for isolation

### Production (`manifests/values/prod-values.yaml`)
- Same minimal configuration for cost optimization
- Can be scaled up by modifying values file

## Management Commands

### Check Status
```bash
helm status codet-dev-yb -n codet-dev-yb
kubectl get pods -n codet-dev-yb
```

### Upgrade Deployment
```bash
helm upgrade codet-dev-yb yugabytedb/yugabyte \
    -n codet-dev-yb \
    --values manifests/values/dev-values.yaml
```

### Scale Resources
Edit the values file and run upgrade:
```yaml
# In manifests/values/dev-values.yaml
replicas:
  master: 3
  tserver: 3
```

### Uninstall
```bash
helm uninstall codet-dev-yb -n codet-dev-yb
kubectl delete namespace codet-dev-yb
```

## Benefits of New Approach

1. **Modern & Supported**: Uses official YugabyteDB Helm charts
2. **Better Lifecycle Management**: Helm provides rollback, upgrade, and status tracking
3. **Simplified Configuration**: Single values file per environment
4. **Community Standard**: Aligns with Kubernetes best practices
5. **Future-Proof**: No dependency on deprecated operators

## Backward Compatibility

- The old `manifests/clusters/` directory is preserved for reference
- Namespace and policy configurations remain unchanged
- Same cost optimization features are maintained
- Connection endpoints remain the same

## Migration Steps (if updating existing deployment)

1. **Backup existing data** (if any)
2. **Uninstall old operator-based deployment**:
   ```bash
   kubectl delete ybcluster --all --all-namespaces
   helm uninstall yugabyte-operator -n yb-operator
   ```
3. **Deploy using new method**:
   ```bash
   ./scripts/deploy-complete-stack.sh
   ```

## Cost Optimization Maintained

All cost optimization features are preserved in the new deployment:
- Single replica configuration
- Minimal resource allocation
- Disabled authentication, TLS, and monitoring
- Standard storage class
- Node affinity for cost-effective instances

Estimated cost remains: **~$130-150/month** for all three environments. 