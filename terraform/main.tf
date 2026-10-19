locals {
  required_apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "certificatemanager.googleapis.com",
    "networksecurity.googleapis.com"
  ]
}

# ------------------------------------------------------------------------------
# 1. Enable GCP Native APIs
# ------------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each           = toset(local.required_apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ------------------------------------------------------------------------------
# 2. Custom VPC, Private Subnet, Cloud Router & Cloud NAT
# ------------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.vpc_name}-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = var.services_cidr
  }
}

resource "google_compute_router" "router" {
  name    = "${var.vpc_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.vpc_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ------------------------------------------------------------------------------
# 3. Dedicated Node Service Account (Least Privilege)
# ------------------------------------------------------------------------------
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-node-sa"
  display_name = "GKE Node Service Account for ODA Canvas"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader"
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ------------------------------------------------------------------------------
# 4. Private GKE Standard Cluster with GCP-Native Features
#    - GKE Dataplane V2 (Cilium NetworkPolicy + Multi-Tenancy)
#    - GKE Gateway API Controller (Standard Channel)
#    - Google Cloud Managed Service for Prometheus (GMP)
#    - GCP Secret Manager Add-on & Workload Identity
# ------------------------------------------------------------------------------
resource "google_container_cluster" "oda_canvas" {
  provider = google-beta
  name     = var.cluster_name
  location = var.region

  node_locations            = var.zones
  remove_default_node_pool  = true
  initial_node_count        = 1
  deletion_protection       = false
  network                   = google_compute_network.vpc.id
  subnetwork                = google_compute_subnetwork.subnet.id
  networking_mode           = "VPC_NATIVE"
  datapath_provider         = "ADVANCED_DATAPATH" # Dataplane V2 (Cilium eBPF)

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # Control plane reachable via Authorized Networks for GitHub Actions
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0" # Dynamically restricted in production or updated by GitHub Actions step
      display_name = "github-actions-runner-access"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  secret_manager_config {
    enabled = true
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER"]
    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [
    google_project_service.apis,
    google_compute_router_nat.nat
  ]
}

# ------------------------------------------------------------------------------
# 5. Node Pool 1: ODA Canvas System / Control Plane Pool
# ------------------------------------------------------------------------------
resource "google_container_node_pool" "canvas_system" {
  name       = "canvas-system-pool"
  location   = var.region
  cluster    = google_container_cluster.oda_canvas.name
  node_count = 1 # 1 per zone (2 nodes total across zones)

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.system_node_machine_type
    disk_size_gb    = 50
    disk_type       = "pd-balanced"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      "oda.tmforum.org/pool-type" = "canvas-system"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# ------------------------------------------------------------------------------
# 6. Node Pool 2: Multi-Tenant ODA Components Pool
# ------------------------------------------------------------------------------
resource "google_container_node_pool" "oda_tenants" {
  name       = "oda-tenants-pool"
  location   = var.region
  cluster    = google_container_cluster.oda_canvas.name
  node_count = 1 # 1 per zone (2 nodes total across zones)

  autoscaling {
    min_node_count = 1
    max_node_count = 4
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.tenant_node_machine_type
    disk_size_gb    = 50
    disk_type       = "pd-balanced"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = {
      "oda.tmforum.org/pool-type" = "tenant-workloads"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
}

# ------------------------------------------------------------------------------
# 7. GCP Artifact Registry for ODA Components & Helm Charts
# ------------------------------------------------------------------------------
resource "google_artifact_registry_repository" "oda_repo" {
  location      = var.region
  repository_id = "oda-canvas-registry"
  description   = "TM Forum ODA Components and Canvas images"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# ------------------------------------------------------------------------------
# 8. Cloud Armor Security Policy for GCP-Native ODA API Gateway Protection
# ------------------------------------------------------------------------------
resource "google_compute_security_policy" "oda_waf" {
  name        = "oda-canvas-cloud-armor-waf"
  description = "Cloud Armor WAF policy protecting Multi-Tenant TM Forum Open APIs"

  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-stable') || evaluatePreconfiguredExpr('sqli-stable')"
      }
    }
    description = "Block SQLi and XSS attacks on TMF Open APIs"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow rule"
  }

  depends_on = [google_project_service.apis]
}

# ------------------------------------------------------------------------------
# 9. Per-Tenant GCP Workload Identity & Secret Manager Isolation
# ------------------------------------------------------------------------------
resource "google_service_account" "tenant_sa" {
  for_each     = toset(var.tenants)
  account_id   = "oda-${each.value}-sa"
  display_name = "Workload Identity SA for ODA Tenant ${each.value}"
  depends_on   = [google_project_service.apis]
}

# Bind each Tenant GCP SA strictly to its own Kubernetes Namespace [tenant-name/oda-tenant-sa]
resource "google_service_account_iam_member" "tenant_wi_binding" {
  for_each           = toset(var.tenants)
  service_account_id = google_service_account.tenant_sa[each.value].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value}/oda-tenant-sa]"
  depends_on         = [google_container_cluster.oda_canvas]
}

resource "google_secret_manager_secret" "tenant_secret" {
  for_each  = toset(var.tenants)
  secret_id = "oda-${each.value}-db-credentials"

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }

  labels = {
    tenant = each.value
    system = "oda-canvas"
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "tenant_secret_val" {
  for_each    = toset(var.tenants)
  secret      = google_secret_manager_secret.tenant_secret[each.value].id
  secret_data = jsonencode({
    tenant_id = each.value
    db_host   = "mongodb-${each.value}.${each.value}.svc.cluster.local"
    api_key   = "tmf-oda-${each.value}-poc-secret"
  })
}

# Each tenant SA can ONLY read its own Secret Manager secret
resource "google_secret_manager_secret_iam_member" "tenant_secret_access" {
  for_each  = toset(var.tenants)
  secret_id = google_secret_manager_secret.tenant_secret[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.tenant_sa[each.value].email}"
}
