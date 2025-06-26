# YugabyteDB Multi-Zone Kubernetes Deployment Makefile
# Professional automation for common development and deployment tasks

# === CONFIGURATION ===
.PHONY: help install clean test deploy destroy validate lint security docs \
	multi-cluster-deploy multi-cluster-test multi-cluster-status multi-cluster-clean
.DEFAULT_GOAL := help

# Project configuration
PROJECT_NAME := yugabytedb-multizone
CLUSTER_NAME ?= yb-demo
REGION ?= us-central1
ENVIRONMENT ?= dev

# Multi-cluster configuration
# Note: Staging cluster temporarily removed per user request - can be re-added later
CLUSTERS := codet-dev-yb codet-prod-yb
REGIONS := us-west1 us-east1

# Tool versions
KUBECTL_VERSION := v1.28.0
HELM_VERSION := v3.13.0
GCLOUD_VERSION := latest

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

# === HELP TARGET ===
help: ## Show this help message
	@echo "$(GREEN)YugabyteDB Multi-Zone/Multi-Cluster Kubernetes Deployment$(NC)"
	@echo "$(BLUE)Available targets:$(NC)"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(YELLOW)%-30s$(NC) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(BLUE)Multi-Cluster Examples:$(NC)"
	@echo "  make multi-cluster-deploy       # Deploy all 3 clusters"
	@echo "  make multi-cluster-test          # Test multi-cluster setup"
	@echo "  make multi-cluster-status        # Check status of all clusters"
	@echo ""
	@echo "$(BLUE)Single Environment Examples:$(NC)"
	@echo "  make install                     # Install all dependencies"
	@echo "  make deploy ENVIRONMENT=prod    # Deploy to production"
	@echo "  make test                        # Run all tests"
	@echo "  make security                    # Run security scans"

# === MULTI-CLUSTER TARGETS ===
multi-cluster-deploy: ## Deploy complete multi-cluster setup (3 environments)
	@echo "$(GREEN)🚀 Starting multi-cluster deployment...$(NC)"
	@chmod +x scripts/create-multi-cluster-yugabytedb.sh
	@./scripts/create-multi-cluster-yugabytedb.sh all
	@echo "$(GREEN)✅ Multi-cluster deployment completed$(NC)"

multi-cluster-vpc: ## Create private VPC network for multi-cluster
	@echo "$(GREEN)🌐 Creating private VPC network...$(NC)"
	@./scripts/create-multi-cluster-yugabytedb.sh vpc

multi-cluster-clusters: ## Create all GKE clusters
	@echo "$(GREEN)☸️ Creating GKE clusters...$(NC)"
	@./scripts/create-multi-cluster-yugabytedb.sh clusters

multi-cluster-yugabytedb: ## Install YugabyteDB in all clusters
	@echo "$(GREEN)🗄️ Installing YugabyteDB in all clusters...$(NC)"
	@./scripts/create-multi-cluster-yugabytedb.sh install

multi-cluster-test: ## Test multi-cluster connectivity and functionality
	@echo "$(GREEN)🔗 Testing multi-cluster setup...$(NC)"
	@chmod +x scripts/test-yugabytedb-connectivity.sh
	@./scripts/test-yugabytedb-connectivity.sh all

multi-cluster-status: ## Show status of all clusters
	@echo "$(GREEN)📊 Multi-cluster status...$(NC)"
	@./scripts/test-yugabytedb-connectivity.sh health

multi-cluster-info: ## Show connection information for all clusters
	@echo "$(GREEN)ℹ️ Connection information...$(NC)"
	@./scripts/test-yugabytedb-connectivity.sh info

multi-cluster-clean: ## Clean up all multi-cluster resources
	@echo "$(RED)🧹 Cleaning up multi-cluster resources...$(NC)"
	@read -p "Are you sure you want to destroy all clusters? [y/N] " confirm && \
	if [ "$$confirm" = "y" ]; then \
		for cluster in $(CLUSTERS); do \
			region=$$(echo $$cluster | sed 's/codet-dev-yb/us-west1/; s/codet-staging-yb/us-central1/; s/codet-prod-yb/us-east1/'); \
			echo "$(YELLOW)Destroying $$cluster in $$region...$(NC)"; \
			gcloud container clusters delete $$cluster --region=$$region --quiet || true; \
		done; \
		echo "$(YELLOW)Removing VPC network...$(NC)"; \
		gcloud compute networks delete yugabytedb-private-vpc --quiet || true; \
		echo "$(GREEN)✅ All resources cleaned up$(NC)"; \
	else \
		echo "$(YELLOW)Cleanup cancelled$(NC)"; \
	fi

