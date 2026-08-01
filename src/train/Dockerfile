# Use Python 3.12 slim as base image
FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the generation script and config
COPY generate_dataset.py .
COPY config.json .

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Arguments will be provided by the Cloud Run Job configuration
ENTRYPOINT ["python", "generate_dataset.py"]
