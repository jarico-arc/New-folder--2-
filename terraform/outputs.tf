# YugabyteDB Infrastructure - Outputs
# Output values that will be useful for YugabyteDB deployment

# Network Outputs
output "vpc_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.yugabyte_vpc.name
}

output "vpc_id" {
  description = "ID of the VPC network"
  value       = google_compute_network.yugabyte_vpc.id
}

output "subnet_name" {
  description = "Name of the subnet"
  value       = google_compute_subnetwork.yugabyte_subnet.name
}

output "subnet_id" {
  description = "ID of the subnet"
  value       = google_compute_subnetwork.yugabyte_subnet.id
}

output "subnet_cidr" {
  description = "CIDR range of the subnet"
  value       = google_compute_subnetwork.yugabyte_subnet.ip_cidr_range
}

output "pods_cidr" {
  description = "CIDR range for pods"
  value       = google_compute_subnetwork.yugabyte_subnet.secondary_ip_range[0].ip_cidr_range
}

output "services_cidr" {
  description = "CIDR range for services"
  value       = google_compute_subnetwork.yugabyte_subnet.secondary_ip_range[1].ip_cidr_range
}

# Cluster Outputs
output "cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.yugabyte_cluster.name
}

output "cluster_id" {
  description = "ID of the GKE cluster"
  value       = google_container_cluster.yugabyte_cluster.id
}

output "cluster_location" {
  description = "Location of the GKE cluster"
  value       = google_container_cluster.yugabyte_cluster.location
}

output "cluster_endpoint" {
  description = "Endpoint of the GKE cluster"
  value       = google_container_cluster.yugabyte_cluster.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "CA certificate of the GKE cluster"
  value       = google_container_cluster.yugabyte_cluster.master_auth.0.cluster_ca_certificate
  sensitive   = true
}

# Node Pool Outputs
output "general_purpose_node_pool_name" {
  description = "Name of the general purpose node pool"
  value       = google_container_node_pool.general_purpose.name
}

output "yugabyte_tserver_node_pool_name" {
  description = "Name of the YugabyteDB TServer node pool"
  value       = google_container_node_pool.yugabyte_tserver.name
}

# Service Account Outputs (Future)
output "cluster_service_account" {
  description = "Service account used by the GKE cluster"
  value       = google_container_cluster.yugabyte_cluster.node_config.0.service_account
  sensitive   = true
}

# Connection Information
output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.yugabyte_cluster.name} --region ${var.region} --project ${var.project_id}"
}

output "private_cluster_access_command" {
  description = "Command to access private cluster via Cloud Shell or bastion"
  value       = "gcloud compute ssh bastion-host --zone ${var.region}-a --command 'kubectl get nodes'"
}

# Firewall Rules
output "internal_firewall_rule" {
  description = "Internal firewall rule name"
  value       = google_compute_firewall.yugabyte_internal.name
}

output "ssh_iap_firewall_rule" {
  description = "SSH IAP firewall rule name"
  value       = google_compute_firewall.yugabyte_ssh_iap.name
}

# Router and NAT
output "router_name" {
  description = "Name of the Cloud Router"
  value       = google_compute_router.yugabyte_router.name
}

output "nat_name" {
  description = "Name of the Cloud NAT"
  value       = google_compute_router_nat.yugabyte_nat.name
}

# Useful Commands for YugabyteDB Deployment
output "yugabytedb_deployment_commands" {
  description = "Commands to deploy YugabyteDB on the created cluster"
  value = [
    "# 1. Get cluster credentials",
    "gcloud container clusters get-credentials ${google_container_cluster.yugabyte_cluster.name} --region ${var.region} --project ${var.project_id}",
    "",
    "# 2. Install YugabyteDB Operator",
    "kubectl apply -f ../manifests/operator/namespace.yaml",
    "helm repo add yugabytedb https://charts.yugabyte.com",
    "helm repo update",
    "helm install yugabyte-operator yugabytedb/yugabyte-k8s-operator --namespace yb-operator --wait",
    "",
    "# 3. Deploy environments",
    "kubectl apply -f ../manifests/namespaces/environments.yaml",
    "",
    "# 4. Deploy YugabyteDB clusters",
    "kubectl apply -f ../manifests/clusters/codet-dev-yb-cluster.yaml",
    "kubectl apply -f ../manifests/clusters/codet-staging-yb-cluster.yaml", 
    "kubectl apply -f ../manifests/clusters/codet-prod-yb-cluster.yaml",
    "",
    "# 5. Deploy monitoring",
    "kubectl apply -f ../manifests/monitoring/prometheus-stack.yaml",
    "",
    "# 6. Deploy security policies",
    "kubectl apply -f ../manifests/policies/network-policies.yaml",
    "kubectl apply -f ../manifests/policies/pod-disruption-budgets.yaml"
  ]
}

# Resource Summary
output "resource_summary" {
  description = "Summary of created resources"
  value = {
    vpc_network           = google_compute_network.yugabyte_vpc.name
    subnet                = google_compute_subnetwork.yugabyte_subnet.name
    gke_cluster          = google_container_cluster.yugabyte_cluster.name
    general_node_pool    = google_container_node_pool.general_purpose.name
    tserver_node_pool    = google_container_node_pool.yugabyte_tserver.name
    router               = google_compute_router.yugabyte_router.name
    nat_gateway          = google_compute_router_nat.yugabyte_nat.name
    firewall_rules       = [
      google_compute_firewall.yugabyte_internal.name,
      google_compute_firewall.yugabyte_ssh_iap.name
    ]
    region               = var.region
    project_id           = var.project_id
  }
}

# Cost Estimation Information
output "estimated_monthly_cost_info" {
  description = "Information about estimated monthly costs"
  value = {
    note = "Estimated costs depend on actual usage and Google Cloud pricing"
    components = {
      gke_cluster_management = "Free (GKE cluster management)"
      general_nodes         = "~$5/month per e2-micro node (if running 24/7)"
      tserver_nodes        = "~$15/month per e2-small node (if running 24/7)"
      network_egress       = "Variable based on traffic"
      persistent_disks     = "~$0.17/GB/month for SSD disks"
      load_balancers       = "~$18/month per load balancer"
    }
    optimization_tips = [
      "Use preemptible nodes for development environments",
      "Scale down or delete dev/staging clusters when not in use",
      "Monitor and adjust node pool sizes based on actual workload",
      "Use committed use discounts for production workloads"
    ]
  }
} 