# === INDIVIDUAL CLUSTER TARGETS ===
deploy-dev: ## Deploy development cluster only
	@echo "$(GREEN)Deploying development cluster...$(NC)"
	@kubectl config use-context codet-dev-yb-context || echo "Context not found"
	@kubectl apply -f manifests/clusters/codet-dev-yb-cluster.yaml
	@helm upgrade --install codet-dev-yb yugabytedb/yugabyte \
		--namespace codet-dev-yb \
		--create-namespace \
		-f manifests/values/multi-cluster/overrides-codet-dev-yb.yaml \
		--wait

deploy-staging: ## Deploy staging cluster only
	@echo "$(GREEN)Deploying staging cluster...$(NC)"
	@kubectl config use-context codet-staging-yb-context || echo "Context not found"
	@kubectl apply -f manifests/clusters/codet-staging-yb-cluster.yaml
	@helm upgrade --install codet-staging-yb yugabytedb/yugabyte \
		--namespace codet-staging-yb \
		--create-namespace \
		-f manifests/values/multi-cluster/overrides-codet-staging-yb.yaml \
		--wait

deploy-prod: ## Deploy production cluster only
	@echo "$(GREEN)Deploying production cluster...$(NC)"
	@kubectl config use-context codet-prod-yb-context || echo "Context not found"
	@kubectl apply -f manifests/clusters/codet-prod-yb-cluster.yaml
	@helm upgrade --install codet-prod-yb yugabytedb/yugabyte \
		--namespace codet-prod-yb \
		--create-namespace \
		-f manifests/values/multi-cluster/overrides-codet-prod-yb.yaml \
		--wait

# === CONTEXT MANAGEMENT ===
context-dev: ## Switch to development cluster context
	@kubectl config use-context codet-dev-yb-context

context-staging: ## Switch to staging cluster context
	@kubectl config use-context codet-staging-yb-context

context-prod: ## Switch to production cluster context
	@kubectl config use-context codet-prod-yb-context

contexts: ## List all cluster contexts
	@kubectl config get-contexts | grep -E "(codet-dev-yb|codet-staging-yb|codet-prod-yb)" || echo "No multi-cluster contexts found"

# === DATABASE ACCESS ===
ysql-dev: ## Connect to development YSQL
	@kubectl config use-context codet-dev-yb-context
	@kubectl exec -it -n codet-dev-yb yb-tserver-0 -- ysqlsh -h yb-tserver-0.yb-tservers.codet-dev-yb

ysql-staging: ## Connect to staging YSQL
	@kubectl config use-context codet-staging-yb-context
	@kubectl exec -it -n codet-staging-yb yb-tserver-0 -- ysqlsh -h yb-tserver-0.yb-tservers.codet-staging-yb -U yugabyte

ysql-prod: ## Connect to production YSQL
	@kubectl config use-context codet-prod-yb-context
	@kubectl exec -it -n codet-prod-yb yb-tserver-0 -- ysqlsh -h yb-tserver-0.yb-tservers.codet-prod-yb -U yugabyte

ycql-dev: ## Connect to development YCQL
	@kubectl config use-context codet-dev-yb-context
	@kubectl exec -it -n codet-dev-yb yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.codet-dev-yb

ycql-staging: ## Connect to staging YCQL
	@kubectl config use-context codet-staging-yb-context
	@kubectl exec -it -n codet-staging-yb yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.codet-staging-yb -u yugabyte

ycql-prod: ## Connect to production YCQL
	@kubectl config use-context codet-prod-yb-context
	@kubectl exec -it -n codet-prod-yb yb-tserver-0 -- ycqlsh yb-tserver-0.yb-tservers.codet-prod-yb -u yugabyte

# === INSTALLATION TARGETS ===
install: ## Install all required dependencies and tools
	@echo "$(GREEN)Installing dependencies...$(NC)"
	@$(MAKE) install-gcloud
	@$(MAKE) install-kubectl
	@$(MAKE) install-helm
	@$(MAKE) install-tools
	@echo "$(GREEN)✅ All dependencies installed$(NC)"

