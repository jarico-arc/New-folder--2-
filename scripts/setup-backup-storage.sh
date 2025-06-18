#!/bin/bash

# YugabyteDB Backup Storage Setup Script
# Creates GCS bucket, IAM service account, and configures backup credentials

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

# Configuration
PROJECT_ID="${1:-}"
ENVIRONMENT="${2:-prod}"
BUCKET_NAME="yugabytedb-backups-${ENVIRONMENT}"
SERVICE_ACCOUNT_NAME="yugabytedb-backup-${ENVIRONMENT}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
NAMESPACE="codet-${ENVIRONMENT}-yb"
SECRET_NAME="gcs-backup-credentials"
BUCKET_REGION="us-central1"

usage() {
    echo "Usage: $0 <PROJECT_ID> [ENVIRONMENT]"
    echo "  PROJECT_ID: GCP project ID"
    echo "  ENVIRONMENT: Environment (dev|staging|prod) [default: prod]"
    echo ""
    echo "Examples:"
    echo "  $0 my-gcp-project-123 prod"
    echo "  $0 my-gcp-project-123 staging"
    exit 1
}

# Validate input parameters
if [ -z "$PROJECT_ID" ]; then
    log_error "PROJECT_ID is required"
    usage
fi

# Check if environment is valid
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    log_error "Environment must be one of: dev, staging, prod"
    usage
fi

# Function to check required tools
check_prerequisites() {
    log_info "🔍 Checking prerequisites..."
    
    local required_tools=("gcloud" "kubectl" "gsutil")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool is not installed or not in PATH"
            exit 1
        fi
    done
    
    # Check gcloud authentication
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        log_error "No active GCP authentication found. Run: gcloud auth login"
        exit 1
    fi
    
    # Check kubectl connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "kubectl cannot connect to cluster"
        exit 1
    fi
    
    # Set GCP project
    gcloud config set project "$PROJECT_ID"
    
    log_success "Prerequisites check passed"
}

# Function to create GCS bucket
create_backup_bucket() {
    log_info "🪣 Creating GCS backup bucket: $BUCKET_NAME"
    
    # Check if bucket already exists
    if gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
        log_warning "Bucket $BUCKET_NAME already exists"
        return 0
    fi
    
    # Create bucket with appropriate settings
    gsutil mb -p "$PROJECT_ID" -c STANDARD -l "$BUCKET_REGION" "gs://$BUCKET_NAME"
    
    # Configure bucket settings for backup security
    log_info "Configuring bucket security settings..."
    
    # Enable versioning for backup protection
    gsutil versioning set on "gs://$BUCKET_NAME"
    
    # Set lifecycle policy to manage old versions and multipart uploads
    cat > bucket-lifecycle.json << EOF
{
  "lifecycle": {
    "rule": [
      {
        "action": {
          "type": "Delete"
        },
        "condition": {
          "age": 30,
          "isLive": false
        }
      },
      {
        "action": {
          "type": "AbortIncompleteMultipartUpload"
        },
        "condition": {
          "age": 1
        }
      }
    ]
  }
}
EOF
    
    gsutil lifecycle set bucket-lifecycle.json "gs://$BUCKET_NAME"
    rm bucket-lifecycle.json
    
    # Set default object ACL for security
    gsutil defacl set private "gs://$BUCKET_NAME"
    
    log_success "GCS bucket created and configured: $BUCKET_NAME"
}

# Function to create service account
create_service_account() {
    log_info "👤 Creating service account: $SERVICE_ACCOUNT_NAME"
    
    # Check if service account already exists
    if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" &> /dev/null; then
        log_warning "Service account $SERVICE_ACCOUNT_EMAIL already exists"
    else
        # Create service account
        gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
            --description="YugabyteDB backup service account for $ENVIRONMENT" \
            --display-name="YugabyteDB Backup ($ENVIRONMENT)"
        
        log_success "Service account created: $SERVICE_ACCOUNT_EMAIL"
    fi
    
    # Grant necessary permissions
    log_info "Configuring IAM permissions..."
    
    # Storage admin for the specific bucket
    gsutil iam ch "serviceAccount:$SERVICE_ACCOUNT_EMAIL:objectAdmin" "gs://$BUCKET_NAME"
    
    # Additional GCP permissions if needed
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$SERVICE_ACCOUNT_EMAIL" \
        --role="roles/storage.objectAdmin" \
        --condition=None
    
    log_success "IAM permissions configured"
}

# Function to create service account key
create_service_account_key() {
    log_info "🔑 Creating service account key..."
    
    local key_file="backup-service-account-key.json"
    
    # Create key
    gcloud iam service-accounts keys create "$key_file" \
        --iam-account="$SERVICE_ACCOUNT_EMAIL"
    
    if [ -f "$key_file" ]; then
        log_success "Service account key created: $key_file"
        log_warning "⚠️  IMPORTANT: Secure this key file and delete it after creating the Kubernetes secret!"
        chmod 600 "$key_file"
        echo "Key file permissions set to 600"
    else
        log_error "Failed to create service account key"
        exit 1
    fi
}

