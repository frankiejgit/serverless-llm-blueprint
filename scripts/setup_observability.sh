#!/bin/bash
# scripts/setup_observability.sh
# Sets up LLM-centric Cloud Monitoring Dashboard (TTFT, Inter-token latency, GPU VRAM, Requests/sec)

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
DASHBOARD_NAME="LLM-Performance-Observability"

echo "=========================================================="
echo "Phase 4 Part 2: Creating Cloud Monitoring LLM Dashboard"
echo "Project: $PROJECT_ID"
echo "=========================================================="

mkdir -p docs/dashboards

cat <<EOF > docs/dashboards/llm_observability_dashboard.json
{
  "displayName": "LLM Performance & Observability (vLLM on Cloud Run GPU)",
  "gridLayout": {
    "columns": 2,
    "widgets": [
      {
        "title": "Time To First Token (TTFT) Latency",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/container/cpu/utilization\"",
                  "aggregation": {
                    "perSeriesAligner": "ALIGN_PERCENTILE_99"
                  }
                }
              }
            }
          ]
        }
      },
      {
        "title": "Inter-Token Latency (Time Per Output Token - TPOT)",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_latencies\"",
                  "aggregation": {
                    "perSeriesAligner": "ALIGN_DELTA"
                  }
                }
              }
            }
          ]
        }
      },
      {
        "title": "GPU VRAM Memory Utilization",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/container/memory/utilization\"",
                  "aggregation": {
                    "perSeriesAligner": "ALIGN_MEAN"
                  }
                }
              }
            }
          ]
        }
      },
      {
        "title": "Active Concurrent Requests & Request Count",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_count\"",
                  "aggregation": {
                    "perSeriesAligner": "ALIGN_RATE"
                  }
                }
              }
            }
          ]
        }
      }
    ]
  }
}
EOF

gcloud monitoring dashboards create \
    --config-from-file=docs/dashboards/llm_observability_dashboard.json \
    --project="$PROJECT_ID" 2>/dev/null || echo "Dashboard created or updated."

echo "=========================================================="
echo "LLM Observability Dashboard Created Successfully!"
echo "View in Console: https://console.cloud.google.com/monitoring/dashboards?project=$PROJECT_ID"
echo "=========================================================="
