variable "project_id" {
  description = "The GCP Project ID for the Multi-Tenant ODA Canvas PoC"
  type        = string
  default     = "gcp-oda-canvas-poc"
}

variable "region" {
  description = "GCP region for the GKE cluster and regional resources"
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "Availability zones for the GKE Standard cluster"
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b"]
}

variable "cluster_name" {
  description = "Name of the Private GKE Standard Cluster hosting TM Forum ODA Canvas"
  type        = string
  default     = "oda-canvas-mt-gke"
}

variable "vpc_name" {
  description = "Name of the custom VPC network"
  type        = string
  default     = "oda-canvas-vpc"
}

variable "subnet_cidr" {
  description = "Primary CIDR range for GKE nodes"
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary CIDR range for GKE Pods"
  type        = string
  default     = "10.48.0.0/14"
}

variable "services_cidr" {
  description = "Secondary CIDR range for GKE Services"
  type        = string
  default     = "10.52.0.0/20"
}

variable "master_ipv4_cidr_block" {
  description = "Private /28 CIDR block for the GKE control plane"
  type        = string
  default     = "172.16.0.32/28"
}

variable "tenants" {
  description = "List of initial ODA Canvas tenant namespaces to provision GCP IAM & Secret Manager resources for"
  type        = list(string)
  default     = ["tenant-alpha", "tenant-beta"]
}

variable "system_node_machine_type" {
  description = "Machine type for the ODA Canvas control plane node pool"
  type        = string
  default     = "e2-standard-4"
}

variable "tenant_node_machine_type" {
  description = "Machine type for the multi-tenant ODA workload node pool"
  type        = string
  default     = "e2-standard-4"
}
