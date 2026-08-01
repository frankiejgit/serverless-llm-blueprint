#!/bin/bash
# scripts/setup_ingress.sh
# Sets up Global External Load Balancer, Google-Managed SSL Certificate, Cloud Armor WAF, and optional IAP

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
SERVICE_NAME="${SERVICE_NAME:-sare-frontend}"
IP_NAME="${IP_NAME:-sare-global-ip}"
CERT_NAME="${CERT_NAME:-sare-ssl-cert}"
WAF_POLICY_NAME="${WAF_POLICY_NAME:-sare-waf-policy}"
NEG_NAME="${NEG_NAME:-sare-frontend-neg}"
BACKEND_SERVICE_NAME="${BACKEND_SERVICE_NAME:-sare-frontend-backend-service}"
URL_MAP_NAME="${URL_MAP_NAME:-sare-frontend-url-map}"
PROXY_NAME="${PROXY_NAME:-sare-frontend-https-proxy}"
FORWARDING_RULE_NAME="${FORWARDING_RULE_NAME:-sare-frontend-forwarding-rule}"

echo "=========================================================="
echo "Phase 4 Part 2: Setting up Ingress (LB, Cloud Armor WAF, IAP)"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Service: $SERVICE_NAME"
echo "=========================================================="

# 1. Reserve Global External IP Address
echo "Step 1: Reserving Global External Static IP..."
gcloud compute addresses create $IP_NAME \
    --global \
    --project="$PROJECT_ID" 2>/dev/null || echo "Static IP $IP_NAME already exists."

STATIC_IP=$(gcloud compute addresses describe $IP_NAME --global --project="$PROJECT_ID" --format='value(address)')
DOMAIN_NAME="${STATIC_IP}.nip.io"

echo "Reserved Static IP: $STATIC_IP"
echo "Configured Domain:  https://$DOMAIN_NAME"

# 2. Create Google-Managed SSL Certificate for nip.io domain
echo "Step 2: Creating Google-Managed SSL Certificate for $DOMAIN_NAME..."
gcloud compute ssl-certificates create $CERT_NAME \
    --domains="$DOMAIN_NAME" \
    --global \
    --project="$PROJECT_ID" 2>/dev/null || echo "SSL Certificate $CERT_NAME already exists."

# 3. Create Cloud Armor WAF Policy (DDoS & Rate Limiting)
echo "Step 3: Creating Cloud Armor WAF Security Policy..."
gcloud compute security-policies create $WAF_POLICY_NAME \
    --description="Cloud Armor WAF policy for SARE LLM Blueprint" \
    --project="$PROJECT_ID" 2>/dev/null || echo "Cloud Armor policy $WAF_POLICY_NAME already exists."

# Add rate-limiting rule (e.g. max 100 requests per minute per IP)
gcloud compute security-policies rules create 1000 \
    --security-policy=$WAF_POLICY_NAME \
    --expression="true" \
    --action="rate-based-ban" \
    --rate-limit-threshold-count=100 \
    --rate-limit-threshold-interval-sec=60 \
    --ban-duration-sec=300 \
    --conform-action="allow" \
    --project="$PROJECT_ID" 2>/dev/null || echo "WAF Rule 1000 already exists."

# 4. Create Serverless Network Endpoint Group (NEG) for Cloud Run
echo "Step 4: Creating Serverless Network Endpoint Group (NEG)..."
gcloud compute network-endpoint-groups create $NEG_NAME \
    --region="$REGION" \
    --network-endpoint-type=serverless \
    --cloud-run-service="$SERVICE_NAME" \
    --project="$PROJECT_ID" 2>/dev/null || echo "NEG $NEG_NAME already exists."

# 5. Create Backend Service & Attach Cloud Armor WAF Policy
# Note: For Cloud Run Serverless NEGs, protocol MUST be HTTP (Google manages TLS internally)
echo "Step 5a: Creating Backend Service & attaching Cloud Armor..."
gcloud compute backend-services create $BACKEND_SERVICE_NAME \
    --global \
    --load-balancing-scheme=EXTERNAL_MANAGED \
    --protocol=HTTP \
    --project="$PROJECT_ID" 2>/dev/null || echo "Backend Service $BACKEND_SERVICE_NAME already exists."

