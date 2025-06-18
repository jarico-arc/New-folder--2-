# Terraform Backend Configuration
# 
# IMPORTANT: Remote backend is DISABLED by default to avoid bucket access issues.
# To enable remote state storage, follow these steps:
#
# 1. Create a GCS bucket in your project:
#    gsutil mb gs://yugabyte-terraform-state-YOUR-PROJECT-ID
#
# 2. Enable versioning:
#    gsutil versioning set on gs://yugabyte-terraform-state-YOUR-PROJECT-ID
#
# 3. Uncomment the backend block below and update the bucket name
#
# 4. Run: terraform init -reconfigure

# terraform {
#   backend "gcs" {
#     bucket = "yugabyte-terraform-state-YOUR-PROJECT-ID"  # Replace YOUR-PROJECT-ID
#     prefix = "terraform/state"
#   }
# }

# For now, terraform will use local state files.
# This is fine for single-user deployments and getting started quickly. 