#!/usr/bin/env bash
# ==============================================================================
# Bootstrap New GCP Project, Terraform State Bucket & GitHub Actions WIF
# Target GitHub Org/User: https://github.com/wipro-gcp-ashu
# ==============================================================================
set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-wipro-gcp-ashu}"
GITHUB_REPO="${GITHUB_REPO:-oda-canvas-poc}"
PROJECT_ID="${PROJECT_ID:-gcp-oda-canvas-poc}"
REGION="${REGION:-us-central1}"
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:-}" # Optional if project already exists

echo "=================================================================="
echo " Bootstrapping GCP Project & GitHub WIF for ${GITHUB_OWNER}/${GITHUB_REPO}"
echo " Project ID : ${PROJECT_ID}"
echo " Region     : ${REGION}"
echo "=================================================================="

# 1. Create GCP Project if it doesn't exist
if ! gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[1/6] Creating new GCP Project: ${PROJECT_ID}..."
  gcloud projects create "${PROJECT_ID}" --name="TMF ODA Canvas MultiTenant PoC"
  if [[ -n "${BILLING_ACCOUNT_ID}" ]]; then
    gcloud billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT_ID}"
  else
    echo "WARNING: Please link a billing account to ${PROJECT_ID} in GCP Console or set BILLING_ACCOUNT_ID."
  fi
else
  echo "[1/6] GCP Project ${PROJECT_ID} already exists."
fi

gcloud config set project "${PROJECT_ID}"

# 2. Enable Bootstrap APIs
echo "[2/6] Enabling IAM, Resource Manager, STS & Storage APIs..."
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  serviceusage.googleapis.com

# 3. Create GCS Bucket for Terraform Remote State
TF_STATE_BUCKET="${PROJECT_ID}-tfstate"
echo "[3/6] Creating GCS Bucket gs://${TF_STATE_BUCKET} for Terraform state..."
if ! gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${TF_STATE_BUCKET}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
  gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning
fi

# 4. Create GitHub Actions Deployer Service Account
SA_NAME="github-oda-deployer"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "[4/6] Creating Service Account ${SA_EMAIL}..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="GitHub Actions ODA Canvas Deployer"
fi

for ROLE in \
  "roles/container.admin" \
  "roles/compute.admin" \
  "roles/iam.serviceAccountAdmin" \
  "roles/iam.serviceAccountUser" \
  "roles/resourcemanager.projectIamAdmin" \
  "roles/secretmanager.admin" \
  "roles/artifactregistry.admin" \
  "roles/serviceusage.serviceUsageAdmin" \
  "roles/storage.admin" \
  "roles/monitoring.admin"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

# 5. Configure Workload Identity Pool & GitHub OIDC Provider
POOL_NAME="github-actions-pool"
PROVIDER_NAME="github-oidc-provider"
echo "[5/6] Configuring GCP Workload Identity Federation for ${GITHUB_OWNER}/${GITHUB_REPO}..."

if ! gcloud iam workload-identity-pools describe "${POOL_NAME}" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_NAME}" \
    --location="global" \
    --display-name="GitHub Actions Pool"
fi

WORKLOAD_IDENTITY_POOL_ID=$(gcloud iam workload-identity-pools describe "${POOL_NAME}" \
  --location="global" --format="value(name)")

if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_NAME}" \
  --workload-identity-pool="${POOL_NAME}" --location="global" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_NAME}" \
    --workload-identity-pool="${POOL_NAME}" \
    --location="global" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_OWNER}'"
fi

WIF_PROVIDER_FULL=$(gcloud iam workload-identity-pools providers describe "${PROVIDER_NAME}" \
  --workload-identity-pool="${POOL_NAME}" \
  --location="global" \
  --format="value(name)")

# 6. Allow GitHub Repository wipro-gcp-ashu/<REPO> to impersonate the Service Account
echo "[6/6] Binding ${GITHUB_OWNER}/${GITHUB_REPO} to ${SA_EMAIL}..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WORKLOAD_IDENTITY_POOL_ID}/attribute.repository/${GITHUB_OWNER}/${GITHUB_REPO}" >/dev/null

echo ""
echo "=================================================================="
echo " BOOTSTRAP COMPLETE! Add these Repository Variables in GitHub:"
echo " URL: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/settings/variables/actions"
echo "=================================================================="
echo "GCP_PROJECT_ID          = ${PROJECT_ID}"
echo "GCP_REGION              = ${REGION}"
echo "GKE_CLUSTER_NAME        = oda-canvas-mt-gke"
echo "TF_STATE_BUCKET         = ${TF_STATE_BUCKET}"
echo "WIF_PROVIDER            = ${WIF_PROVIDER_FULL}"
echo "WIF_SERVICE_ACCOUNT     = ${SA_EMAIL}"
echo "=================================================================="