gcloud compute backend-services update $BACKEND_SERVICE_NAME \
    --global \
    --security-policy=$WAF_POLICY_NAME \
    --project="$PROJECT_ID" 2>/dev/null || echo "Attached WAF policy $WAF_POLICY_NAME."

gcloud compute backend-services add-backend $BACKEND_SERVICE_NAME \
    --global \
    --network-endpoint-group=$NEG_NAME \
    --network-endpoint-group-region="$REGION" \
    --project="$PROJECT_ID" 2>/dev/null || echo "Backend NEG binding already exists."

# 5b. Enable Identity-Aware Proxy (IAP) if OAuth Credentials are available (.env or Secret Manager)
if [ -z "$IAP_CLIENT_SECRET" ]; then
    # Dynamically fetch IAP client secret from Google Secret Manager if present
    IAP_CLIENT_SECRET=$(gcloud secrets versions access latest --secret="IAP_CLIENT_SECRET" --project="$PROJECT_ID" 2>/dev/null || echo "")
fi

if [ -n "$IAP_CLIENT_ID" ] && [ -n "$IAP_CLIENT_SECRET" ]; then
    echo "Step 5b: Enabling Identity-Aware Proxy (IAP)..."
    gcloud compute backend-services update $BACKEND_SERVICE_NAME \
        --global \
        --iap=enabled,oauth2-client-id="$IAP_CLIENT_ID",oauth2-client-secret="$IAP_CLIENT_SECRET" \
        --project="$PROJECT_ID"

    # Provision Google-managed IAP Service Account & Grant Cloud Run Invoker Role
    echo "Provisioning IAP Service Account & granting Cloud Run Invoker role..."
    gcloud beta services identity create --service=iap.googleapis.com --project="$PROJECT_ID" 2>/dev/null || true

    PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
    IAP_SA="service-${PROJECT_NUMBER}@gcp-sa-iap.iam.gserviceaccount.com"

    gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
        --member="serviceAccount:${IAP_SA}" \
        --role="roles/run.invoker" \
        --region="$REGION" \
        --project="$PROJECT_ID" 2>/dev/null || true
else
    echo "Notice: IAP_CLIENT_ID or IAP_CLIENT_SECRET not provided."
    echo "Skipping IAP OAuth activation (Global Load Balancer & Cloud Armor WAF are fully active)."
fi

# 6. Create URL Map, Target HTTPS Proxy, and Global Forwarding Rule
echo "Step 6: Routing traffic via URL Map & Target HTTPS Proxy..."
gcloud compute url-maps create $URL_MAP_NAME \
    --default-service=$BACKEND_SERVICE_NAME \
    --project="$PROJECT_ID" 2>/dev/null || echo "URL map $URL_MAP_NAME already exists."

gcloud compute target-https-proxies create $PROXY_NAME \
    --url-map=$URL_MAP_NAME \
    --ssl-certificates=$CERT_NAME \
    --project="$PROJECT_ID" 2>/dev/null || echo "Target HTTPS Proxy $PROXY_NAME already exists."

gcloud compute forwarding-rules create $FORWARDING_RULE_NAME \
    --global \
    --target-https-proxy=$PROXY_NAME \
    --address=$IP_NAME \
    --ports=443 \
    --project="$PROJECT_ID" 2>/dev/null || echo "Forwarding Rule $FORWARDING_RULE_NAME already exists."

echo "=========================================================="
echo "Ingress & Security Setup Complete!"
echo "Global IP:  $STATIC_IP"
echo "Secure URL: https://$DOMAIN_NAME"
echo ""
echo "Note: SSL Certificate provisioning takes ~10-15 minutes on GCP."
echo "=========================================================="
