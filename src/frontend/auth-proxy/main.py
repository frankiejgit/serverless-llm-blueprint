import os
import httpx
import logging
import uvicorn
import json
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

# Logging to track requests and model routing
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger("smart-router")

app = FastAPI()

# Configuration from Environment
LISTEN_PORT = int(os.environ.get("PORT", 8000))

def get_auth_token(target_url: str):
    """
    Fetches an OIDC token directly from the Google Metadata Server.
    This is the most reliable method for Cloud Run-to-Cloud Run communication.
    """
    try:
        # The audience MUST be the base URL of the Cloud Run service (no path)
        audience = str(httpx.URL(target_url).copy_with(path="", query=None, fragment=None)).rstrip("/")
        
        metadata_url = f"http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience={audience}"
        headers = {"Metadata-Flavor": "Google"}
        
        with httpx.Client() as client:
            resp = client.get(metadata_url, headers=headers, timeout=5.0)
            if resp.status_code == 200:
                return resp.text
            else:
                logger.error(f"Auth: Metadata server error ({resp.status_code}) for audience {audience}")
                return None
    except Exception as e:
        logger.error(f"Auth: Exception fetching OIDC token: {e}")
        return None

def get_model_config():
    """
    Dynamically builds the model routing dictionary from environment variables.
    Zero hardcoded model names so any team can customize display names via .env!
    """
    tuned_url = os.environ.get("TUNED_MODEL_URL") or os.environ.get("TARGET_URL")
    base_url = os.environ.get("BASE_MODEL_URL")
    
    tuned_name = os.environ.get("TUNED_MODEL_NAME", "gemma-4-sare-tuned")
    base_name = os.environ.get("BASE_MODEL_NAME", "gemma-4-base")
    
    tuned_backend_id = os.environ.get("TUNED_BACKEND_ID", tuned_name)
    base_backend_id = os.environ.get("BASE_BACKEND_ID", "/app/model_cache")

    config = {}
    if tuned_url and "pending" not in tuned_url:
        config[tuned_name] = {"url": tuned_url, "backend_id": tuned_backend_id}
    if base_url and "pending" not in base_url:
        config[base_name] = {"url": base_url, "backend_id": base_backend_id}
    
    # Fallback template if URLs are not active yet
    if not config:
        config[tuned_name] = {"url": tuned_url or "http://pending-tuned-service", "backend_id": tuned_backend_id}
    
    return config

@app.get("/v1/models")
async def list_models():
    """Exposes the supported models dynamically to OpenWebUI."""
    config = get_model_config()
    models = []
    for model_id in config:
        owned_by = "google" if "base" in model_id.lower() else "custom-tuned"
        models.append({"id": model_id, "object": "model", "owned_by": owned_by})
    return {"object": "list", "data": models}

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"])
async def proxy(request: Request, path: str):
    """
    Smart OIDC Proxy:
    1. Inspects the requested 'model' for routing and ID rewriting.
    2. Completely sanitizes unsupported OpenWebUI parameters ('tool_choice', 'tools').
    3. Fetches OIDC token from the local metadata server.
    4. Streams the response back to the frontend with detailed upstream error logging.
    """
    try:
        content = await request.body()
        model_config = get_model_config()
        
        # Default target URL
        default_config = next(iter(model_config.values()))
        target_url = default_config["url"]
        forward_content = content
        
        # 1. Routing, Rewriting & Robust Parameter Sanitization
        if request.method == "POST" and "completions" in path:
            try:
                body = json.loads(content)
                requested_model = body.get("model")
                if requested_model in model_config:
                    config = model_config[requested_model]
                    target_url = config["url"]
                    body["model"] = config["backend_id"]
                
                # Strip all tool/function calling params sent by OpenWebUI to ensure vLLM stability
                if "tool_choice" in body:
                    logger.info(f"Stripping 'tool_choice' ({body['tool_choice']}) parameter from request")
                    body.pop("tool_choice", None)
                if "tools" in body:
                    logger.info("Stripping 'tools' array parameter from request")
                    body.pop("tools", None)
                
                forward_content = json.dumps(body).encode("utf-8")
                logger.info(f"Routing '{requested_model}' -> '{body.get('model')}' at {target_url}")
            except json.JSONDecodeError:
                pass 

        if not target_url or "pending" in target_url:
            return Response(content="Backend model service URL not configured.", status_code=503)

        # 2. Authentication (Metadata Server)
        token = get_auth_token(target_url)
        if not token:
            return Response(content="Authentication failure: Could not acquire OIDC token.", status_code=401)

        # 3. Forwarding (Streaming & Explicit Error Logging)
        headers = {k: v for k, v in request.headers.items() 
                   if k.lower() not in ["host", "content-length", "authorization", "connection"]}
        headers["Authorization"] = f"Bearer {token}"
        
        clean_path = path.lstrip('/')
        target_endpoint = f"{target_url.rstrip('/')}/{clean_path}"
        logger.info(f"Forwarding {request.method} -> {target_endpoint}")
        
        client = httpx.AsyncClient(timeout=300.0)
        req = client.build_request(
            method=request.method,
            url=target_endpoint,
            headers=headers,
            params=request.query_params,
            content=forward_content
        )
        
        response = await client.send(req, stream=True)
        
        if response.status_code != 200:
            error_body = await response.aread()
            logger.error(f"Upstream vLLM error (HTTP {response.status_code}): {error_body.decode('utf-8', errors='ignore')}")
            await client.aclose()
            return Response(
                content=error_body,
                status_code=response.status_code,
                media_type=response.headers.get("content-type", "application/json")
            )
        
        return StreamingResponse(
            response.aiter_raw(),
            status_code=response.status_code,
            headers=dict(response.headers),
            background=client.aclose
        )

    except Exception as e:
        logger.error(f"Proxy error: {str(e)}")
        return Response(content=f"Proxy error: {str(e)}", status_code=500)

if __name__ == "__main__":
    logger.info(f"Secure Smart Router active on port {LISTEN_PORT}")
    uvicorn.run(app, host="0.0.0.0", port=LISTEN_PORT)
