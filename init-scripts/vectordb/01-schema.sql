-- ═══════════════════════════════════════════════════════════════════════════
-- Nodara Rolling Forecast · Knowledge base (isolated pgvector instance — operational logs only)
-- Maintenance logs (bitácoras, Spanish originals) chunked for retrieval. Every vector carries the SAP
-- coordinates it explains — fiscal year (Año = GJAHR), month (Mes = MONAT) and cost center (RCNTR) —
-- as MANDATORY metadata: retrieval is pre-filtered on them before the similarity ranking, so the AI
-- only reads the logs of the period and cost center whose variance it explains.
-- Embeddings are produced in-enclave by the backend (Ollama nomic-embed-text, 768-d): no external
-- embedding APIs (air-gap). No CDC, no Trino catalog.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA kb;

CREATE TABLE kb.documents (
    doc_id         text PRIMARY KEY,
    title          text NOT NULL,
    doc_type       text NOT NULL CHECK (doc_type IN ('maintenance_log')),
    author_role    text NOT NULL,
    site           text NOT NULL,
    language       char(2) NOT NULL,
    classification text NOT NULL,
    source_uri     text NOT NULL UNIQUE CHECK (source_uri LIKE 's3://raw-docs/%'),  -- lineage → raw layer (MinIO)
    loaded_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE kb.chunks (
    chunk_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_id          text NOT NULL REFERENCES kb.documents (doc_id),
    chunk_no        int NOT NULL,
    section         text NOT NULL,
    content         text NOT NULL,
    gjahr           smallint NOT NULL CHECK (gjahr BETWEEN 2000 AND 2100),       -- Año (fiscal year)
    monat           smallint NOT NULL CHECK (monat BETWEEN 1 AND 12),            -- Mes (period, K4 = month)
    rcntr           varchar(20) NOT NULL CHECK (rcntr ~ '^[A-Z0-9_]{1,20}$'),    -- RCNTR (cost center)
    embedding       vector(768),
    embedding_model text,
    embedded_at     timestamptz,
    UNIQUE (doc_id, chunk_no)
);

CREATE INDEX chunks_sap_coordinates ON kb.chunks (rcntr, gjahr, monat);
CREATE INDEX chunks_embedding_hnsw ON kb.chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX chunks_content_fts ON kb.chunks USING gin (to_tsvector('spanish', content));
