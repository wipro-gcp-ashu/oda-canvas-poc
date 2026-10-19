terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.30"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.30"
    }
  }

  # Uncomment after running scripts/bootstrap-gcp-wif.sh to store state in GCS
  # backend "gcs" {
  #   bucket = "REPLACE_WITH_TF_STATE_BUCKET"
  #   prefix = "oda-canvas-multitenant-poc/infra"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
