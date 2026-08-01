#!/bin/bash
# scripts/deploy_frontend.sh

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

REGION="${REGION:-us-central1}"
AR_NAME="${AR_NAME:-sare-repo}"
SERVICE_NAME="${SERVICE_NAME:-sare-frontend}"
VPC_NAME="${VPC_NAME:-sare-vpc}"
SUBNET_NAME="${SUBNET_NAME:-sare-subnet}"

TUNED_MODEL_NAME="${TUNED_MODEL_NAME:-gemma-4-sare-tuned}"
BASE_MODEL_NAME="${BASE_MODEL_NAME:-gemma-4-base}"
WEBUI_NAME="${WEBUI_NAME:-SARE Agroforestry Advisor}"
WEBUI_SECRET_KEY="sare-demo-secret-$(date +%s)"

BUILD_SA_EMAIL="${BUILD_SA:-sare-build@${PROJECT_ID}.iam.gserviceaccount.com}"
FRONTEND_SA_EMAIL="${FRONTEND_SA:-sare-frontend@${PROJECT_ID}.iam.gserviceaccount.com}"

PROXY_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_NAME}/sare-auth-proxy:latest"
OPENWEBUI_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_NAME}/open-webui:main"

# Automatically resolve backend URLs if deployed
TUNED_MODEL_URL=$(gcloud run services describe gemma-4-sare-tuned --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null || echo "http://pending-tuned-service")
BASE_MODEL_URL=$(gcloud run services describe gemma-4-base --region "$REGION" --project "$PROJECT_ID" --format='value(status.url)' 2>/dev/null || echo "http://pending-base-service")

echo "=========================================================="
echo "Deploying Multi-Container Frontend Service"
echo "Project:      $PROJECT_ID"
echo "Region:       $REGION"
echo "Service:      $SERVICE_NAME"
echo "Tuned Model:  $TUNED_MODEL_NAME ($TUNED_MODEL_URL)"
echo "Base Model:   $BASE_MODEL_NAME ($BASE_MODEL_URL)"
echo "Frontend SA:  $FRONTEND_SA_EMAIL"
echo "Build SA:     $BUILD_SA_EMAIL"
echo "=========================================================="

# 1. Trigger Cloud Build for Auth Proxy and OpenWebUI images
echo "Building and tagging container images via Cloud Build..."
gcloud builds submit src/frontend/ \
    --config=src/frontend/cloudbuild.yaml \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA_EMAIL}" \
    --substitutions="_PROXY_IMAGE_URL=${PROXY_IMAGE_URL},_OPENWEBUI_IMAGE_URL=${OPENWEBUI_IMAGE_URL}" \
    --project="$PROJECT_ID"

# 2. Render declarative Knative YAML manifest from src/frontend/service.yaml
TEMP_MANIFEST="/tmp/frontend-manifest-$$.yaml"

export SERVICE_NAME VPC_NAME SUBNET_NAME FRONTEND_SA_EMAIL OPENWEBUI_IMAGE_URL PROXY_IMAGE_URL WEBUI_SECRET_KEY WEBUI_NAME TUNED_MODEL_NAME BASE_MODEL_NAME TUNED_MODEL_URL BASE_MODEL_URL

if command -v envsubst >/dev/null 2>&1; then
    envsubst < src/frontend/service.yaml > "$TEMP_MANIFEST"
else
    # Pure bash fallback if envsubst is not installed
    sed -e "s|\${SERVICE_NAME}|$SERVICE_NAME|g" \
        -e "s|\${VPC_NAME}|$VPC_NAME|g" \
        -e "s|\${SUBNET_NAME}|$SUBNET_NAME|g" \
        -e "s|\${FRONTEND_SA_EMAIL}|$FRONTEND_SA_EMAIL|g" \
        -e "s|\${OPENWEBUI_IMAGE_URL}|$OPENWEBUI_IMAGE_URL|g" \
        -e "s|\${PROXY_IMAGE_URL}|$PROXY_IMAGE_URL|g" \
        -e "s|\${WEBUI_SECRET_KEY}|$WEBUI_SECRET_KEY|g" \
        -e "s|\${WEBUI_NAME}|$WEBUI_NAME|g" \
        -e "s|\${TUNED_MODEL_NAME}|$TUNED_MODEL_NAME|g" \
        -e "s|\${BASE_MODEL_NAME}|$BASE_MODEL_NAME|g" \
        -e "s|\${TUNED_MODEL_URL}|$TUNED_MODEL_URL|g" \
        -e "s|\${BASE_MODEL_URL}|$BASE_MODEL_URL|g" \
        src/frontend/service.yaml > "$TEMP_MANIFEST"
fi

# 3. Deploy Cloud Run service using declarative replacement
echo "Applying declarative Knative manifest src/frontend/service.yaml..."
gcloud beta run services replace "$TEMP_MANIFEST" --region="$REGION" --project="$PROJECT_ID"
rm -f "$TEMP_MANIFEST"

# 4. Allow public ingress access (attempts binding, handles Enterprise Org Policies gracefully)
echo "Configuring IAM invoker permissions..."
if ! gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
    --member="allUsers" \
    --role="roles/run.invoker" \
    --region="$REGION" \
    --project="$PROJECT_ID" 2>/dev/null; then
    echo "Notice: Organization Policy (Domain Restricted Sharing) prevented public 'allUsers' binding."
    echo "Access will be secured via Load Balancer + Identity-Aware Proxy (IAP) in Phase 4."
fi

echo "=========================================================="
echo "Multi-Container Frontend Deployment Complete!"
echo "URL: $(gcloud run services describe $SERVICE_NAME --region="$REGION" --project="$PROJECT_ID" --format='value(status.url)')"
echo "=========================================================="
