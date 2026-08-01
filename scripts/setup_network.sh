#!/bin/bash
# scripts/setup_network.sh

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

# Set defaults for Region, VPC, Subnet, and CIDR range
REGION="${REGION:-us-central1}"
VPC_NAME="${VPC_NAME:-sare-vpc}"
SUBNET_NAME="${SUBNET_NAME:-sare-subnet}"
SUBNET_RANGE="${SUBNET_RANGE:-10.0.0.0/24}"

echo "=========================================================="
echo "Setting up Core VPC Network Baseline for Project: $PROJECT_ID"
echo "=========================================================="

# 1. Enable Compute Engine API
echo "Step 1: Enabling Compute Engine API..."
gcloud services enable compute.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet

# 2. Create Custom VPC Network
if ! gcloud compute networks describe "$VPC_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "Step 2: Creating Custom VPC Network: $VPC_NAME..."
    gcloud compute networks create "$VPC_NAME" \
        --subnet-mode=custom \
        --project="$PROJECT_ID" \
        --quiet
else
    echo "Step 2: VPC Network $VPC_NAME already exists."
fi

# 3. Create Subnet with Private Google Access
if ! gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "Step 3: Creating Subnet $SUBNET_NAME ($SUBNET_RANGE) with Private Google Access in $REGION..."
    gcloud compute networks subnets create "$SUBNET_NAME" \
        --network="$VPC_NAME" \
        --region="$REGION" \
        --range="$SUBNET_RANGE" \
        --enable-private-ip-google-access \
        --project="$PROJECT_ID" \
        --quiet
else
    echo "Step 3: Subnet $SUBNET_NAME already exists in region $REGION."
fi

echo "=========================================================="
echo "Networking Setup Complete!"
echo "VPC Network: $VPC_NAME"
echo "Subnet:      $SUBNET_NAME ($SUBNET_RANGE in $REGION)"
echo "Features:    Private Google Access Enabled (Ready for Direct VPC Egress)"
echo "=========================================================="
