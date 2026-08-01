# Use PyTorch with CUDA support as base image
FROM pytorch/pytorch:latest

# Set working directory
WORKDIR /app



# Upgrade PyTorch to CUDA 12.8 build for Blackwell (sm_120) support
RUN pip install --no-cache-dir --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128

# Copy and install python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the fine-tuning script
COPY train_lora.py .

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Arguments will be provided by Cloud Run Job configuration
ENTRYPOINT ["python", "train_lora.py"]
