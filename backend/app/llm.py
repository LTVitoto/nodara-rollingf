"""LLM engines through LangChain.

* ``nim``    NVIDIA NIM (cloud, OpenAI-compatible API) reached only through the egress gateway;
             pipeline: NIM model → fallback 1: local Ollama model.
* ``ollama`` local, air-gapped engine (also serves the embeddings).

Every attempt has a hard timeout (ChatNVIDIA posts without a network timeout) and is reported,
so the caller always knows which model answered and why a fallback happened.
"""
from __future__ import annotations

import logging
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as AttemptTimeout

import httpx
from langchain_core.runnables import Runnable
from langchain_nvidia_ai_endpoints import ChatNVIDIA
from langchain_ollama import ChatOllama, OllamaEmbeddings

from .messages import message
from .settings import get_settings

log = logging.getLogger("backend")

ENGINES = ("nim", "ollama")
THINK_BLOCK = re.compile(r"<think>.*?</think>", re.DOTALL)
_attempts = ThreadPoolExecutor(max_workers=8, thread_name_prefix="llm-attempt")
_catalog_lock = threading.Lock()
_catalog: tuple[float, set[str]] | None = None


class ModelUnavailable(RuntimeError):
    """Raised when an engine or a required model is not available."""


def _canonical(name: str) -> str:
    return name if ":" in name else f"{name}:latest"


# ── Ollama (local) ──────────────────────────────────────────────────────────
def installed_models() -> set[str]:
    response = httpx.get(f"{get_settings().ollama_base_url}/api/tags", timeout=5)
    response.raise_for_status()
    return {_canonical(m["name"]) for m in response.json().get("models", [])}


def require_models(*names: str, language: str = "en") -> None:
    missing = [n for n in names if _canonical(n) not in installed_models()]
    if missing:
        raise ModelUnavailable(message("model_unavailable", language, models=", ".join(missing)))


def model_status() -> dict:
    s = get_settings()
    installed = installed_models()
    return {"chat_model": s.ollama_chat_model, "chat_ready": _canonical(s.ollama_chat_model) in installed,
            "embed_model": s.ollama_embed_model, "embed_ready": _canonical(s.ollama_embed_model) in installed,
            "installed": sorted(installed)}


def chat() -> ChatOllama:
    s = get_settings()
    return ChatOllama(model=s.ollama_chat_model, base_url=s.ollama_base_url, temperature=0.1,
                      num_ctx=8192, keep_alive="30m", client_kwargs={"timeout": s.ollama_timeout_s})


def embedder() -> OllamaEmbeddings:
    s = get_settings()
    return OllamaEmbeddings(model=s.ollama_embed_model, base_url=s.ollama_base_url,
                            client_kwargs={"timeout": s.ollama_timeout_s})


# ── NVIDIA NIM (cloud) ──────────────────────────────────────────────────────
def _nim(model: str) -> Runnable:
    s = get_settings()
    nim = ChatNVIDIA(model=model, api_key=s.nvidia_api_key, base_url=s.nvidia_base_url,
                     temperature=0.1, max_tokens=1500)
    return nim.bind(reasoning_effort=s.nim_reasoning_effort) if s.nim_reasoning_effort else nim


def nim_status() -> dict:
    """Configuration and catalog reachability of the cloud engine (catalog cached for 5 minutes)."""
    global _catalog
    s = get_settings()
    status = {"configured": bool(s.nvidia_api_key), "model": s.nim_model,
              "fallback": f"ollama/{s.ollama_chat_model}", "reachable": False}
    if not s.nvidia_api_key:
        return status
    with _catalog_lock:
        if not _catalog or time.monotonic() - _catalog[0] > 300:
            try:
                response = httpx.get(f"{s.nvidia_base_url}/models", timeout=10,
                                     headers={"Authorization": f"Bearer {s.nvidia_api_key}"})
                response.raise_for_status()
                _catalog = (time.monotonic(), {m["id"] for m in response.json().get("data", [])})
            except Exception as exc:
                status["error"] = str(exc)[:200]
                return status
    status["reachable"] = True
    status["listed"] = s.nim_model in _catalog[1]
    return status


# ── Engine routing with fallbacks ───────────────────────────────────────────
def candidates(engine: str, language: str) -> list[tuple[str, Runnable, float]]:
    """Ordered (label, model, timeout) chain: NIM → local Ollama, or only the local engine."""
    s = get_settings()
    local = (f"ollama/{s.ollama_chat_model}", chat(), s.ollama_timeout_s)
    if engine == "ollama":
        return [local]
    if not s.nvidia_api_key:
        raise ModelUnavailable(message("nim_not_configured", language))
    return [(f"nim/{s.nim_model}", _nim(s.nim_model), s.nim_timeout_s), local]


def generate(prompt_value, engine: str, task: str, language: str, callbacks: list) -> tuple[str, str, list[dict]]:
    """Runs the fallback chain; returns (text, model that answered, attempts)."""
    attempts: list[dict] = []
    for label, model, timeout_s in candidates(engine, language):
        start = time.perf_counter()
        future = _attempts.submit(model.invoke, prompt_value,
                                  {"callbacks": callbacks, "run_name": f"{task} · {label}"})
        try:
            text = THINK_BLOCK.sub("", future.result(timeout=timeout_s).content).strip()
            if not text:
                raise ValueError("empty completion")
        except AttemptTimeout:
            error = f"timeout after {timeout_s:.0f}s"
        except Exception as exc:  # API error, rate limit, model end-of-life… → next model
            error = f"{type(exc).__name__}: {exc}"[:240]
        else:
            attempts.append({"model": label, "task": task, "status": "ok", "ms": int((time.perf_counter() - start) * 1000)})
            return text, label, attempts
        attempts.append({"model": label, "task": task, "status": "error", "error": error,
                         "ms": int((time.perf_counter() - start) * 1000)})
        log.warning("LLM attempt failed (%s, %s): %s", task, label, error)
    raise ModelUnavailable(message("all_models_failed", language,
                                   models=", ".join(a["model"] for a in attempts)))


def warm_up() -> None:
    """Loads the local models into memory so the first question skips the cold start."""
    s = get_settings()
    try:
        if {_canonical(s.ollama_chat_model), _canonical(s.ollama_embed_model)} <= installed_models():
            embedder().embed_query("warm-up")
            chat().invoke("Reply with OK.")
            log.info("local models warmed up: %s, %s", s.ollama_chat_model, s.ollama_embed_model)
    except Exception as exc:  # warm-up is best effort; requests still work without it
        log.info("model warm-up skipped: %s", exc)
