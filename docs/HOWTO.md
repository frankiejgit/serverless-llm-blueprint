# Serverless LLM Blueprint: Step-by-Step Developer Guide (HOWTO)

This guide provides step-by-step instructions for deploying the Serverless LLM Blueprint in your Google Cloud environment.

---

## Phase 1: Security & Identity Setup (IAM)

### Step 1: Configure Environment Variables

Create your `.env` file from the provided template:

```bash
cp .env.example .env
```

Ensure `.env` defines your project ID, region, and 4 dedicated service accounts:

```bash
PROJECT_ID="your-gcp-project-id"
REGION="us-central1"
DATA_BUCKET="${PROJECT_ID}-data"
MODEL_BUCKET="${PROJECT_ID}-models"
AR_NAME="sare-repo"
VPC_NAME="sare-vpc"
SUBNET_NAME="sare-subnet"

# Dedicated Service Accounts
BUILD_SA="sare-build@${PROJECT_ID}.iam.gserviceaccount.com"
SYNTH_SA="sare-synth@${PROJECT_ID}.iam.gserviceaccount.com"
BACKEND_SA="sare-backend@${PROJECT_ID}.iam.gserviceaccount.com"
FRONTEND_SA="sare-frontend@${PROJECT_ID}.iam.gserviceaccount.com"
```

---

### Step 2: Run the IAM Setup Script

Execute the IAM setup script to enable core APIs, create the 4 service accounts, and grant least-privilege permissions:

```bash
chmod +x scripts/setup_iam.sh
./scripts/setup_iam.sh
```

#### What `scripts/setup_iam.sh` Does:
1. Enables required Google Cloud APIs (`iam`, `cloudbuild`, `run`, `artifactregistry`, `secretmanager`, `aiplatform`, `monitoring`).
2. Provisions 4 dedicated Service Accounts:
   - `sare-build`: Container builds and Cloud Run service management.
   - `sare-synth`: Gemini API access and data bucket access for PDF dataset synthesis.
   - `sare-backend`: Storage access for model weights/adapters and metric writing for vLLM GPU inference.
   - `sare-frontend`: Runtime invoker rights to call private backend model services.
3. Grants `roles/iam.serviceAccountUser` allowing Cloud Build (`sare-build`) to deploy services under execution identities.

---

## Phase 2: Core Infrastructure Setup (Storage, Registry, Secrets & VPC Network)

### Step 1: Execute Storage Setup Script

Execute `scripts/setup_storage.sh` to provision storage buckets, Docker container registries, and secrets:

```bash
chmod +x scripts/setup_storage.sh
./scripts/setup_storage.sh
```

#### What `scripts/setup_storage.sh` Does:
1. Enables `storage.googleapis.com`, `artifactregistry.googleapis.com`, and `secretmanager.googleapis.com` APIs.
2. Provisions **Dual GCS Buckets**:
   - `gs://$DATA_BUCKET` (`gs://<project-id>-data`): Storage for raw PDFs and generated JSONL datasets.
   - `gs://$MODEL_BUCKET` (`gs://<project-id>-models`): Storage for base Gemma model weights and fine-tuned LoRA adapters.
3. Provisions **Artifact Registry Repository**:
   - `$AR_NAME` (`sare-repo`): Regional Docker container repository for build images.
4. Provisions **Secret Manager Credentials**:
   - `HF_TOKEN`: Hugging Face access token secret, with `roles/secretmanager.secretAccessor` granted to `sare-backend` and `sare-build`.
5. Binds **Bucket-Level IAM Policies**:
   - `sare-synth`: `roles/storage.objectAdmin` on `gs://$DATA_BUCKET`.
   - `sare-backend`: `roles/storage.objectViewer` on `gs://$DATA_BUCKET` & `roles/storage.objectAdmin` on `gs://$MODEL_BUCKET`.

---

### Step 2: Execute VPC Networking Setup Script

Execute `scripts/setup_network.sh` to provision the custom VPC network and subnet:

```bash
chmod +x scripts/setup_network.sh
./scripts/setup_network.sh
```

#### What `scripts/setup_network.sh` Does:
1. Enables `compute.googleapis.com` API.
2. Provisions **Custom VPC Network**: `$VPC_NAME` (`sare-vpc`).
3. Provisions **Subnet with Private Google Access**: `$SUBNET_NAME` (`sare-subnet`, `10.0.0.0/24`) with `--enable-private-ip-google-access` enabled for Direct VPC Egress.

---

### Step 3: Upload Source PDF Documents

Upload your source domain PDF files to the data bucket under `pdf/`:

```bash
source .env
gcloud storage cp data/*.pdf gs://$DATA_BUCKET/pdf/
```

---

## Phase 3: Data Synthesis & Fine-Tuning Execution

### Step 1: Deploy & Execute Data Synthesis Job

Deploy and execute the data synthesis Cloud Run Job (`jsonl-data-generator`):

