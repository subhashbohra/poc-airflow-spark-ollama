"""
ollama_client.py — Reusable Ollama API client for Airflow DAGs

All LLM calls go to the internal ClusterIP service only.
No external API calls. Mirrors GDC air-gap pattern.
"""
import json
import logging
import os
import time

import requests

log = logging.getLogger(__name__)

OLLAMA_BASE_URL = os.getenv(
    "OLLAMA_BASE_URL",
    "http://ollama-service.llm-serving.svc.cluster.local:11434"
)
DEFAULT_MODEL = os.getenv("OLLAMA_MODEL", "gemma2:2b")
DEFAULT_TIMEOUT = int(os.getenv("TIMEOUT_SECONDS", "120"))


def check_ollama_health() -> bool:
    """
    Health check — used by HttpSensor in DAGs.
    Returns True if Ollama API is reachable and responding.
    """
    try:
        resp = requests.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=10)
        if resp.status_code == 200:
            data = resp.json()
            models = [m.get("name", "") for m in data.get("models", [])]
            log.info(f"Ollama healthy. Models available: {models}")
            return True
        log.warning(f"Ollama returned status {resp.status_code}")
        return False
    except Exception as e:
        log.error(f"Ollama health check failed: {e}")
        return False


def list_models() -> list:
    """Return list of available model names."""
    try:
        resp = requests.get(f"{OLLAMA_BASE_URL}/api/tags", timeout=10)
        resp.raise_for_status()
        return [m.get("name", "") for m in resp.json().get("models", [])]
    except Exception as e:
        log.error(f"Could not list Ollama models: {e}")
        return []


def generate_rca(prompt: str, model: str = None) -> dict:
    """
    Call Ollama /api/generate and parse JSON response.

    Uses format='json' to enforce structured output.
    Temperature 0.1 for deterministic, factual RCA.

    Returns parsed dict or error dict if LLM call fails.
    """
    model = model or DEFAULT_MODEL
    start = time.time()

    try:
        log.info(f"Calling Ollama RCA: model={model}, prompt_len={len(prompt)}")

        resp = requests.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json={
                "model": model,
                "prompt": prompt,
                "format": "json",
                "stream": False,
                "options": {
                    "temperature": 0.1,
                    "num_predict": 512,
                    "top_p": 0.9,
                    "repeat_penalty": 1.1,
                },
            },
            timeout=DEFAULT_TIMEOUT,
        )
        resp.raise_for_status()

        raw_response = resp.json().get("response", "{}")
        elapsed = round(time.time() - start, 2)

        log.info(f"Ollama responded in {elapsed}s. Raw length: {len(raw_response)}")

        # Parse the JSON response from the model
        try:
            result = json.loads(raw_response)
        except json.JSONDecodeError:
            # Try to extract JSON from the response if model wrapped it
            import re
            json_match = re.search(r'\{.*\}', raw_response, re.DOTALL)
            if json_match:
                result = json.loads(json_match.group())
            else:
                raise

        result["_response_time_seconds"] = elapsed
        result["_model_used"] = model
        result["_prompt_length"] = len(prompt)

        log.info(f"RCA parsed successfully. Category: {result.get('root_cause_category', 'unknown')}, "
                 f"Severity: {result.get('severity', 'unknown')}, "
                 f"Confidence: {result.get('confidence', 0)}")
        return result

    except json.JSONDecodeError as e:
        log.error(f"Ollama returned invalid JSON: {e}\nRaw: {raw_response[:500]}")
        return {
            "root_cause": "LLM response parsing failed — Ollama returned non-JSON output",
            "root_cause_category": "configuration",
            "confidence": 0.0,
            "immediate_fix": (
                "Review Ollama pod logs: kubectl logs -n llm-serving deployment/ollama\n"
                "Try lowering temperature to 0.05 or re-pulling the model."
            ),
            "prevention": "Validate Ollama JSON output format in staging before production",
            "retry_recommended": True,
            "estimated_fix_time_minutes": 10,
            "severity": "medium",
            "affected_downstream": "RCA report unavailable",
            "similar_past_incidents": "none",
            "_error": str(e),
            "_response_time_seconds": round(time.time() - start, 2),
            "_model_used": model,
        }
    except requests.exceptions.Timeout:
        log.error(f"Ollama request timed out after {DEFAULT_TIMEOUT}s")
        return {
            "root_cause": f"Ollama inference timed out after {DEFAULT_TIMEOUT}s — model may be overloaded",
            "root_cause_category": "resource_exhaustion",
            "confidence": 0.0,
            "immediate_fix": "Check Ollama pod CPU/memory: kubectl top pod -n llm-serving",
            "prevention": "Increase Ollama pod memory limit or use a smaller model",
            "retry_recommended": True,
            "estimated_fix_time_minutes": 5,
            "severity": "medium",
            "affected_downstream": "RCA report unavailable",
            "similar_past_incidents": "none",
            "_error": "timeout",
            "_response_time_seconds": round(time.time() - start, 2),
            "_model_used": model,
        }
    except Exception as e:
        log.error(f"Ollama call failed: {e}")
        return {
            "root_cause": f"Could not reach Ollama service: {str(e)}",
            "root_cause_category": "connectivity",
            "confidence": 0.0,
            "immediate_fix": (
                "Check Ollama pod status: kubectl get pods -n llm-serving\n"
                "Verify network policy: kubectl get networkpolicy -n llm-serving"
            ),
            "prevention": "Add Ollama health check sensor at start of each DAG",
            "retry_recommended": False,
            "estimated_fix_time_minutes": 15,
            "severity": "high",
            "affected_downstream": "All AI-powered RCA unavailable",
            "similar_past_incidents": "none",
            "_error": str(e),
            "_response_time_seconds": round(time.time() - start, 2),
            "_model_used": model,
        }


def generate_anomaly_explanation(context: str, model: str = None) -> str:
    """
    Ask Ollama to explain an anomaly in plain English.
    Returns a human-readable string (not JSON).
    """
    model = model or DEFAULT_MODEL
    prompt = f"""
You are a data pipeline expert. A timing anomaly was detected in an Apache Airflow DAG.
Provide a brief (2-3 sentences) explanation of what might cause this and what to check.

Anomaly context:
{context}

Respond with a plain English explanation only. Be concise and actionable.
"""
    try:
        resp = requests.post(
            f"{OLLAMA_BASE_URL}/api/generate",
            json={
                "model": model,
                "prompt": prompt,
                "stream": False,
                "options": {"temperature": 0.2, "num_predict": 150},
            },
            timeout=60,
        )
        resp.raise_for_status()
        return resp.json().get("response", "Could not generate explanation.").strip()
    except Exception as e:
        log.error(f"Anomaly explanation failed: {e}")
        return f"Anomaly explanation unavailable: {str(e)}"
