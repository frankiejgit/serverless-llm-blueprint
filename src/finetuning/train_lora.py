import argparse
import glob
import logging
import os
import time
from typing import Dict, List

import torch
from datasets import load_dataset
from google.cloud import run_v2
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
    TrainingArguments,
)
from trl import SFTConfig, SFTTrainer

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def trigger_cloud_run_redeployment(project_id: str, region: str, service_name: str):
    """Triggers a redeployment of a Cloud Run service by updating a template annotation."""
    logger.info(f"Connecting to Cloud Run API to trigger redeployment of {service_name}...")
    try:
        client = run_v2.ServicesClient()
        service_path = client.service_path(project_id, region, service_name)
        
        # Get current service configuration
        service = client.get_service(name=service_path)
        
        # Update template metadata annotations to force a new revision deployment
        if not service.template.annotations:
            service.template.annotations = {}
            
        # Standard annotation used to track/trigger redeployments
        service.template.annotations["client.knative.dev/user-image"] = f"redeploy-trigger-{int(time.time())}"
        
        # Specify update mask
        update_mask = {"paths": ["template.annotations"]}
        
        logger.info(f"Updating service configuration for {service_name}...")
        operation = client.update_service(service=service, update_mask=update_mask)
        
        logger.info("Waiting for Cloud Run deployment operation to complete...")
        operation.result(timeout=300)
        logger.info(f"Successfully triggered redeployment of {service_name}!")
        
    except Exception as e:
        logger.error(f"Failed to trigger Cloud Run redeployment: {e}")
        # We don't want to crash the whole script if redeploy fails (e.g. permission issues),
        # but we want to log it clearly.