```bash
chmod +x scripts/deploy_synthesis_job.sh
./scripts/deploy_synthesis_job.sh

# Trigger job dynamically (1 task per PDF)
source .env
PDF_COUNT=$(gcloud storage ls "gs://${DATA_BUCKET}/pdf/*.pdf" 2>/dev/null | grep -c '\.pdf$' || echo 1)
gcloud run jobs execute jsonl-data-generator --tasks=$PDF_COUNT --region=$REGION --project=$PROJECT_ID
```

#### What `scripts/deploy_synthesis_job.sh` Does:
1. Triggers Cloud Build using `src/train/cloudbuild.yaml` running under `sare-build` service account credentials.
2. Builds the `data-generator:latest` Docker image and pushes it to Artifact Registry (`$AR_NAME`).
3. Deploys the Cloud Run Job `jsonl-data-generator` configured with `--memory=4Gi` and `--cpu=2` under `sare-synth` identity.

---

### Step 2: Deploy & Execute QLoRA Fine-Tuning GPU Job

Deploy and execute the QLoRA Fine-Tuning GPU Job (`lora-finetuning-job`):

```bash
chmod +x scripts/deploy_finetuning_job.sh
./scripts/deploy_finetuning_job.sh

# Execute QLoRA Fine-Tuning on Cloud Run GPU
gcloud beta run jobs execute lora-finetuning-job --region=$REGION --project=$PROJECT_ID
```

#### What `scripts/deploy_finetuning_job.sh` Does:
1. Triggers Cloud Build using `src/finetuning/cloudbuild.yaml` running under `sare-build` service account credentials.
2. Builds PyTorch CUDA 12.8 `lora-finetuning:latest` Docker image.
3. Deploys Cloud Run GPU Job `lora-finetuning-job` configured with 1x GPU (`nvidia-rtx-pro-6000`), 20 vCPUs, 80 GiB RAM, and dual GCS FUSE volume mounts (`/mnt/data` and `/mnt/models`).

---

## Phase 4: Serving, Frontend, Ingress & LLM Observability Setup

### Step 1: Deploy Private vLLM Cloud Run GPU Model Service

```bash
chmod +x scripts/deploy_model_service.sh
./scripts/deploy_model_service.sh
```

#### What `scripts/deploy_model_service.sh` Does:
1. Triggers Cloud Build using `src/serve/cloudbuild.yaml` (configured with `E2_HIGHCPU_32` and `500GB SSD` build acceleration) under `sare-build` service account credentials.
2. Builds the PyTorch + vLLM `vllm-serving:latest` Docker image and pushes it to Artifact Registry (`$AR_NAME`).
3. Deploys the private Cloud Run GPU service `gemma-4-sare-tuned` configured with:
   - Service Account: `sare-backend` (`sare-backend@$PROJECT_ID.iam.gserviceaccount.com`).
   - Hardware Specifications: 1x GPU (`nvidia-rtx-pro-6000`), 20 vCPUs, 80 GiB RAM.
   - GCS FUSE Volume Mount: Maps `gs://$MODEL_BUCKET` to `/mnt/models`.
   - Network Security: Enforces IAM OIDC Authentication (`--no-allow-unauthenticated`), attached to `sare-vpc` via `sare-subnet` (Direct VPC Egress).
   - Dynamic LoRA Adapter Resolution: Checks `/mnt/models/sare-agroforestry/adapter_config.json`; if present, enables vLLM Multi-LoRA (`--enable-lora`).

---

### Step 2: Deploy Multi-Container Frontend Service

```bash
chmod +x scripts/deploy_frontend.sh
./scripts/deploy_frontend.sh
```

#### What `scripts/deploy_frontend.sh` Does:
1. **Cloud Build Image Pipeline**:
   - Builds `sare-auth-proxy:latest` from `src/frontend/auth-proxy/` and pushes it to Artifact Registry (`$AR_NAME`).
   - Pulls official `ghcr.io/open-webui/open-webui:main` image and re-tags it into Artifact Registry (`$AR_NAME/open-webui:main`).
2. **Declarative Knative Multi-Container Manifest Deployment (`src/frontend/service.yaml`)**:
   - Renders `src/frontend/service.yaml` with environment variables (`SERVICE_NAME`, `VPC_NAME`, `SUBNET_NAME`, `FRONTEND_SA_EMAIL`, `TUNED_MODEL_NAME`, `BASE_MODEL_NAME`, `TUNED_MODEL_URL`, `BASE_MODEL_URL`).
   - Applies the manifest declaratively via `gcloud beta run services replace`.
3. **Direct VPC Egress Network Attachment**:
   - Attaches `sare-vpc` and `sare-subnet` via Knative annotations (`run.googleapis.com/network-interfaces`), setting `vpc-access-egress: private-ranges-only` to route internal database and backend microservice calls over `sare-vpc`.
4. **Service Identity**:
   - Binds `sare-frontend` Service Account identity (`sare-frontend@$PROJECT_ID.iam.gserviceaccount.com`).
