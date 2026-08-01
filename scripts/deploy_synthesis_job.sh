#!/bin/bash
# scripts/deploy_synthesis_job.sh

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
AR_NAME="${AR_NAME:-sare-repo}"
JOB_NAME="${JOB_NAME:-jsonl-data-generator}"
SYNTH_SA_EMAIL="${SYNTH_SA:-sare-synth@${PROJECT_ID}.iam.gserviceaccount.com}"
BUILD_SA_EMAIL="${BUILD_SA:-sare-build@${PROJECT_ID}.iam.gserviceaccount.com}"

IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_NAME}/data-generator:latest"

echo "=========================================================="
echo "Submitting Data Synthesis Job Build to Cloud Build"
echo "Project:   $PROJECT_ID"
echo "Region:    $REGION"
echo "Image:     $IMAGE_URL"
echo "Data SA:   $SYNTH_SA_EMAIL"
echo "Build SA:  $BUILD_SA_EMAIL"
echo "Data GCS:  gs://$DATA_BUCKET"
echo "=========================================================="

gcloud builds submit src/train/ \
    --config=src/train/cloudbuild.yaml \
    --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA_EMAIL}" \
    --substitutions="_REGION=${REGION},_IMAGE_URL=${IMAGE_URL},_JOB_NAME=${JOB_NAME},_BUCKET_NAME=${DATA_BUCKET},_SYNTH_SA_EMAIL=${SYNTH_SA_EMAIL}" \
    --project="$PROJECT_ID"

# Calculate current PDF count in GCS bucket to suggest dynamic execution command
PDF_COUNT=$(gcloud storage ls "gs://${DATA_BUCKET}/pdf/*.pdf" 2>/dev/null | grep -c '\.pdf$' || echo 1)

echo "=========================================================="
echo "Data Synthesis Cloud Run Job Deployed Successfully!"
echo ""
echo "To execute the job dynamically based on the $PDF_COUNT PDF(s) in your GCS bucket, run:"
echo ""
echo "  PDF_COUNT=\$(gcloud storage ls \"gs://${DATA_BUCKET}/pdf/*.pdf\" 2>/dev/null | grep -c '\.pdf$' || echo 1)"
echo "  gcloud run jobs execute $JOB_NAME --tasks=\$PDF_COUNT --region=$REGION --project=$PROJECT_ID"
echo "=========================================================="
