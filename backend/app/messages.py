"""User-facing backend messages in the three supported languages (ES / EN / PT)."""
from __future__ import annotations

from typing import Literal

Language = Literal["es", "en", "pt"]

LANGUAGE_NAMES: dict[str, str] = {"es": "español", "en": "English", "pt": "português do Brasil"}

_MESSAGES: dict[str, dict[str, str]] = {
    "model_unavailable": {
        "es": "Modelo(s) {models} no disponible(s) en el Ollama local (entorno air-gapped). Impórtalos con: make models",
        "en": "Model(s) {models} not available in the local Ollama (air-gapped environment). Import them with: make models",
        "pt": "Modelo(s) {models} indisponível(is) no Ollama local (ambiente air-gapped). Importe com: make models",
    },
    "kb_empty": {
        "es": "La base de conocimiento no tiene bitácoras indexadas. Ejecuta: make embed",
        "en": "The knowledge base has no indexed logs. Run: make embed",
        "pt": "A base de conhecimento não tem diários indexados. Execute: make embed",
    },
    "nim_not_configured": {
        "es": "El motor NVIDIA NIM no está configurado (falta NVIDIA_API_KEY en .env). Usa el motor Ollama (Local).",
        "en": "The NVIDIA NIM engine is not configured (NVIDIA_API_KEY missing in .env). Use the Ollama (Local) engine.",
        "pt": "O motor NVIDIA NIM não está configurado (falta NVIDIA_API_KEY no .env). Use o motor Ollama (Local).",
    },
    "all_models_failed": {
        "es": "Ningún modelo respondió ({models}). Revisa la conexión del gateway de salida o usa el motor local.",
        "en": "No model answered ({models}). Check the egress gateway connection or use the local engine.",
        "pt": "Nenhum modelo respondeu ({models}). Verifique o gateway de saída ou use o motor local.",
    },
    "lakehouse_not_ready": {
        "es": "El lakehouse aún no tiene las tablas financieras (el CDC está cargando). Reintenta en unos segundos.",
        "en": "The lakehouse does not have the financial tables yet (CDC is loading). Retry in a few seconds.",
        "pt": "O lakehouse ainda não tem as tabelas financeiras (o CDC está carregando). Tente novamente em instantes.",
    },
    "no_actuals": {
        "es": "El centro de costo {rcntr} no tiene datos reales en ACDOCA{period}.",
        "en": "Cost center {rcntr} has no actual data in ACDOCA{period}.",
        "pt": "O centro de custo {rcntr} não tem dados reais na ACDOCA{period}.",
    },
}


def message(key: str, language: str, **values: str) -> str:
    texts = _MESSAGES[key]
    return texts.get(language, texts["en"]).format(**values)
