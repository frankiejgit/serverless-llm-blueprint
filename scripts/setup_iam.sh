#!/bin/bash
# scripts/setup_iam.sh

set -e

if [ -f .env ]; then
    source .env
fi

# Fallback PROJECT_ID to gcloud config if unset or equal to placeholder
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "your-project-id" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
fi

if [ -z "$PROJECT_ID" ]; then
    echo "Error: PROJECT_ID is not set in .env and could not be retrieved from gcloud config." >&2
    exit 1
fi

# Extract SA details from environment variables or default names
BUILD_SA_NAME="${BUILD_SA%%@*}"
[ -z "$BUILD_SA_NAME" ] && BUILD_SA_NAME="sare-build"
BUILD_SA_EMAIL="$BUILD_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

SYNTH_SA_NAME="${SYNTH_SA%%@*}"
[ -z "$SYNTH_SA_NAME" ] && SYNTH_SA_NAME="sare-synth"
SYNTH_SA_EMAIL="$SYNTH_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

BACKEND_SA_NAME="${BACKEND_SA%%@*}"
[ -z "$BACKEND_SA_NAME" ] && BACKEND_SA_NAME="sare-backend"
BACKEND_SA_EMAIL="$BACKEND_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

FRONTEND_SA_NAME="${FRONTEND_SA%%@*}"
[ -z "$FRONTEND_SA_NAME" ] && FRONTEND_SA_NAME="sare-frontend"
FRONTEND_SA_EMAIL="$FRONTEND_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

echo "=========================================================="
echo "Setting up Granular IAM Security Baseline for Project: $PROJECT_ID"
echo "=========================================================="

# 1. Enable required GCP APIs first
echo "Step 1: Enabling core GCP APIs..."
REQUIRED_APIS=(
    "iam.googleapis.com"
    "cloudbuild.googleapis.com"
    "run.googleapis.com"
    "artifactregistry.googleapis.com"
    "secretmanager.googleapis.com"
    "aiplatform.googleapis.com"
    "monitoring.googleapis.com"
)

for API in "${REQUIRED_APIS[@]}"; do
    echo "  - Enabling $API..."
    gcloud services enable "$API" --project="$PROJECT_ID" --quiet
done

# 2. Create the 4 Service Accounts
echo "Step 2: Creating Service Accounts..."

create_sa_if_missing() {
    local sa_email="$1"
    local sa_name="$2"
    local desc="$3"
    
    if ! gcloud iam service-accounts describe "$sa_email" --project="$PROJECT_ID" >/dev/null 2>&1; then
        echo "  - Creating Service Account: $sa_name ($sa_email)..."
        gcloud iam service-accounts create "$sa_name" \
            --description="$desc" \
            --display-name="$sa_name" \
            --project="$PROJECT_ID"
    else
        echo "  - Service Account exists: $sa_name"
    fi
}

create_sa_if_missing "$BUILD_SA_EMAIL" "$BUILD_SA_NAME" "Build & deployment operations identity"
create_sa_if_missing "$SYNTH_SA_EMAIL" "$SYNTH_SA_NAME" "Data synthesis Cloud Run Job identity"
create_sa_if_missing "$BACKEND_SA_EMAIL" "$BACKEND_SA_NAME" "Fine-tuning & vLLM model serving identity"
create_sa_if_missing "$FRONTEND_SA_EMAIL" "$FRONTEND_SA_NAME" "OpenWebUI & Smart Auth Proxy frontend identity"

echo "Waiting 10 seconds for service accounts to propagate..."
sleep 10

# Helper to bind roles
grant_roles() {
    local sa_email="$1"
    shift
    local roles=("$@")
    for role in "${roles[@]}"; do
        echo "  - Granting $role to $sa_email..."
        gcloud projects add-iam-policy-binding "$PROJECT_ID" \
            --member="serviceAccount:$sa_email" \
            --role="$role" \
            --quiet > /dev/null
    done
}

