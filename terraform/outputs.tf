output "project_id" {
  description = "GCP Project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP Region"
  value       = var.region
}

output "cluster_name" {
  description = "GKE Private Cluster Name"
  value       = google_container_cluster.oda_canvas.name
}

output "cluster_endpoint" {
  description = "GKE Control Plane Endpoint"
  value       = google_container_cluster.oda_canvas.endpoint
  sensitive   = true
}

output "artifact_registry_url" {
  description = "GCP Artifact Registry URL for ODA Components"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.oda_repo.repository_id}"
}

output "cloud_armor_policy_name" {
  description = "Cloud Armor WAF Policy protecting ODA Canvas API Gateway"
  value       = google_compute_security_policy.oda_waf.name
}

output "tenant_service_accounts" {
  description = "Map of Tenant Namespaces to GCP Workload Identity Service Account Emails"
  value = {
    for k, sa in google_service_account.tenant_sa : k => sa.email
  }
}