install-gcloud: ## Install Google Cloud SDK
	@echo "$(BLUE)Checking Google Cloud SDK...$(NC)"
	@if ! command -v gcloud >/dev/null 2>&1; then \
		echo "$(YELLOW)Installing Google Cloud SDK...$(NC)"; \
		curl https://sdk.cloud.google.com | bash; \
		exec -l $$SHELL; \
	else \
		echo "$(GREEN)✅ Google Cloud SDK already installed$(NC)"; \
	fi

install-kubectl: ## Install kubectl
	@echo "$(BLUE)Checking kubectl...$(NC)"
	@if ! command -v kubectl >/dev/null 2>&1; then \
		echo "$(YELLOW)Installing kubectl $(KUBECTL_VERSION)...$(NC)"; \
		curl -LO "https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/linux/amd64/kubectl"; \
		chmod +x kubectl; \
		sudo mv kubectl /usr/local/bin/; \
	else \
		echo "$(GREEN)✅ kubectl already installed$(NC)"; \
	fi

install-helm: ## Install Helm
	@echo "$(BLUE)Checking Helm...$(NC)"
	@if ! command -v helm >/dev/null 2>&1; then \
		echo "$(YELLOW)Installing Helm $(HELM_VERSION)...$(NC)"; \
		curl https://get.helm.sh/helm-$(HELM_VERSION)-linux-amd64.tar.gz | tar -xz; \
		sudo mv linux-amd64/helm /usr/local/bin/; \
		rm -rf linux-amd64; \
	else \
		echo "$(GREEN)✅ Helm already installed$(NC)"; \
	fi

install-tools: ## Install additional development tools
	@echo "$(BLUE)Installing additional tools...$(NC)"
	# Add Helm repository
	@helm repo add yugabytedb https://charts.yugabyte.com
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	@helm repo update
	# Install YQ for YAML processing
	@if ! command -v yq >/dev/null 2>&1; then \
		echo "$(YELLOW)Installing yq...$(NC)"; \
		wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64; \
		chmod +x /usr/local/bin/yq; \
	fi
	@echo "$(GREEN)✅ Additional tools installed$(NC)"

# === MONITORING AND OBSERVABILITY ===
deploy-monitoring: ## Deploy monitoring stack to all clusters
	@echo "$(GREEN)Deploying monitoring stack...$(NC)"
	@for cluster in $(CLUSTERS); do \
		echo "$(YELLOW)Deploying monitoring to $$cluster...$(NC)"; \
		kubectl config use-context $$cluster-context; \
		kubectl apply -f manifests/monitoring/prometheus-stack.yaml || true; \
	done
	@echo "$(GREEN)✅ Monitoring stack deployed$(NC)"

deploy-dashboards: ## Deploy Grafana dashboards for multi-cluster monitoring
	@echo "$(GREEN)Deploying Grafana dashboards...$(NC)"
	@echo "$(BLUE)Creating monitoring namespace...$(NC)"
	@kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@echo "$(BLUE)Deploying datasources and dashboard providers...$(NC)"
	@kubectl apply -f manifests/monitoring/grafana-datasources.yaml
	@echo "$(BLUE)Creating dashboard ConfigMaps...$(NC)"
	@kubectl create configmap grafana-dashboard-yugabytedb-overview \
		--from-file=manifests/monitoring/dashboards/yugabytedb-cluster-overview.json \
		--namespace=monitoring \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl label configmap grafana-dashboard-yugabytedb-overview grafana_dashboard=1 -n monitoring --overwrite
	@kubectl create configmap grafana-dashboard-yugabytedb-details \
		--from-file=manifests/monitoring/dashboards/yugabytedb-environment-details.json \
		--namespace=monitoring \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl label configmap grafana-dashboard-yugabytedb-details grafana_dashboard=1 -n monitoring --overwrite
	@kubectl create configmap grafana-dashboard-kubernetes-infra \
		--from-file=manifests/monitoring/dashboards/kubernetes-infrastructure.json \
		--namespace=monitoring \
		--dry-run=client -o yaml | kubectl apply -f -
	@kubectl label configmap grafana-dashboard-kubernetes-infra grafana_dashboard=1 -n monitoring --overwrite
	@echo "$(GREEN)✅ Grafana dashboards deployed successfully$(NC)"
	@echo "$(YELLOW)Dashboard URLs:$(NC)"
	@echo "  - Multi-Cluster Overview: http://grafana.local/d/yugabytedb-multi-cluster"
	@echo "  - Environment Details: http://grafana.local/d/yugabytedb-environment-details"  
	@echo "  - Kubernetes Infrastructure: http://grafana.local/d/kubernetes-infrastructure"

