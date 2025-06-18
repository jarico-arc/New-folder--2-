terraform {
  backend "gcs" {
    bucket = "yugabyte-terraform-state"  # Replace with your actual bucket name
    prefix = "terraform/state"
    
    # State locking via Cloud Storage
    # Requires terraform init -reconfigure after adding this
  }
}

# To set up the backend:
# 1. Create a GCS bucket: gsutil mb gs://yugabyte-terraform-state
# 2. Enable versioning: gsutil versioning set on gs://yugabyte-terraform-state
# 3. Run: terraform init -reconfigure 