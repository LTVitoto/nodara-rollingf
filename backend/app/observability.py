"""GenAI observability with Langfuse v2 (self-hosted): one trace per question with the simulated
Finance Manager as user_id, LangChain generations through the trace-bound CallbackHandler, and
explicit spans for the Trino calculation and the pgvector retrieval. Tracing is best effort and
never breaks a request."""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from functools import lru_cache

from langfuse import Langfuse

from .settings import get_settings

log = logging.getLogger("backend")


@lru_cache
def client() -> Langfuse | None:
    s = get_settings()
    if not (s.langfuse_public_key and s.langfuse_secret_key):
        log.info("Langfuse disabled: LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY not set")
        return None
    return Langfuse(public_key=s.langfuse_public_key, secret_key=s.langfuse_secret_key,
                    host=s.langfuse_host, release="nodara-rollingf-backend@0.1.0")


def start_trace(question: str, language: str, engine: str, rcntr: str):
    lf = client()
    if lf is None:
        return None
    s = get_settings()
    try:
        return lf.trace(name="rollingf-ask", user_id=s.trace_user_id,
                        session_id=f"{s.trace_user_id}:{datetime.now(timezone.utc):%Y-%m-%d}",
                        input={"question": question, "language": language, "engine": engine, "rcntr": rcntr},
                        tags=[f"engine:{engine}", f"lang:{language}", f"rcntr:{rcntr}"])
    except Exception as exc:
        log.warning("Langfuse trace not created: %s", exc)
        return None


def callbacks(trace) -> list:
    """Langfuse v2 CallbackHandler bound to the trace (every LangChain call becomes a generation)."""
    if trace is None:
        return []
    try:
        return [trace.get_langchain_handler()]
    except Exception as exc:
        log.warning("Langfuse CallbackHandler unavailable: %s", exc)
        return []


def span(trace, name: str, start: datetime, input: dict, output: dict) -> None:
    if trace is None:
        return
    try:
        trace.span(name=name, start_time=start, end_time=datetime.now(timezone.utc), input=input, output=output)
    except Exception as exc:
        log.warning("Langfuse span %s not recorded: %s", name, exc)


def finish(trace, output: str, metadata: dict) -> tuple[str | None, str | None]:
    """Closes the trace; returns (trace_id, URL of the trace in the Langfuse UI)."""
    if trace is None:
        return None, None
    s = get_settings()
    try:
        trace.update(output=output, metadata=metadata)
    except Exception as exc:
        log.warning("Langfuse trace not updated: %s", exc)
    return trace.id, f"{s.langfuse_public_url}/project/{s.langfuse_project_id}/traces/{trace.id}"


def healthy() -> bool:
    lf = client()
    try:
        return bool(lf and lf.auth_check())
    except Exception:
        return False


def flush() -> None:
    lf = client()
    if lf is not None:
        lf.flush()
