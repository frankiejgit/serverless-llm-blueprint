import argparse
import json
import logging
import os
import random
import shutil
import time
from typing import List, Optional, Tuple

from google import genai
from google.genai import types
from pydantic import BaseModel, Field, ValidationError

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Schema for the synthetic data generation (Meta-prompting)
class SyntheticQAEntry(BaseModel):
    user_question: str = Field(description="A realistic and contextually appropriate user question based on the provided documents.")
    assistant_answer: str = Field(description="A detailed, technically accurate, and comprehensive assistant answer based on the provided documents.")

def load_pdf_parts(pdf_path: str, task_index: int = 0, task_count: int = 1) -> Tuple[List[types.Part], List[str]]:
    """Loads and partitions PDFs from a directory or single file based on Cloud Run task index.
    
    Returns:
        tuple: (List of types.Part, List of absolute file paths loaded)
    """
    parts = []
    loaded_paths = []
    if not os.path.exists(pdf_path):
        logger.warning(f"PDF path {pdf_path} does not exist.")
        return parts, loaded_paths

    if os.path.isfile(pdf_path) and pdf_path.lower().endswith(".pdf"):
        try:
            if os.path.getsize(pdf_path) == 0:
                logger.warning(f"Single PDF file is empty: {pdf_path} (0 bytes)")
                return parts, loaded_paths
        except Exception as e:
            logger.error(f"Error checking size of {pdf_path}: {e}")
            return parts, loaded_paths
            
        logger.info(f"Loading single file {pdf_path}...")
        with open(pdf_path, "rb") as f:
            parts.append(types.Part.from_bytes(data=f.read(), mime_type="application/pdf"))
        loaded_paths.append(pdf_path)
        return parts, loaded_paths

    # Get all PDFs and sort them for deterministic partitioning across tasks
    all_filenames = sorted([f for f in os.listdir(pdf_path) if f.lower().endswith(".pdf")])
    
    # Partition files using task_index and task_count
    task_filenames = [all_filenames[i] for i in range(len(all_filenames)) if i % task_count == task_index]
    
    logger.info(f"Task index {task_index}/{task_count} assigned {len(task_filenames)} PDFs out of {len(all_filenames)}")
    
    for filename in task_filenames:
        path = os.path.join(pdf_path, filename)
        try:
            if os.path.getsize(path) == 0:
                logger.warning(f"Skipping empty PDF file: {filename} (0 bytes)")
                continue
        except Exception as e:
            logger.error(f"Error checking size of {filename}: {e}")
            continue

        logger.info(f"Loading {filename}...")
        try:
            with open(path, "rb") as f:
                parts.append(types.Part.from_bytes(data=f.read(), mime_type="application/pdf"))
            loaded_paths.append(path)
        except Exception as e:
            logger.error(f"Failed to load PDF {filename}: {e}")
            
    return parts, loaded_paths

