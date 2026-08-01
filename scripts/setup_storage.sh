#!/bin/bash
# scripts/setup_storage.sh

set -e

if [ -f .env ]; then
    source .env
fi

# Fallback PROJECT_ID to gcloud config if unset or equal to placeholder
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "your-project-id" ] || [ "$PROJECT_ID" = "serverless-llm-and-agents-demo" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
fi

if [ -z "$PROJECT_ID" ]; then
    echo "Error: PROJECT_ID is not set in .env and could not be retrieved from gcloud config." >&2
    exit 1
fi

# Set defaults for Region, Buckets, Artifact Registry, and Service Accounts
REGION="${REGION:-us-central1}"
DATA_BUCKET="${DATA_BUCKET:-${PROJECT_ID}-data}"
MODEL_BUCKET="${MODEL_BUCKET:-${PROJECT_ID}-models}"
AR_NAME="${AR_NAME:-sare-repo}"

SYNTH_SA_EMAIL="${SYNTH_SA:-sare-synth@${PROJECT_ID}.iam.gserviceaccount.com}"
BACKEND_SA_EMAIL="${BACKEND_SA:-sare-backend@${PROJECT_ID}.iam.gserviceaccount.com}"
BUILD_SA_EMAIL="${BUILD_SA:-sare-build@${PROJECT_ID}.iam.gserviceaccount.com}"

echo "=========================================================="
echo "Setting up Storage & Infrastructure Baseline for Project: $PROJECT_ID"
echo "=========================================================="

# 1. Enable Storage, Artifact Registry, and Secret Manager APIs
echo "Step 1: Enabling Storage, Artifact Registry, and Secret Manager APIs..."
gcloud services enable storage.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet

# 2. Create Data GCS Bucket (PDFs & Training JSONL)
if ! gcloud storage buckets describe "gs://$DATA_BUCKET" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "Step 2a: Creating Data GCS bucket: gs://$DATA_BUCKET..."
    gcloud storage buckets create "gs://$DATA_BUCKET" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --uniform-bucket-level-access \
        --quiet
else
    echo "Step 2a: Data bucket gs://$DATA_BUCKET already exists."
fi

# 3. Create Models GCS Bucket (LoRA Adapters & Base Weights)
if ! gcloud storage buckets describe "gs://$MODEL_BUCKET" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "Step 2b: Creating Models GCS bucket: gs://$MODEL_BUCKET..."
    gcloud storage buckets create "gs://$MODEL_BUCKET" \
        --project="$PROJECT_ID" \
        --location="$REGION" \
        --uniform-bucket-level-access \
        --quiet
else
    echo "Step 2b: Models bucket gs://$MODEL_BUCKET already exists."
fi

# 4. Create Artifact Registry Repository
if ! gcloud artifacts repositories describe "$AR_NAME" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "Step 3: Creating Artifact Registry repository: $AR_NAME..."
    gcloud artifacts repositories create "$AR_NAME" \
        --repository-format=docker \
        --location="$REGION" \
        --project="$PROJECT_ID" \
        --description="Docker repository for serverless LLM synthesis, fine-tuning, and serving" \
        --quiet
else
    echo "Step 3: Artifact Registry repository $AR_NAME already exists."
fi

# 5. Create Secret Manager secret for Hugging Face Token
if [ -n "$HF_TOKEN" ] && [ "$HF_TOKEN" != "your-huggingface-token" ]; then
    echo "Step 4: Configuring Secret Manager secret HF_TOKEN..."
    if ! gcloud secrets describe HF_TOKEN --project="$PROJECT_ID" >/dev/null 2>&1; then
        echo "  - Creating secret HF_TOKEN..."
        gcloud secrets create HF_TOKEN \
            --replication-policy="automatic" \
            --project="$PROJECT_ID" \
            --quiet
        
        echo -n "$HF_TOKEN" | gcloud secrets versions add HF_TOKEN \
            --data-file=- \
            --project="$PROJECT_ID" \
            --quiet
    else
        echo "  - Secret HF_TOKEN already exists."
    fi

    # Grant Secret Accessor to Backend SA and Build SA
    echo "  - Granting Secret Accessor permission on HF_TOKEN to Backend SA and Build SA..."
    gcloud secrets add-iam-policy-binding HF_TOKEN \
        --member="serviceAccount:$BACKEND_SA_EMAIL" \
        --role="roles/secretmanager.secretAccessor" \
        --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true

    gcloud secrets add-iam-policy-binding HF_TOKEN \
        --member="serviceAccount:$BUILD_SA_EMAIL" \
        --role="roles/secretmanager.secretAccessor" \
        --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
else
    echo "Step 4: Warning: HF_TOKEN is not set or using placeholder in .env. Skipping secret creation."
fi

# 6. Grant bucket-level least privilege permissions
echo "Step 5: Granting bucket-level IAM permissions to Service Accounts..."
echo "  - Granting Data Bucket Object Admin to $SYNTH_SA_EMAIL..."
gcloud storage buckets add-iam-policy-binding "gs://$DATA_BUCKET" \
    --member="serviceAccount:$SYNTH_SA_EMAIL" \
    --role="roles/storage.objectAdmin" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true

echo "  - Granting Data Bucket Object Viewer to $BACKEND_SA_EMAIL..."
gcloud storage buckets add-iam-policy-binding "gs://$DATA_BUCKET" \
    --member="serviceAccount:$BACKEND_SA_EMAIL" \
    --role="roles/storage.objectViewer" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true

echo "  - Granting Models Bucket Object Admin to $BACKEND_SA_EMAIL..."
gcloud storage buckets add-iam-policy-binding "gs://$MODEL_BUCKET" \
    --member="serviceAccount:$BACKEND_SA_EMAIL" \
    --role="roles/storage.objectAdmin" --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true

echo "=========================================================="
echo "Storage Setup Complete!"
echo "Data Bucket:   gs://$DATA_BUCKET"
echo "Models Bucket: gs://$MODEL_BUCKET"
echo "Docker Repo:   $REGION-docker.pkg.dev/$PROJECT_ID/$AR_NAME"
if [ -n "$HF_TOKEN" ] && [ "$HF_TOKEN" != "your-huggingface-token" ]; then
echo "Secret:        HF_TOKEN (configured & granted)"
fi
echo "=========================================================="
