#!/bin/bash
# scripts/deploy_model_service.sh
# Builds vLLM container image via Cloud Build and deploys private vLLM Cloud Run GPU model service

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
MODEL_BUCKET="${MODEL_BUCKET:-${PROJECT_ID}-models}"
VPC_NAME="${VPC_NAME:-sare-vpc}"
SUBNET_NAME="${SUBNET_NAME:-sare-subnet}"

SERVICE_NAME="${TUNED_MODEL_NAME:-gemma-4-sare-tuned}"
MODEL_NAME="${BASE_MODEL_NAME:-${MODEL_NAME:-google/gemma-4-12b-it}}"
ADAPTER_DIR="${ADAPTER_DIR:-/mnt/models/sare-agroforestry}"
GPU_TYPE="${GPU_TYPE:-nvidia-rtx-pro-6000}"

BUILD_SA_EMAIL="${BUILD_SA:-sare-build@${PROJECT_ID}.iam.gserviceaccount.com}"
BACKEND_SA_EMAIL="${BACKEND_SA:-sare-backend@${PROJECT_ID}.iam.gserviceaccount.com}"

IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_NAME}/vllm-serving:latest"

echo "=========================================================="
echo "Submitting vLLM Model Serving Build to Cloud Build"
echo "Project:      $PROJECT_ID"
echo "Region:       $REGION"
echo "Service:      $SERVICE_NAME"
echo "Model Name:   $MODEL_NAME"
echo "GPU Type:     $GPU_TYPE (1x GPU, 20 vCPUs, 80 GiB RAM)"
echo "Image:        $IMAGE_URL"
echo "Adapter Dir:  $ADAPTER_DIR"
echo "Backend SA:   $BACKEND_SA_EMAIL"
echo "Build SA:     $BUILD_SA_EMAIL"
echo "Models GCS:   gs://$MODEL_BUCKET"
echo "=========================================================="

gcloud builds submit src/serve/ \
    --config=src/serve/cloudbuild.yaml \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA_EMAIL}" \
    --substitutions="_REGION=${REGION},_IMAGE_URL=${IMAGE_URL},_SERVICE_NAME=${SERVICE_NAME},_MODELS_BUCKET_NAME=${MODEL_BUCKET},_BACKEND_SA_EMAIL=${BACKEND_SA_EMAIL},_MODEL_NAME=${MODEL_NAME},_VPC_NAME=${VPC_NAME},_SUBNET_NAME=${SUBNET_NAME},_ADAPTER_DIR=${ADAPTER_DIR},_GPU_TYPE=${GPU_TYPE}" \
    --timeout=3600s \
    --project="$PROJECT_ID"

echo "=========================================================="
echo "Private Cloud Run GPU Model Service Deployed Successfully!"
echo "Service URL: $(gcloud run services describe $SERVICE_NAME --region=$REGION --project=$PROJECT_ID --format='value(status.url)')"
echo "=========================================================="
