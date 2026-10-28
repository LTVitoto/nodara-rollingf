"""API contracts."""
from typing import Any, Literal

from pydantic import AliasChoices, BaseModel, Field, field_validator

from .messages import Language

Engine = Literal["nim", "ollama"]
_ENGINE_ALIASES = {"nim": "nim", "nvidia": "nim", "cloud": "nim", "ollama": "ollama", "local": "ollama"}


def normalize_language(value: Any) -> Any:
    return str(value).strip().lower().split("-")[0] if value else "es"


class AskRequest(BaseModel):
    question: str = Field(min_length=3, max_length=2000, validation_alias=AliasChoices("question", "query"),
                          description="Finance Manager question in ES, EN or PT (also accepted as `query`)")
    language: Language = Field(default="es", description="Answer language: ES | EN | PT (case-insensitive)")
    engine: Engine | None = Field(default=None, description="LLM engine: nim (NVIDIA NIM cloud) | ollama (local)")
    rcntr: str | None = Field(default=None, pattern=r"^[A-Z0-9_]{1,20}$",
                              description="Cost center (RCNTR); default: the first one with actual data")
    period: str | None = Field(default=None, pattern=r"^\d{4}-(0[1-9]|1[0-2])$",
                               description="Actual month to explain (YYYY-MM); default: the latest actual month")
    top_k: int | None = Field(default=None, ge=1, le=10)

    @field_validator("language", mode="before")
    @classmethod
    def _language(cls, value: Any) -> Any:
        return normalize_language(value)

    @field_validator("engine", mode="before")
    @classmethod
    def normalize_engine(cls, value: Any) -> Any:
        return _ENGINE_ALIASES.get(str(value).strip().lower(), value) if value else None


class Source(BaseModel):
    doc_id: str
    title: str
    author_role: str
    source_uri: str  # lineage: original document in the raw layer (s3://raw-docs/...)
    section: str
    similarity: float
    excerpt: str
    metadata: dict[str, int | str]  # mandatory vector metadata: Año, Mes, RCNTR


class AskResponse(BaseModel):
    answer: str
    language: Language
    language_check: dict[str, str | None]
    figures_check: dict[str, Any]  # numbers quoted by the LLM: checked / grounded / ungrounded (not from Trino)
    engine: Engine
    model_used: str
    attempts: list[dict[str, Any]]  # fallback chain as executed (model, task, status, ms, error)
    trace_id: str | None
    trace_url: str | None  # Langfuse v2 UI
    rcntr: str
    period: str
    analysis: dict[str, Any]  # deterministic variance computed by Trino
    retrieval_filter: dict[str, int | str]
    sources: list[Source]
    models: dict[str, str]
    timings_ms: dict[str, int]


class EmbedResponse(BaseModel):
    embedded_now: int
    model: str
    total_embedded: int
    total_chunks: int
