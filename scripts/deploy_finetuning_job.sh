#!/bin/bash
# scripts/deploy_finetuning_job.sh

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
DATA_BUCKET="${DATA_BUCKET:-${PROJECT_ID}-data}"
MODEL_BUCKET="${MODEL_BUCKET:-${PROJECT_ID}-models}"
AR_NAME="${AR_NAME:-sare-repo}"
JOB_NAME="${JOB_NAME:-lora-finetuning-job}"
MODEL_NAME="${MODEL_NAME:-google/gemma-4-12b}"
BACKEND_SA_EMAIL="${BACKEND_SA:-sare-backend@${PROJECT_ID}.iam.gserviceaccount.com}"
BUILD_SA_EMAIL="${BUILD_SA:-sare-build@${PROJECT_ID}.iam.gserviceaccount.com}"

IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_NAME}/lora-finetuning:latest"

echo "=========================================================="
echo "Submitting Fine-Tuning Job Build to Cloud Build"
echo "Project:     $PROJECT_ID"
echo "Region:      $REGION"
echo "Image:       $IMAGE_URL"
echo "Backend SA:  $BACKEND_SA_EMAIL"
echo "Build SA:    $BUILD_SA_EMAIL"
echo "Data GCS:    gs://$DATA_BUCKET"
echo "Models GCS:  gs://$MODEL_BUCKET"
echo "=========================================================="

gcloud builds submit src/finetuning/ \
    --config=src/finetuning/cloudbuild.yaml \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA_EMAIL}" \
    --substitutions="_REGION=${REGION},_IMAGE_URL=${IMAGE_URL},_JOB_NAME=${JOB_NAME},_DATA_BUCKET_NAME=${DATA_BUCKET},_MODELS_BUCKET_NAME=${MODEL_BUCKET},_BACKEND_SA_EMAIL=${BACKEND_SA_EMAIL},_MODEL_NAME=${MODEL_NAME}" \
    --project="$PROJECT_ID"

echo "=========================================================="
echo "Fine-Tuning Cloud Run GPU Job Deployed Successfully!"
echo ""
echo "Once data synthesis finishes, execute the training job with:"
echo "  gcloud beta run jobs execute $JOB_NAME --region=$REGION --project=$PROJECT_ID"
echo "=========================================================="
