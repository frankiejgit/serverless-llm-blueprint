# Use official vLLM OpenAI compatible server image
FROM vllm/vllm-openai:latest

# Set working directory
WORKDIR /app

# Install huggingface_hub to use huggingface-cli
RUN pip install --no-cache-dir huggingface_hub

# Accept Hugging Face Token and Model ID as build arguments
ARG HF_TOKEN
ARG MODEL_ID=google/gemma-4-12b-it

# Download and bake the base model weights into the container image
# This avoids downloading the heavy model files during container startup.
RUN if [ -z "$HF_TOKEN" ]; then \
        echo "Error: HF_TOKEN build argument is required to download gated models." && exit 1; \
    fi && \
    hf download $MODEL_ID \
        --local-dir /app/model_cache \
        --token $HF_TOKEN \
        --exclude "*.git*" \
        --exclude "*.md"

# Copy the serving startup wrapper script
COPY serve.sh /app/serve.sh
RUN chmod +x /app/serve.sh

# Expose port
EXPOSE 8080

# Execute startup script
ENTRYPOINT ["/bin/bash", "/app/serve.sh"]
