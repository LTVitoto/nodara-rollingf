"""Nodara Rolling Forecast · AI orchestrator API (FastAPI)."""
from __future__ import annotations

import logging
import threading
from contextlib import asynccontextmanager, contextmanager
from typing import Annotated

from fastapi import FastAPI, Query, Request
from fastapi.responses import JSONResponse

from . import knowledge, lakehouse, llm, observability, opex
from .messages import message
from .orchestrator import KnowledgeBaseEmpty, answer_question
from .schemas import AskRequest, AskResponse, EmbedResponse, normalize_language
from .settings import get_settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s [backend] %(message)s")
log = logging.getLogger("backend")


class UserFacingError(RuntimeError):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status, self.detail = status, detail


@asynccontextmanager
async def lifespan(_: FastAPI):
    knowledge.open_pool()
    threading.Thread(target=llm.warm_up, name="model-warm-up", daemon=True).start()
    yield
    observability.flush()
    knowledge.close_pool()


app = FastAPI(title="Nodara Rolling Forecast Orchestrator", version="0.1.0", lifespan=lifespan)


@app.exception_handler(llm.ModelUnavailable)
async def model_unavailable(_: Request, exc: llm.ModelUnavailable) -> JSONResponse:
    return JSONResponse(status_code=503, content={"detail": str(exc)})


@app.exception_handler(KnowledgeBaseEmpty)
async def knowledge_base_empty(_: Request, exc: KnowledgeBaseEmpty) -> JSONResponse:
    return JSONResponse(status_code=409, content={"detail": str(exc)})


@app.exception_handler(UserFacingError)
async def user_facing_error(_: Request, exc: UserFacingError) -> JSONResponse:
    return JSONResponse(status_code=exc.status, content={"detail": exc.detail})


@contextmanager
def localized(language: str, rcntr: str | None = None, period: str | None = None):
    """Lakehouse and scope errors as messages in the operator's language."""
    try:
        yield
    except lakehouse.LakehouseNotReady as exc:
        raise UserFacingError(503, message("lakehouse_not_ready", language)) from exc
    except lakehouse.AnalysisNotFound as exc:
        raise UserFacingError(404, message("no_actuals", language, rcntr=rcntr or "-",
                                           period=f" ({period})" if period else "")) from exc
    except ValueError as exc:
        raise UserFacingError(422, str(exc)) from exc


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


def _probe(check) -> dict:
    try:
        return {"ok": True, **check()}
    except Exception as exc:  # status page must degrade gracefully, never fail
        return {"ok": False, "error": str(exc)[:300]}


def _engines() -> dict:
    return {"default_engine": get_settings().llm_default_engine, "nim": llm.nim_status(),
            "ollama": _probe(llm.model_status)}


@app.get("/api/v1/status")
def status() -> dict:
    """Dependency map for the operator console: KB, live S/4, lakehouse CDC, LLM engines, tracing."""
    return {"knowledge_base": _probe(knowledge.stats),
            "s4hana_live": _probe(lakehouse.s4_live_summary),
            "lakehouse_cdc": _probe(lakehouse.cdc_freshness),
            "llm": _probe(_engines),
            "observability": {"ok": observability.healthy(), "langfuse_url": get_settings().langfuse_public_url}}


@app.get("/api/v1/opex/cost-centers")
def cost_centers(language: str = "es") -> dict:
    """Cost centers of the value chain with actuals and plan categories (selector of the console)."""
    with localized(normalize_language(language)):
        return opex.cost_centers()


@app.get("/api/v1/opex/timeline")
def timeline(rcntr: Annotated[str | None, Query(pattern=r"^[A-Z0-9_]{1,20}$")] = None,
             category: Annotated[str | None, Query(pattern=r"^[A-Z0-9_]{1,10}$")] = None,
             language: str = "es") -> dict:
    """Continuous monthly OPEX: actuals (ACDOCA) against the budget (ACDOCP · BUDG) + plan (ACDOCP), drivers
    and unit OPEX computed by Trino, with the deviation summary (actual - budget) of the latest actual month."""
    with localized(normalize_language(language), rcntr):
        center, plan_category = opex.scope(rcntr, category)
        return opex.timeline(center, plan_category)


@app.post("/api/v1/kb/embed", response_model=EmbedResponse)
def embed_knowledge_base() -> EmbedResponse:
    """Embeds pending log chunks in-enclave (Ollama) and stores them in pgvector."""
    s = get_settings()
    llm.require_models(s.ollama_embed_model)
    pending = knowledge.pending_chunks()
    if pending:
        vectors = llm.embedder().embed_documents(
            [f"search_document: {c['section']}\n{c['content']}" for c in pending])
        knowledge.save_embeddings([(c["chunk_id"], v) for c, v in zip(pending, vectors)], s.ollama_embed_model)
        log.info("embedded %d chunks with %s", len(pending), s.ollama_embed_model)
    totals = knowledge.stats()
    return EmbedResponse(embedded_now=len(pending), model=s.ollama_embed_model,
                         total_embedded=totals["embedded"], total_chunks=totals["chunks"])


@app.post("/api/v1/ask", response_model=AskResponse)
def ask(request: AskRequest) -> dict:
    """Explains the OPEX deviation of a cost center month: Trino math + pgvector logs filtered by
    Año / Mes / RCNTR, answered in the requested language by the selected engine and traced in Langfuse."""
    with localized(request.language, request.rcntr, request.period):
        return answer_question(request.question, request.language,
                               request.engine or get_settings().llm_default_engine,
                               request.rcntr, request.period, request.top_k)