# 3. Grant BUILD Roles
echo "Step 3: Binding IAM Roles to Build SA ($BUILD_SA_NAME)..."
BUILD_ROLES=(
    "roles/cloudbuild.builds.builder"
    "roles/artifactregistry.admin"
    "roles/run.admin"
    "roles/logging.logWriter"
    "roles/compute.networkAdmin"
    "roles/compute.securityAdmin"
    "roles/iap.admin"
    "roles/secretmanager.secretAccessor"
)
grant_roles "$BUILD_SA_EMAIL" "${BUILD_ROLES[@]}"

# 4. Grant Data Synthesis Roles
echo "Step 4: Binding IAM Roles to Data Synthesis SA ($SYNTH_SA_NAME)..."
SYNTH_ROLES=(
    "roles/aiplatform.user"
    "roles/storage.objectAdmin"
    "roles/logging.logWriter"
    "roles/secretmanager.secretAccessor"
)
grant_roles "$SYNTH_SA_EMAIL" "${SYNTH_ROLES[@]}"

# 5. Grant Model Backend Roles
echo "Step 5: Binding IAM Roles to Model Backend SA ($BACKEND_SA_NAME)..."
BACKEND_ROLES=(
    "roles/storage.objectAdmin"
    "roles/logging.logWriter"
    "roles/monitoring.metricWriter"
    "roles/secretmanager.secretAccessor"
)
grant_roles "$BACKEND_SA_EMAIL" "${BACKEND_ROLES[@]}"

# 6. Grant Frontend Roles
echo "Step 6: Binding IAM Roles to Frontend SA ($FRONTEND_SA_NAME)..."
FRONTEND_ROLES=(
    "roles/run.invoker"
    "roles/logging.logWriter"
)
grant_roles "$FRONTEND_SA_EMAIL" "${FRONTEND_ROLES[@]}"

# 7. Allow Build SA to impersonate execution SAs during deployment
echo "Step 7: Granting Build SA impersonation rights over execution SAs..."
EXECUTION_SAS=("$SYNTH_SA_EMAIL" "$BACKEND_SA_EMAIL" "$FRONTEND_SA_EMAIL")
for EXEC_SA in "${EXECUTION_SAS[@]}"; do
    echo "  - Allowing $BUILD_SA_EMAIL to act as $EXEC_SA..."
    gcloud iam service-accounts add-iam-policy-binding "$EXEC_SA" \
        --member="serviceAccount:$BUILD_SA_EMAIL" \
        --role="roles/iam.serviceAccountUser" \
        --project="$PROJECT_ID" \
        --quiet > /dev/null
done

# 8. Configure Cloud Build Service Agent
echo "Step 8: Setting up Cloud Build Service Agent permissions..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)
if [ -z "$PROJECT_NUMBER" ]; then
    PROJECT_NUMBER=$(gcloud projects list --filter="projectId:$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null | head -n 1)
fi
PROJECT_NUMBER=$(echo "$PROJECT_NUMBER" | tr -d '\r\n[:space:]')

gcloud services identity create --service=cloudbuild.googleapis.com --project="$PROJECT_ID" 2>/dev/null || true
BUILD_AGENT="service-$PROJECT_NUMBER@gcp-sa-cloudbuild.iam.gserviceaccount.com"

echo "  - Granting Cloud Build Agent ($BUILD_AGENT) permission to act as $BUILD_SA_EMAIL..."
gcloud iam service-accounts add-iam-policy-binding "$BUILD_SA_EMAIL" \
    --member="serviceAccount:$BUILD_AGENT" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID" \
    --quiet > /dev/null

echo "=========================================================="
echo "IAM Setup Complete! 4 Dedicated Service Accounts Configured:"
echo "  1. Build SA:    $BUILD_SA_EMAIL"
echo "  2. Synth SA:    $SYNTH_SA_EMAIL"
echo "  3. Backend SA:  $BACKEND_SA_EMAIL"
echo "  4. Frontend SA: $FRONTEND_SA_EMAIL"
echo "=========================================================="