def generate_dataset(client: genai.Client, pdf_parts: List[types.Part], count: int, output_path: str, model_id: str, system_prompt: str, base_prompt: str):
    """Generates the synthetic dataset with robust retry logic."""
    
    config = types.GenerateContentConfig(
        response_mime_type="application/json",
        response_schema=SyntheticQAEntry,
        temperature=0.8,
    )

    # Create output directory if it doesn't exist
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    # Combine prompt and PDF parts once, outside the loop
    contents = [base_prompt] + pdf_parts
    
    max_retries = 3
    base_delay = 2.0

    with open(output_path, "w") as f:
        for i in range(count):
            logger.info(f"Generating scenario {i+1}/{count}...")
            success = False
            
            for attempt in range(max_retries):
                try:
                    response = client.models.generate_content(
                        model=model_id,
                        contents=contents,
                        config=config
                    )
                    
                    data = SyntheticQAEntry.model_validate_json(response.text)
                    
                    jsonl_entry = {
                        "messages": [
                            {"role": "system", "content": system_prompt},
                            {"role": "user", "content": data.user_question},
                            {"role": "assistant", "content": data.assistant_answer}
                        ]
                    }
                    f.write(json.dumps(jsonl_entry) + "\n")
                    # Force write to disk immediately so partial progress is saved
                    f.flush()
                    logger.info(f"Scenario {i+1} saved.")
                    success = True
                    break # Success, break out of retry loop
                    
                except ValidationError as ve:
                    logger.warning(f"JSON schema validation failed on attempt {attempt+1} for scenario {i+1}: {ve}")
                except Exception as e:
                    logger.warning(f"API/Network error on attempt {attempt+1} for scenario {i+1}: {e}")
                
                if attempt < max_retries - 1:
                    sleep_time = base_delay * (2 ** attempt)
                    logger.info(f"Retrying in {sleep_time:.1f}s...")
                    time.sleep(sleep_time)
            
            if not success:
                logger.error(f"Failed scenario {i+1} completely after {max_retries} attempts. Skipping.")
                
            # Minor sleep between successful requests to smooth out API RPM
            time.sleep(0.5)

    # Clean up file if 0 bytes
    if os.path.exists(output_path) and os.path.getsize(output_path) == 0:
        logger.warning(f"No dataset scenarios were generated. Removing 0-byte empty file: {output_path}")
        try:
            os.remove(output_path)
        except Exception as e:
            logger.error(f"Failed to remove 0-byte file {output_path}: {e}")
def archive_pdfs(pdf_paths: List[str], archive_dir: str):
    """Moves processed PDFs to the archive (processed) directory."""
    if not pdf_paths:
        return
    
    os.makedirs(archive_dir, exist_ok=True)
    for path in pdf_paths:
        filename = os.path.basename(path)
        dest_path = os.path.join(archive_dir, filename)
        logger.info(f"Archiving {filename} to {dest_path}...")
        try:
            # GCS FUSE rename works as copy + delete
            shutil.move(path, dest_path)
            logger.info(f"Successfully archived {filename}")
        except Exception as e:
            logger.error(f"Failed to archive {filename}: {e}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=str, required=True, help="Path to config.json containing prompts.")
    parser.add_argument("--count", type=int, default=5, help="Number of scenarios to generate per task.")
    parser.add_argument("--output-dir", type=str, default="data/train", help="Directory where JSONL files will be saved.")
    parser.add_argument("--pdf-path", type=str, default="data/raw", help="Path to a directory of PDFs or a single PDF file for testing.")
    parser.add_argument("--archive-dir", type=str, default="data/processed", help="Directory where processed PDFs will be archived.")
    parser.add_argument("--project", type=str, required=True)
    parser.add_argument("--location", type=str, default="us-central1")
    parser.add_argument("--model", type=str, default="gemini-2.5-flash")
    args = parser.parse_args()

    with open(args.config, "r") as f:
        config_data = json.load(f)
        system_prompt = config_data.get("system_prompt", "")
        base_prompt = config_data.get("base_prompt", "")

    # Cloud Run Job specific indexing to avoid file collisions
    task_index_str = os.getenv("CLOUD_RUN_TASK_INDEX", "0")
    task_count_str = os.getenv("CLOUD_RUN_TASK_COUNT", "1")
    try:
        task_index = int(task_index_str)
        task_count = int(task_count_str)
    except ValueError:
        task_index = 0
        task_count = 1

    output_filename = f"agroforestry_sft_task_{task_index}.jsonl"
    final_output_path = os.path.join(args.output_dir, output_filename)

    # Use Vertex AI client
    client = genai.Client(vertexai=True, project=args.project, location=args.location)

    pdf_parts, loaded_paths = load_pdf_parts(args.pdf_path, task_index, task_count)
    if not pdf_parts:
        logger.info(f"No source PDFs assigned to task {task_index} in {args.pdf_path}. Exiting cleanly.")
        exit(0)

    logger.info(f"Task {task_index} starting. Generating {args.count} scenarios to {final_output_path}...")
    generate_dataset(client, pdf_parts, args.count, final_output_path, args.model, system_prompt, base_prompt)

    logger.info(f"Task {task_index} dataset generation completed. Archiving processed PDFs...")
    archive_pdfs(loaded_paths, args.archive_dir)
    logger.info("Task completion cleanup done.")