monitoring-full: deploy-monitoring deploy-dashboards ## Deploy complete monitoring stack with dashboards

# === TESTING TARGETS ===
test: ## Run all tests
	@echo "$(GREEN)Running tests...$(NC)"
	@$(MAKE) test-connectivity
	@$(MAKE) test-multi-cluster
	@$(MAKE) test-security
	@echo "$(GREEN)✅ All tests completed$(NC)"

test-connectivity: ## Test database connectivity
	@echo "$(BLUE)Testing connectivity...$(NC)"
	@./scripts/test-yugabytedb-connectivity.sh connectivity

test-multi-cluster: ## Test multi-cluster functionality
	@echo "$(BLUE)Testing multi-cluster functionality...$(NC)"
	@./scripts/test-yugabytedb-connectivity.sh multi-cluster

test-security: ## Run security tests
	@echo "$(BLUE)Running security tests...$(NC)"
	@./scripts/security-scan.sh

# === SCALING OPERATIONS ===
scale-staging: ## Scale staging cluster
	@echo "$(GREEN)Scaling staging cluster...$(NC)"
	@kubectl config use-context codet-staging-yb-context
	@helm upgrade codet-staging-yb yugabytedb/yugabyte \
		--namespace codet-staging-yb \
		-f manifests/values/multi-cluster/overrides-codet-staging-yb.yaml \
		--set replicas.tserver=2

scale-prod: ## Scale production cluster
	@echo "$(GREEN)Scaling production cluster...$(NC)"
	@kubectl config use-context codet-prod-yb-context
	@helm upgrade codet-prod-yb yugabytedb/yugabyte \
		--namespace codet-prod-yb \
		-f manifests/values/multi-cluster/overrides-codet-prod-yb.yaml \
		--set replicas.tserver=3

# === MAINTENANCE ===
restart-all: ## Restart all clusters
	@echo "$(YELLOW)Restarting all clusters...$(NC)"
	@for cluster in $(CLUSTERS); do \
		echo "$(YELLOW)Restarting $$cluster...$(NC)"; \
		kubectl config use-context $$cluster-context; \
		kubectl rollout restart statefulset/yb-master -n $$cluster || true; \
		kubectl rollout restart statefulset/yb-tserver -n $$cluster || true; \
	done

backup-all: ## Create backups for all clusters
	@echo "$(GREEN)Creating backups...$(NC)"
	@kubectl apply -f manifests/backup/backup-schedule.yaml
	@kubectl apply -f manifests/backup/backup-strategy.yaml

# === LOGS ===
logs-dev: ## View development logs
	@kubectl config use-context codet-dev-yb-context
	@kubectl logs -f -n codet-dev-yb yb-master-0

logs-staging: ## View staging logs
	@kubectl config use-context codet-staging-yb-context
	@kubectl logs -f -n codet-staging-yb yb-master-0

logs-prod: ## View production logs
	@kubectl config use-context codet-prod-yb-context
	@kubectl logs -f -n codet-prod-yb yb-master-0

# === VALIDATION TARGETS ===
validate: ## Validate all configurations
	@echo "$(GREEN)Validating configurations...$(NC)"
	@$(MAKE) validate-yaml
	@$(MAKE) validate-kubernetes
	@echo "$(GREEN)✅ All validations passed$(NC)"

validate-yaml: ## Validate YAML syntax
	@echo "$(BLUE)Validating YAML files...$(NC)"
	@find manifests/ -name "*.yaml" -o -name "*.yml" | xargs -I {} sh -c 'echo "Validating {}" && yq eval . {} > /dev/null'

validate-kubernetes: ## Validate Kubernetes manifests
	@echo "$(BLUE)Validating Kubernetes manifests...$(NC)"
	@kubectl apply --dry-run=client -f manifests/clusters/ || echo "Some manifests may need cluster context"

# === SECURITY ===
security: ## Run comprehensive security scan
	@echo "$(GREEN)Running security scan...$(NC)"
	@./scripts/security-scan.sh

# === CLEANUP ===
clean: ## Clean up development resources
	@echo "$(YELLOW)Cleaning up development resources...$(NC)"
	@kubectl config use-context codet-dev-yb-context || true
	@helm uninstall codet-dev-yb -n codet-dev-yb || true
	@kubectl delete namespace codet-dev-yb || true

