#!/bin/bash
# src/serve/serve.sh

set -e

ADAPTER_DIR="${ADAPTER_DIR:-/mnt/models/sare-agroforestry}"
MODEL_PATH="${MODEL_PATH:-/app/model_cache}"
LORA_MODULE_NAME="${LORA_MODULE_NAME:-gemma-4-sare-tuned}"
PORT="${PORT:-8080}"

echo "Starting private vLLM model serving..."

if [ -f "${ADAPTER_DIR}/adapter_config.json" ]; then
    echo "Fine-tuned LoRA adapter found in ${ADAPTER_DIR}."
    echo "Starting vLLM with base model and LoRA adapter module: ${LORA_MODULE_NAME}..."
    
    # Run vLLM OpenAI API Server with LoRA and Tool Choice enabled
    exec vllm serve "$MODEL_PATH" \
        --enable-lora \
        --lora-modules "${LORA_MODULE_NAME}=${ADAPTER_DIR}" \
        --gpu-memory-utilization 0.90 \
        --max-model-len 8192 \
        --trust-remote-code \
        --enable-auto-tool-choice \
        --tool-call-parser pythonic \
        --port "$PORT" \
        --host 0.0.0.0
else
    echo "No fine-tuned adapter found in ${ADAPTER_DIR} (missing adapter_config.json)."
    echo "Starting vLLM with base model only..."
    
    # Run vLLM OpenAI API Server with base model only
    exec vllm serve "$MODEL_PATH" \
        --gpu-memory-utilization 0.90 \
        --max-model-len 8192 \
        --trust-remote-code \
        --enable-auto-tool-choice \
        --tool-call-parser pythonic \
        --port "$PORT" \
        --host 0.0.0.0
fi
