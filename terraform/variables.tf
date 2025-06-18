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
  default     = "codet-yugabyte-cluster"  # Match tfvars.example
}

# Cluster Autoscaling Limits
variable "min_cpu" {
  description = "Minimum CPU cores for cluster autoscaling"
  type        = number
  default     = 4
}

variable "max_cpu" {
  description = "Maximum CPU cores for cluster autoscaling"
  type        = number
  default     = 40
}

variable "min_memory" {
  description = "Minimum memory in GB for cluster autoscaling"
  type        = number
  default     = 16
}

variable "max_memory" {
  description = "Maximum memory in GB for cluster autoscaling"
  type        = number
  default     = 80
}

# General Purpose Node Pool Configuration
variable "general_machine_type" {
  description = "Machine type for general purpose node pool"
  type        = string
  default     = "e2-micro"
  validation {
    condition = can(regex("^(e2-micro|e2-small|e2-medium|e2-standard-[2-8]|n2-standard-[2-8]|n2-highmem-[2-8])$", var.general_machine_type))
    error_message = "Machine type must be a valid GCE machine type."
  }
}

variable "general_min_nodes" {
  description = "Minimum nodes in general purpose pool"
  type        = number
  default     = 1
}

variable "general_max_nodes" {
  description = "Maximum nodes in general purpose pool"
  type        = number
  default     = 6
}

# YugabyteDB TServer Node Pool Configuration
variable "tserver_machine_type" {
  description = "Machine type for YugabyteDB TServer node pool"
  type        = string
  default     = "e2-small"
  validation {
    condition = can(regex("^(e2-micro|e2-small|e2-medium|e2-standard-[2-8]|n2-standard-[2-8]|n2-highmem-[2-8])$", var.tserver_machine_type))
    error_message = "Machine type must be a valid GCE machine type."
  }
}

variable "tserver_min_nodes" {
  description = "Minimum nodes in TServer pool"
  type        = number
  default     = 0
}

variable "tserver_max_nodes" {
  description = "Maximum nodes in TServer pool"
  type        = number
  default     = 6
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
  description = "Maintenance window start time (RFC3339 format) - will be calculated dynamically"
  type        = string
  default     = ""  # Will be calculated in main.tf to next Saturday 2 AM
}

variable "maintenance_end_time" {
  description = "Maintenance window end time (RFC3339 format) - will be calculated dynamically"
  type        = string
  default     = ""  # Will be calculated in main.tf to next Saturday 6 AM
}

variable "maintenance_recurrence" {
  description = "Maintenance window recurrence (RFC5545 RRULE)"
  type        = string
  default     = "FREQ=WEEKLY;BYDAY=SA"
}

variable "maintenance_start_hour" {
  description = "Maintenance window start hour (0-23)"
  type        = number
  default     = 2
  validation {
    condition     = var.maintenance_start_hour >= 0 && var.maintenance_start_hour <= 23
    error_message = "Maintenance start hour must be between 0 and 23."
  }
}

variable "maintenance_duration_hours" {
  description = "Maintenance window duration in hours"
  type        = number
  default     = 4
  validation {
    condition     = var.maintenance_duration_hours >= 1 && var.maintenance_duration_hours <= 12
    error_message = "Maintenance duration must be between 1 and 12 hours."
  }
}

 