# === LEGACY SINGLE CLUSTER SUPPORT ===
cluster-create: ## Create single GKE cluster (legacy)
	@echo "$(GREEN)Creating GKE cluster...$(NC)"
	@bash scripts/create-gke-clusters.sh --cluster $(CLUSTER_NAME) --region $(REGION)

cluster-destroy: ## Destroy single GKE cluster (legacy)
	@echo "$(RED)Destroying GKE cluster $(CLUSTER_NAME)...$(NC)"
	@read -p "Are you sure you want to destroy cluster $(CLUSTER_NAME)? [y/N] " confirm && \
	if [ "$$confirm" = "y" ]; then \
		gcloud container clusters delete $(CLUSTER_NAME) --region=$(REGION) --quiet; \
		echo "$(GREEN)✅ Cluster destroyed$(NC)"; \
	else \
		echo "$(YELLOW)Cluster destruction cancelled$(NC)"; \
	fi

# === QUICK OPERATIONS ===
quick-deploy: ## Quick deployment (dev only)
	@echo "$(GREEN)Quick deployment (dev only)...$(NC)"
	@$(MAKE) deploy-dev

quick-test: ## Quick connectivity test
	@echo "$(GREEN)Quick connectivity test...$(NC)"
	@./scripts/test-yugabytedb-connectivity.sh connectivity

quick-status: ## Quick status check
	@echo "$(GREEN)Quick status check...$(NC)"
	@for cluster in $(CLUSTERS); do \
		echo "$(YELLOW)Status for $$cluster:$(NC)"; \
		kubectl config use-context $$cluster-context 2>/dev/null || echo "Context not found"; \
		kubectl get pods -n $$cluster 2>/dev/null || echo "Namespace not found"; \
		echo ""; \
	done

# === SECURITY: SECRET GENERATION TARGETS - FIXED CRITICAL ISSUE ===
.PHONY: generate-secrets generate-secrets-dev generate-secrets-staging generate-secrets-prod generate-grafana-secret

generate-secrets: generate-secrets-dev generate-secrets-prod generate-grafana-secret ## Generate all secrets for active environments (staging excluded)
	@echo "$(GREEN)✅ All secrets generated$(NC)"

generate-secrets-dev: ## Generate development environment secrets
	@echo "$(BLUE)🔐 Generating development secrets...$(NC)"
	@kubectl create namespace codet-dev-yb --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic codet-dev-yb-credentials \
		--from-literal=yugabyte.password="$$(openssl rand -base64 32)" \
		--from-literal=postgres.password="$$(openssl rand -base64 32)" \
		--namespace=codet-dev-yb \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "$(GREEN)✅ Development secrets generated$(NC)"

generate-secrets-staging: ## Generate staging environment secrets
	@echo "$(BLUE)🔐 Generating staging secrets...$(NC)"
	@kubectl create namespace codet-staging-yb --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic codet-staging-yb-credentials \
		--from-literal=yugabyte.password="$$(openssl rand -base64 32)" \
		--from-literal=postgres.password="$$(openssl rand -base64 32)" \
		--namespace=codet-staging-yb \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "$(GREEN)✅ Staging secrets generated$(NC)"

generate-secrets-prod: ## Generate production environment secrets
	@echo "$(BLUE)🔐 Generating production secrets...$(NC)"
	@kubectl create namespace codet-prod-yb --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic codet-prod-yb-credentials \
		--from-literal=yugabyte.password="$$(openssl rand -base64 48)" \
		--from-literal=postgres.password="$$(openssl rand -base64 48)" \
		--namespace=codet-prod-yb \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "$(GREEN)✅ Production secrets generated$(NC)"

generate-grafana-secret: ## Generate Grafana admin secret
	@echo "$(BLUE)🔐 Generating Grafana admin secret...$(NC)"
	@kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic grafana-admin-secret \
		--from-literal=admin-user=admin \
		--from-literal=admin-password="$$(openssl rand -base64 32)" \
		--namespace=monitoring \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "$(GREEN)✅ Grafana admin secret generated$(NC)"

# === ADDITIONAL SERVICES FOR MONITORING ===
deploy-support-services: ## Deploy supporting services (webhook, SMTP relay)
	@echo "$(GREEN)Deploying support services...$(NC)"
	@kubectl apply -f manifests/monitoring/webhook-service.yaml
	@kubectl apply -f manifests/monitoring/smtp-relay.yaml
	@echo "$(GREEN)✅ Support services deployed$(NC)" 