5. **Universal Ingress IAM Policy Handling**:
   - Attempts `allUsers` binding for sandbox/personal GCP projects; gracefully detects Google Organization Policy (Domain Restricted Sharing) in enterprise environments and logs an informational notice without script failure.

---

### Step 3: Provision Global Load Balancer, SSL Certificate & Cloud Armor WAF

Execute `scripts/setup_ingress.sh` to secure the frontend endpoint:

```bash
chmod +x scripts/setup_ingress.sh
./scripts/setup_ingress.sh
```

#### What `scripts/setup_ingress.sh` Does:
1. Reserves a Global External Static IP (`sare-global-ip`).
2. Generates a Google-Managed SSL Certificate for `${STATIC_IP}.nip.io`.
3. Provisions Cloud Armor WAF Security Policy (`sare-waf-policy`) with rate-limiting ban rules (max 100 req/min per IP).
4. Creates Serverless Network Endpoint Group (NEG) (`sare-frontend-neg`) pointing to `sare-frontend`.
5. Creates Backend Service (`sare-frontend-backend-service`) with `--load-balancing-scheme=EXTERNAL_MANAGED` and `--protocol=HTTP`, binds Cloud Armor policy, and attaches Serverless NEG.
6. Provisions Target HTTPS Proxy (`sare-frontend-https-proxy`) and Global Forwarding Rule (Port 443).

---

### Step 4: Enabling Zero-Trust IAP Authentication (Optional Step)

To enable **Identity-Aware Proxy (IAP)** and restrict access to authorized Google accounts:

1. **Initialize OAuth Consent Screen (If First Time in Project)**:
   - Go to **[GCP Console $\rightarrow$ APIs & Services $\rightarrow$ OAuth consent screen](https://console.cloud.google.com/apis/credentials/consent)**.
   - Select **Internal** (Workspace) or **External**, enter App Name (`SARE Blueprint`) and User/Developer Email, then click **SAVE AND CONTINUE** through default steps.
2. **Create OAuth 2.0 Credentials**:
   - Go to **[GCP Console $\rightarrow$ APIs & Services $\rightarrow$ Credentials](https://console.cloud.google.com/apis/credentials)**.
   - Click **+ CREATE CREDENTIALS $\rightarrow$ OAuth client ID** (Application type: **Web application**).
   - Under **Authorized redirect URIs**, add:
     `https://iap.googleapis.com/v1/oauth/clientIds/YOUR_CLIENT_ID.apps.googleusercontent.com:handleRedirect`
3. **Add Credentials to `.env` (or Secret Manager)**:
   ```bash
   IAP_CLIENT_ID="your-client-id.apps.googleusercontent.com"
   IAP_CLIENT_SECRET="your-client-secret"
   ```
4. **Re-run Ingress Setup Script**:
   ```bash
   ./scripts/setup_ingress.sh
   ```
   *Note: `setup_ingress.sh` automatically creates the Google-managed IAP Service Account (`service-<PROJECT_NUMBER>@gcp-sa-iap.iam.gserviceaccount.com`) and grants it `roles/run.invoker` on the Cloud Run frontend service.*
5. **Grant Access to Authorized Users / Teams**:
   - **Via GCP Console (Recommended)**:
     1. Go to **[GCP Console $\rightarrow$ Security $\rightarrow$ Identity-Aware Proxy](https://console.cloud.google.com/security/iap)**.
     2. Check the box next to **`sare-frontend-backend-service`**.
     3. Click **ADD PRINCIPAL** in the right panel.
     4. Enter user/group emails and select Role **IAP-secured Web App User** (`roles/iap.httpsResourceAccessor`). Click **SAVE**.
   - **Via gcloud CLI**:
     ```bash
     source .env
     gcloud compute backend-services add-iam-policy-binding sare-frontend-backend-service \
         --member="user:your-email@company.com" \
         --role="roles/iap.httpsResourceAccessor" \
         --global \
         --project=$PROJECT_ID
     ```

---

### Step 5: Provision Cloud Monitoring LLM Observability Dashboard

Execute `scripts/setup_observability.sh` to generate the real-time LLM monitoring dashboard:

```bash
chmod +x scripts/setup_observability.sh
./scripts/setup_observability.sh
```

#### What `scripts/setup_observability.sh` Does:
1. Generates `docs/dashboards/llm_observability_dashboard.json` dashboard configuration.
2. Provisions a custom Cloud Monitoring dashboard (`LLM Performance & Observability`) tracking:
   - **Time To First Token (TTFT)** 99th percentile latency.
   - **Inter-Token Latency (TPOT)** per output token.
   - **GPU VRAM Utilization** & memory pressure.
   - **Active Concurrent Requests & Request Rate (QPS)**.

---

### Step 6: Verification

Access your secure domain:

```bash
echo "https://$(gcloud compute addresses describe sare-global-ip --global --format='value(address)').nip.io"
```
