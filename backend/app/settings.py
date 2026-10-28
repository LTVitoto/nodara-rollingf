"""Runtime configuration — 12-factor: everything comes from environment variables."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore")

    # Knowledge base: isolated pgvector instance (operational logs only)
    vector_db_host: str = "vector-db"
    vector_db_port: int = 5432
    vector_db_name: str = "knowledge"
    vector_db_user: str
    vector_db_password: str

    # Deterministic analytics: Trino over Delta Lake (catalog lakehouse: bronze + silver) and S/4HANA live
    trino_host: str = "trino"
    trino_port: int = 8080
    trino_user: str = "nodara-backend"

    # Local LLM runtime (air-gapped Ollama): embeddings + contingency chat engine
    ollama_base_url: str = "http://ollama:11434"
    ollama_chat_model: str = "llama3.1:8b"
    ollama_embed_model: str = "nomic-embed-text"
    ollama_timeout_s: float = 300.0

    # Cloud LLM engine (NVIDIA NIM), reachable only through the egress gateway
    llm_default_engine: str = "nim"
    nvidia_api_key: str = ""
    nvidia_base_url: str = "https://integrate.api.nvidia.com/v1"
    nim_model: str = "openai/gpt-oss-20b"
    nim_timeout_s: float = 45.0  # per attempt; a fast NIM answer is never cut
    nim_reasoning_effort: str = "low"  # sent to reasoning models; empty = not sent

    # GenAI observability (Langfuse v2, self-hosted)
    langfuse_host: str = "http://langfuse:3000"
    langfuse_public_key: str = ""
    langfuse_secret_key: str = ""
    langfuse_public_url: str = "http://localhost:3001"
    langfuse_project_id: str = "nodara-rollingf"
    trace_user_id: str = "gerente_finanzas@nodara.com"

    rag_top_k: int = 4


@lru_cache
def get_settings() -> Settings:
    return Settings()
