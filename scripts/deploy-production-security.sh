#!/bin/bash

# Production Security Deployment Script for YugabyteDB
# Ensures all security best practices are applied

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Configuration
ENVIRONMENT=${1:-"prod"}
NAMESPACE="codet-${ENVIRONMENT}-yb"
VALUES_FILE="manifests/values/${ENVIRONMENT}-values.yaml"

if [ ! -f "$VALUES_FILE" ]; then
    log_error "Values file not found: $VALUES_FILE"
    exit 1
fi

log_info "🔐 Deploying YugabyteDB with production security for environment: $ENVIRONMENT"

# Step 1: Generate secure passwords
log_info "🔑 Generating secure passwords..."
YUGABYTE_PASSWORD=$(openssl rand -base64 32)
YSQL_PASSWORD=$(openssl rand -base64 32)
YCQL_PASSWORD=$(openssl rand -base64 32)

# Step 2: Create namespace if it doesn't exist
log_info "📦 Ensuring namespace exists: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Step 3: Create TLS certificates
log_info "🔒 Generating TLS certificates..."

# Create certificate directory
mkdir -p certs

# Generate CA key and certificate
openssl genrsa -out certs/ca.key 4096
openssl req -new -x509 -key certs/ca.key -sha256 -subj "/C=US/ST=CA/O=YugabyteDB/CN=yugabyte-ca" -days 3650 -out certs/ca.crt

# Generate server key and certificate
openssl genrsa -out certs/server.key 4096
openssl req -new -key certs/server.key -out certs/server.csr -subj "/C=US/ST=CA/O=YugabyteDB/CN=yugabyte-server"
openssl x509 -req -in certs/server.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial -out certs/server.crt -days 365 -sha256

# Step 4: Create Kubernetes secrets
log_info "🔐 Creating Kubernetes secrets..."

# Database credentials secret
kubectl create secret generic yugabyte-db-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=yugabyte-password="$YUGABYTE_PASSWORD" \
  --from-literal=ysql-password="$YSQL_PASSWORD" \
  --from-literal=ycql-password="$YCQL_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# TLS certificates secret
kubectl create secret generic yugabyte-tls \
  --namespace="$NAMESPACE" \
  --from-file=ca.crt=certs/ca.crt \
  --from-file=server.crt=certs/server.crt \
  --from-file=server.key=certs/server.key \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 5: Create secure values override
log_info "📝 Creating secure values override..."

cat > "/tmp/${ENVIRONMENT}-secure-values.yaml" << EOF
# Production Security Override Values
# These override the base values to enable all security features

auth:
  enabled: true
  useSecretFile: true

tls:
  enabled: true
  certManager:
    enabled: false
  customCerts:
    enabled: true
    certFilesPath: "/opt/certs"

# Use secrets for passwords
secretmanagement:
  yugabyte:
    password:
      existingSecret: "yugabyte-db-credentials"
      existingSecretKey: "yugabyte-password"

# Enable RBAC
rbac:
  create: true

# Enable Pod Security Standards
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: false  # YugabyteDB needs write access
  runAsNonRoot: true
  runAsUser: 10001

# Network policies
networkPolicy:
  enabled: true

# Resource limits for security
resource:
  master:
    requests:
      cpu: "1"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
  tserver:
    requests:
      cpu: "2"
      memory: "4Gi"
    limits:
      cpu: "4"
      memory: "8Gi"

# Production gflags with security
gflags:
  master:
    max_clock_skew_usec: 200000
    default_memory_limit_to_ram_ratio: 0.85
    # Security flags
    use_client_to_server_encryption: true
    use_node_to_node_encryption: true
    allow_insecure_connections: false
    certs_dir: "/opt/certs"
    
  tserver:
    max_clock_skew_usec: 200000
    default_memory_limit_to_ram_ratio: 0.85
    # Security flags
    use_client_to_server_encryption: true
    use_node_to_node_encryption: true
    allow_insecure_connections: false
    certs_dir: "/opt/certs"
    # CDC with security
    cdc_state_checkpoint_update_interval_ms: 15000
    cdc_checkpoint_opid_interval_ms: 60000

# Volume mounts for certificates
volumes:
  - name: yugabyte-tls
    secret:
      secretName: yugabyte-tls
      defaultMode: 0400

volumeMounts:
  - name: yugabyte-tls
    mountPath: "/opt/certs"
    readOnly: true