def train():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", type=str, default="google/gemma-4-12b", help="HF Base Model ID")
    parser.add_argument("--train-dir", type=str, default="/mnt/data/train", help="Directory containing JSONL dataset files")
    parser.add_argument("--output-weights-dir", type=str, default="/mnt/data/weights", help="Directory to save LoRA adapter weights")
    parser.add_argument("--epochs", type=int, default=1, help="Number of training epochs")
    parser.add_argument("--batch-size", type=int, default=2, help="Per device train batch size")
    parser.add_argument("--lr", type=float, default=2e-4, help="Learning rate")
    parser.add_argument("--max-steps", type=int, default=-1, help="Max training steps (overrides epochs if > 0)")
    parser.add_argument("--seq-length", type=int, default=1024, help="Max sequence length")
    parser.add_argument("--project", type=str, required=True, help="GCP Project ID")
    parser.add_argument("--region", type=str, default="us-central1", help="GCP Region")
    parser.add_argument("--service-name", type=str, default="gemma-4-service", help="Cloud Run service to redeploy")
    parser.add_argument("--trigger-redeploy", action="store_true", help="Whether to trigger Cloud Run redeployment on completion")
    args = parser.parse_args()

    # Verify CUDA availability
    if not torch.cuda.is_available():
        logger.warning("CUDA is not available. Training will run on CPU, which is highly discouraged for 12B model!")
        device_map = "cpu"
    else:
        logger.info(f"CUDA is available. Active Device: {torch.cuda.get_device_name(0)}")
        device_map = "auto"

    # Read HF Token
    hf_token = os.getenv("HF_TOKEN")
    if not hf_token:
        logger.warning("HF_TOKEN environment variable not set. Loading public models only.")

    # Find JSONL dataset files
    jsonl_pattern = os.path.join(args.train_dir, "*.jsonl")
    all_files = glob.glob(jsonl_pattern)
    if not all_files:
        logger.error(f"No JSONL training files found in {args.train_dir} matching {jsonl_pattern}")
        raise FileNotFoundError(f"No JSONL training files found in {args.train_dir}")
    
    # Filter out 0-byte or invalid JSONL files to prevent Hugging Face datasets IndexError
    dataset_files = []
    for f in all_files:
        try:
            if os.path.exists(f) and os.path.getsize(f) > 0:
                with open(f, "r", encoding="utf-8") as check_f:
                    for line in check_f:
                        if line.strip():
                            dataset_files.append(f)
                            break
            else:
                logger.warning(f"Skipping empty 0-byte dataset file: {f}")
        except Exception as e:
            logger.warning(f"Could not read dataset file {f}: {e}")

    if not dataset_files:
        logger.error(f"No valid non-empty JSONL dataset files found in {args.train_dir}")
        raise FileNotFoundError(f"No valid non-empty JSONL dataset files found in {args.train_dir}")

    logger.info(f"Loading datasets from {len(dataset_files)} valid file(s): {dataset_files}")
    dataset = load_dataset("json", data_files=dataset_files, split="train")
    logger.info(f"Loaded dataset with {len(dataset)} examples.")

    # Configure 4-bit Quantization (QLoRA)
    logger.info("Configuring 4-bit Quantization (QLoRA)...")
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32,
        bnb_4bit_use_double_quant=True
    )

    # Load Tokenizer
    logger.info(f"Loading tokenizer for {args.model_id}...")
    tokenizer = AutoTokenizer.from_pretrained(args.model_id, token=hf_token)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    if getattr(tokenizer, "chat_template", None) is None:
        logger.info("Setting default ChatML fallback template for tokenizer...")
        tokenizer.chat_template = "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>' + '\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}{% endif %}"

    # Load Base Model
    logger.info(f"Loading base model {args.model_id} in 4-bit...")
    model = AutoModelForCausalLM.from_pretrained(
        args.model_id,
        quantization_config=bnb_config if torch.cuda.is_available() else None,
        device_map=device_map,
        token=hf_token,
        torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32
    )

    # Prepare model for kbit training
    if torch.cuda.is_available():
        logger.info("Preparing model for kbit training...")
        model = prepare_model_for_kbit_training(model)

    # Configure LoRA Parameters
    logger.info("Configuring PEFT/LoRA adapter...")
    lora_config = LoraConfig(
        r=16,
        lora_alpha=32,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM"
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # Formatter for SFTTrainer using conversational templates
    def format_prompts(example):
        # Apply tokenizer's chat template
        # The dataset format is: {"messages": [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}, {"role": "assistant", "content": "..."}]}
        return {"text": tokenizer.apply_chat_template(example["messages"], tokenize=False)}

    # Map the formatting function to dataset and remove unformatted columns
    logger.info("Formatting dataset using model chat templates...")
    formatted_dataset = dataset.map(format_prompts, remove_columns=dataset.column_names)

    # SFT Configuration & Trainer
    logger.info("Initializing SFTConfig and SFTTrainer...")
    sft_config = SFTConfig(
        dataset_text_field="text",
        max_length=args.seq_length,
        output_dir="./local_results",
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        per_device_train_batch_size=args.batch_size,
        gradient_accumulation_steps=4,
        learning_rate=args.lr,
        logging_steps=5,
        save_strategy="no", # Do not save local checkpoints to save space
        bf16=torch.cuda.is_available(),
        optim="adamw_torch",
        gradient_checkpointing=torch.cuda.is_available(),
        report_to="none",
        ddp_find_unused_parameters=False
    )

    trainer = SFTTrainer(
        model=model,
        processing_class=tokenizer,
        train_dataset=formatted_dataset,
        args=sft_config,
    )

    # Run Fine-Tuning
    logger.info("Starting training loop...")
    start_time = time.time()
    trainer.train()
    training_time = time.time() - start_time
    logger.info(f"Training completed in {training_time:.2f} seconds.")

    # Save trained LoRA adapter weights
    logger.info(f"Saving LoRA adapter weights and tokenizer to {args.output_weights_dir}...")
    os.makedirs(args.output_weights_dir, exist_ok=True)
    
    # Save model and tokenizer
    trainer.model.save_pretrained(args.output_weights_dir)
    tokenizer.save_pretrained(args.output_weights_dir)
    logger.info("Weights saved successfully.")

    # Trigger Cloud Run Redeployment
    if args.trigger_redeploy:
        logger.info(f"Triggering redeployment of {args.service_name}...")
        trigger_cloud_run_redeployment(args.project, args.region, args.service_name)
    else:
        logger.info("Redeployment trigger was not requested. Skipping.")

if __name__ == "__main__":
    train()
