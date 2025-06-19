# YugabyteDB Infrastructure - Main Terraform Configuration
# This creates a private GKE cluster with VPC for YugabyteDB deployment

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
  }
}

# Configure the Google Cloud Provider
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ✅ FIXED: Calculate maintenance window times dynamically
locals {
  # Simplified maintenance window - use a fixed time to avoid date format issues
  maintenance_start_time = var.maintenance_start_time != "" ? var.maintenance_start_time : "2024-07-01T03:00:00Z"
  maintenance_end_time   = var.maintenance_end_time != "" ? var.maintenance_end_time : "2024-07-01T07:00:00Z"
}

# Data source for available zones
data "google_compute_zones" "available" {
  project = var.project_id
  region  = var.region
}

# VPC Network
resource "google_compute_network" "yugabyte_vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  mtu                     = 1460
  project                 = var.project_id
}

# Subnet for GKE cluster
resource "google_compute_subnetwork" "yugabyte_subnet" {
  name          = var.subnet_name
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.yugabyte_vpc.id
  project       = var.project_id

  # Enable private Google access
  private_ip_google_access = true

  # Secondary IP ranges for GKE
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Cloud Router for NAT Gateway
resource "google_compute_router" "yugabyte_router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.yugabyte_vpc.id
  project = var.project_id

  bgp {
    asn = 64514
  }
}

# Cloud NAT for outbound internet access
resource "google_compute_router_nat" "yugabyte_nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.yugabyte_router.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option            = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Firewall rule for internal communication
resource "google_compute_firewall" "yugabyte_internal" {
  name    = "${var.cluster_name}-allow-internal"
  network = google_compute_network.yugabyte_vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
  priority      = 1000
}

# Firewall rule for SSH access (from IAP)
resource "google_compute_firewall" "yugabyte_ssh_iap" {
  name    = "${var.cluster_name}-allow-ssh-iap"
  network = google_compute_network.yugabyte_vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # Google IAP range
  target_tags   = ["gke-node"]
  priority      = 1000
}

# Private GKE Cluster
resource "google_container_cluster" "yugabyte_cluster" {
  provider = google-beta
  
  name     = var.cluster_name
  location = var.region
  project  = var.project_id

  # Remove default node pool
  remove_default_node_pool = true
  initial_node_count       = 1

  # Network configuration
  network    = google_compute_network.yugabyte_vpc.name
  subnetwork = google_compute_subnetwork.yugabyte_subnet.name

  # Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  # IP allocation policy
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Master authorized networks - restrict to specific ranges
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.master_authorized_networks
      display_name = "Authorized networks"
    }
  }

  # Addons configuration
  addons_config {
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }

    network_policy_config {
      disabled = false
    }

    dns_cache_config {
      enabled = true
    }
  }

  # Network policy
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Binary authorization
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  # Cluster autoscaling
  cluster_autoscaling {
    enabled = true
    
    resource_limits {
      resource_type = "cpu"
      minimum       = var.min_cpu
      maximum       = var.max_cpu
    }
    
    resource_limits {
      resource_type = "memory"
      minimum       = var.min_memory
      maximum       = var.max_memory
    }

    auto_provisioning_defaults {
      oauth_scopes = [
        "https://www.googleapis.com/auth/devstorage.read_only",
        "https://www.googleapis.com/auth/logging.write",
        "https://www.googleapis.com/auth/monitoring",
        "https://www.googleapis.com/auth/servicecontrol",
        "https://www.googleapis.com/auth/service.management.readonly",
        "https://www.googleapis.com/auth/trace.append"
      ]

          disk_size    = 100
    disk_type    = "pd-ssd"  # ✅ FIXED: Use SSD for auto-provisioned nodes
      image_type   = "COS_CONTAINERD"

      shielded_instance_config {
        enable_secure_boot          = true
        enable_integrity_monitoring = true
      }
    }
  }

  # ✅ FIXED: Simplified maintenance policy
  maintenance_policy {
    recurring_window {
      start_time = "2024-12-21T03:00:00Z"
      end_time   = "2024-12-21T07:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA"
    }
  }

  # ✅ FIXED: Basic monitoring and logging (removed problematic workload monitoring)
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  depends_on = [
    google_compute_subnetwork.yugabyte_subnet,
    google_compute_router_nat.yugabyte_nat
  ]
}

# General purpose node pool
resource "google_container_node_pool" "general_purpose" {
  name       = "general-purpose"
  location   = var.region
  cluster    = google_container_cluster.yugabyte_cluster.name
  project    = var.project_id
  
  # Autoscaling
  autoscaling {
    min_node_count = var.general_min_nodes
    max_node_count = var.general_max_nodes
  }

  # Node configuration
  node_config {
    preemptible  = false
    machine_type = var.general_machine_type
    disk_size_gb = 100
    disk_type    = "pd-standard"
    image_type   = "COS_CONTAINERD"

    labels = {
      environment = "production"
      node-pool   = "general-purpose"
    }

    tags = ["gke-node", "${var.cluster_name}-node"]

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  # Upgrade settings
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  # Management
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# High-memory node pool for YugabyteDB TServers
resource "google_container_node_pool" "yugabyte_tserver" {
  name       = "yugabyte-tserver"
  location   = var.region
  cluster    = google_container_cluster.yugabyte_cluster.name
  project    = var.project_id
  
  # Autoscaling
  autoscaling {
    min_node_count = var.tserver_min_nodes
    max_node_count = var.tserver_max_nodes
  }

  # Node configuration
  node_config {
    preemptible  = false
    machine_type = var.tserver_machine_type
    disk_size_gb = 200
    disk_type    = "pd-standard"
    image_type   = "COS_CONTAINERD"

    labels = {
      environment = "production"
      node-pool   = "yugabyte-tserver"
      workload    = "database"
    }

    taint {
      key    = "yugabyte.com/tserver"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    tags = ["gke-node", "${var.cluster_name}-node", "yugabyte-tserver"]

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  # Upgrade settings
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  # Management
  management {
    auto_repair  = true
    auto_upgrade = true
  }
} 