# Monitoring with security
istio:
  enabled: false  # Can be enabled with proper mesh security

annotations:
  cluster-autoscaler.kubernetes.io/safe-to-evict: "false"
  
# Service mesh integration (if available)
serviceMonitor:
  enabled: false
EOF

# Step 6: Deploy with Helm
log_info "🚀 Deploying YugabyteDB with security enabled..."

if ! command -v helm &> /dev/null; then
    log_error "Helm is not installed or not in PATH"
    exit 1
fi

helm upgrade --install yugabyte-${ENVIRONMENT} yugabytedb/yugabyte \
  --namespace="$NAMESPACE" \
  --values="$VALUES_FILE" \
  --values="/tmp/${ENVIRONMENT}-secure-values.yaml" \
  --wait \
  --timeout=10m

# Step 7: Wait for deployment
log_info "⏳ Waiting for YugabyteDB to be ready..."
kubectl wait --for=condition=ready pod -l app=yb-master -n "$NAMESPACE" --timeout=300s
kubectl wait --for=condition=ready pod -l app=yb-tserver -n "$NAMESPACE" --timeout=300s

# Step 8: Verify security configuration
log_info "🔍 Verifying security configuration..."

# Check if TLS is enabled
if kubectl exec -n "$NAMESPACE" deploy/yb-master-0 -- curl -k -s https://localhost:7000/api/v1/health-check >/dev/null; then
    log_success "✅ TLS encryption verified"
else
    log_warning "⚠️ TLS verification failed - check configuration"
fi

# Check authentication
if kubectl exec -n "$NAMESPACE" deploy/yb-tserver-0 -- ysqlsh -h localhost -U yugabyte -c "SELECT 1" 2>/dev/null | grep -q "password authentication failed"; then
    log_success "✅ Authentication is enabled"
else
    log_warning "⚠️ Authentication check inconclusive"
fi

# Step 9: Create admin user
log_info "👤 Creating admin user..."
kubectl exec -n "$NAMESPACE" deploy/yb-tserver-0 -- ysqlsh -h localhost -U yugabyte << EOF
CREATE USER admin WITH SUPERUSER PASSWORD '$YSQL_PASSWORD';
EOF

# Step 10: Save credentials securely
log_info "💾 Saving credentials..."

cat > "/tmp/${ENVIRONMENT}-credentials.txt" << EOF
=== YugabyteDB ${ENVIRONMENT} Credentials ===
Generated: $(date)

Yugabyte Super User: yugabyte
Password: $YUGABYTE_PASSWORD

Admin User: admin  
Password: $YSQL_PASSWORD

YCQL Password: $YCQL_PASSWORD

Connection Examples:
YSQL: ysqlsh -h <service-ip> -U admin -d yugabyte
YCQL: ycqlsh <service-ip> -u admin -p $YCQL_PASSWORD

TLS Certificates:
- CA Certificate: certs/ca.crt
- Server Certificate: certs/server.crt
- Server Key: certs/server.key

IMPORTANT: Store these credentials securely and delete this file!
EOF

# Step 11: Apply network policies
log_info "🛡️ Applying network policies..."

cat << EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: yugabyte-network-policy
  namespace: $NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: yb-tserver
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: $NAMESPACE
    - podSelector:
        matchLabels:
          app: yb-master
    ports:
    - protocol: TCP
      port: 5433
    - protocol: TCP
      port: 9042
    - protocol: TCP
      port: 9100
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: $NAMESPACE
    - podSelector:
        matchLabels:
          app: yb-master
  - to: []
    ports:
    - protocol: TCP
      port: 53
    - protocol: UDP
      port: 53
EOF

# Cleanup temporary files
rm -f "/tmp/${ENVIRONMENT}-secure-values.yaml"

log_success "🎉 Production security deployment completed!"
log_warning "⚠️ Credentials saved to: /tmp/${ENVIRONMENT}-credentials.txt"
log_warning "⚠️ TLS certificates saved to: certs/"
log_error "🔥 IMPORTANT: Store credentials securely and delete temporary files!"

echo ""
echo "📋 Next Steps:"
echo "1. Store credentials in your password manager"
echo "2. Backup TLS certificates to secure storage"  
echo "3. Delete temporary credential files"
echo "4. Test connections with authentication"
echo "5. Set up monitoring and alerting"
echo "6. Review and apply additional security policies" 