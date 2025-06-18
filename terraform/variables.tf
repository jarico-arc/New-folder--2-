# YugabyteDB Infrastructure - Variables
# Input variables for Terraform configuration

# Project Configuration
variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region for resources"
  type        = string
  default     = "us-central1"
}

# Network Configuration
variable "vpc_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "yugabyte-tf-vpc"
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "yugabyte-subnet-us-central1"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "pods_cidr" {
  description = "CIDR range for pods"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_cidr" {
  description = "CIDR range for services"
  type        = string
  default     = "10.2.0.0/16"
}

variable "master_cidr" {
  description = "CIDR range for GKE master nodes"
  type        = string
  default     = "172.16.0.0/28"
}

# Cluster Configuration
variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "yugabyte-cluster"
}

# Cluster Autoscaling Limits
variable "min_cpu" {
  description = "Minimum CPU cores for cluster autoscaling"
  type        = number
  default     = 2
}

variable "max_cpu" {
  description = "Maximum CPU cores for cluster autoscaling"
  type        = number
  default     = 20
}

variable "min_memory" {
  description = "Minimum memory in GB for cluster autoscaling"
  type        = number
  default     = 8
}

variable "max_memory" {
  description = "Maximum memory in GB for cluster autoscaling"
  type        = number
  default     = 40
}

# General Purpose Node Pool Configuration
variable "general_machine_type" {
  description = "Machine type for general purpose nodes"
  type        = string
  default     = "e2-micro"
}

variable "general_min_nodes" {
  description = "Minimum nodes in general purpose pool"
  type        = number
  default     = 1
}

variable "general_max_nodes" {
  description = "Maximum nodes in general purpose pool"
  type        = number
  default     = 3
}

# YugabyteDB TServer Node Pool Configuration
variable "tserver_machine_type" {
  description = "Machine type for YugabyteDB TServer nodes"
  type        = string
  default     = "e2-small"
}

variable "tserver_min_nodes" {
  description = "Minimum nodes in TServer pool"
  type        = number
  default     = 0
}

variable "tserver_max_nodes" {
  description = "Maximum nodes in TServer pool"
  type        = number
  default     = 3
}

# Environment Configuration
variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
  
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

# Labels and Tags
variable "labels" {
  description = "Labels to apply to all resources"
  type        = map(string)
  default = {
    managed-by = "terraform"
    project    = "yugabytedb-deployment"
  }
}

# Backup and Storage Configuration
variable "backup_enabled" {
  description = "Enable automated backups"
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 30
}

# Monitoring Configuration
variable "monitoring_enabled" {
  description = "Enable enhanced monitoring"
  type        = bool
  default     = true
}

variable "logging_enabled" {
  description = "Enable enhanced logging"
  type        = bool
  default     = true
}

# Security Configuration
variable "enable_binary_authorization" {
  description = "Enable binary authorization for container images"
  type        = bool
  default     = true
}

variable "enable_network_policy" {
  description = "Enable Kubernetes network policies"
  type        = bool
  default     = true
}

variable "enable_private_nodes" {
  description = "Enable private nodes (no public IP)"
  type        = bool
  default     = true
}

variable "enable_workload_identity" {
  description = "Enable Workload Identity for secure access to GCP services"
  type        = bool
  default     = true
}

# Maintenance Configuration
variable "maintenance_start_time" {
  description = "Maintenance window start time (RFC3339 format)"
  type        = string
  default     = "2023-01-01T02:00:00Z"
}

variable "maintenance_end_time" {
  description = "Maintenance window end time (RFC3339 format)"
  type        = string
  default     = "2023-01-01T06:00:00Z"
}

variable "maintenance_recurrence" {
  description = "Maintenance window recurrence (RFC5545 RRULE)"
  type        = string
  default     = "FREQ=WEEKLY;BYDAY=SA"
}

# For production cluster only:
replicationFactor: 3
master:
  replicas: 3
tserver:
  replicas: 3
enableAuth: true
tls:
  enabled: true

# Extremely limited resources:
cpu: "0.5"      # May cause performance issues
memory: 1Gi     # May cause OOM kills 