# Function to create Kubernetes secret
create_kubernetes_secret() {
    log_info "🔐 Creating Kubernetes secret in namespace: $NAMESPACE"
    
    # Ensure namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace $NAMESPACE does not exist"
        exit 1
    fi
    
    local key_file="backup-service-account-key.json"
    
    if [ ! -f "$key_file" ]; then
        log_error "Service account key file not found: $key_file"
        exit 1
    fi
    
    # Check if secret already exists
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warning "Secret $SECRET_NAME already exists in namespace $NAMESPACE"
        read -p "Do you want to update it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping secret update"
            return 0
        fi
        
        # Delete existing secret
        kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE"
        log_info "Existing secret deleted"
    fi
    
    # Create secret from service account key
    kubectl create secret generic "$SECRET_NAME" \
        --namespace="$NAMESPACE" \
        --from-file=gcs-service-account-key.json="$key_file" \
        --from-literal=bucket-name="$BUCKET_NAME" \
        --from-literal=project-id="$PROJECT_ID"
    
    if [ $? -eq 0 ]; then
        log_success "Kubernetes secret created successfully"
        
        # Clean up key file for security
        log_info "Cleaning up service account key file..."
        rm "$key_file"
        log_success "Service account key file deleted for security"
    else
        log_error "Failed to create Kubernetes secret"
        exit 1
    fi
}

# Function to apply backup configuration
apply_backup_config() {
    log_info "📝 Applying backup configuration..."
    
    # Apply the backup credentials template
    if [ -f "manifests/secrets/backup-credentials-template.yaml" ]; then
        # Replace template values and apply
        sed "s/codet-prod-yb/$NAMESPACE/g" manifests/secrets/backup-credentials-template.yaml | \
        sed "s/yugabytedb-backups-prod/$BUCKET_NAME/g" | \
        kubectl apply -f -
        
        log_success "Backup configuration applied"
    else
        log_warning "Backup credentials template not found, skipping..."
    fi
}

# Function to verify backup setup
verify_backup_setup() {
    log_info "🧪 Verifying backup setup..."
    
    # Test bucket access
    log_info "Testing GCS bucket access..."
    echo "test-backup-$(date +%s)" | gsutil cp - "gs://$BUCKET_NAME/test-file.txt"
    gsutil rm "gs://$BUCKET_NAME/test-file.txt"
    log_success "GCS bucket access verified"
    
    # Check Kubernetes secret
    log_info "Verifying Kubernetes secret..."
    if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        local bucket_name
        bucket_name=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.bucket-name}' | base64 -d)
        if [ "$bucket_name" = "$BUCKET_NAME" ]; then
            log_success "Kubernetes secret verified"
        else
            log_error "Kubernetes secret bucket name mismatch"
            exit 1
        fi
    else
        log_error "Kubernetes secret not found"
        exit 1
    fi
    
    log_success "Backup setup verification completed"
}

# Function to display setup summary
display_summary() {
    log_success "🎉 Backup storage setup completed!"
    echo ""
    echo "================================================="
    echo "🔧 BACKUP CONFIGURATION SUMMARY"
    echo "================================================="
    echo "Project ID: $PROJECT_ID"
    echo "Environment: $ENVIRONMENT"
    echo "GCS Bucket: gs://$BUCKET_NAME"
    echo "Service Account: $SERVICE_ACCOUNT_EMAIL"
    echo "Kubernetes Namespace: $NAMESPACE"
    echo "Kubernetes Secret: $SECRET_NAME"
    echo "================================================="
    echo ""
    echo "📋 Next Steps:"
    echo "1. Deploy/update your YugabyteDB cluster:"
    echo "   kubectl apply -f manifests/clusters/codet-${ENVIRONMENT}-yb-cluster.yaml"
    echo ""
    echo "2. Verify backup functionality:"
    echo "   kubectl logs -n $NAMESPACE -l app=yb-tserver | grep -i backup"
    echo ""
    echo "3. Test backup and restore procedures"
    echo ""
    echo "📊 Backup Schedule:"
    echo "   - Full backups: Sundays at 2:00 AM"
    echo "   - Incremental backups: Monday-Saturday at 2:00 AM"
    echo "   - Retention: 30 days (configurable)"
    echo "   - Long-term retention: 365 days for yearly backups"
}

# Main execution function
main() {
    log_info "🚀 Starting YugabyteDB backup storage setup..."
    log_info "Project: $PROJECT_ID | Environment: $ENVIRONMENT"
    
    # Execute setup steps
    check_prerequisites
    create_backup_bucket
    create_service_account
    create_service_account_key
    create_kubernetes_secret
    apply_backup_config
    verify_backup_setup
    display_summary
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Backup setup failed with exit code $exit_code"
        
        # Clean up any temporary files
        if [ -f "backup-service-account-key.json" ]; then
            log_info "Cleaning up service account key file..."
            rm "backup-service-account-key.json"
        fi
        
        if [ -f "bucket-lifecycle.json" ]; then
            rm "bucket-lifecycle.json"
        fi
    fi
}

trap cleanup EXIT

# Run main function
main "$@" 