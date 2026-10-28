"""Variance explanation with engine and language routing:
question (ES / EN / PT) → deterministic analysis in Trino (OPEX per cost element, drivers, unit OPEX,
plan horizon) → maintenance logs from pgvector pre-filtered by Año / Mes / RCNTR of the analyzed month
→ answer from the selected engine (NVIDIA NIM with local fallback, or local Ollama) written EXACTLY in
the requested language. The LLM never calculates: a figures guard checks that every number it quotes
comes from Trino or the logs, and a language guard re-translates a drifted answer. Every question is
traced in Langfuse v2."""
from __future__ import annotations

import time
from datetime import datetime, timezone

from langchain_core.prompts import ChatPromptTemplate
from langdetect import DetectorFactory, LangDetectException, detect_langs

from . import figures, knowledge, llm, observability, opex
from .masterdata import ACCOUNTS, texts
from .messages import LANGUAGE_NAMES, message
from .settings import get_settings

DetectorFactory.seed = 0  # deterministic language detection


class KnowledgeBaseEmpty(RuntimeError):
    """Raised when the logs have not been embedded yet."""


SYSTEM_PROMPTS = {
    "es": ("Eres el analista FP&A con IA de Nodara Minería Chile y explicas al Gerente de Finanzas las desviaciones de "
           "OPEX del Rolling Forecast a 18 meses.\n"
           "Reglas obligatorias:\n"
           "1. Responde EXCLUSIVAMENTE en español; deja sin traducir solo códigos SAP, unidades y nombres propios.\n"
           "2. NO calcules: nunca sumes, restes, multipliques, dividas, promedies ni conviertas cifras. Usa SOLO las cifras "
           "del bloque «CÁLCULO DETERMINISTA», copiadas tal como aparecen y con su unidad, respetando el signo de cada Δ "
           "(negativo = disminución). Si una cifra no está, di que no está disponible.\n"
           "3. Explica la causa operacional SOLO con las bitácoras recuperadas y cítalas como [DOC-ID §sección]. Si no hay "
           "bitácoras del período, dilo y no supongas causas.\n"
           "4. Relaciona la causa con los impulsores calculados: gasto por cuenta (ACDOCA), horas operativas y toneladas "
           "(FINSSKF) y OPEX unitario.\n"
           "5. Indica qué proyecta el plan (ACDOCP) para los próximos meses con sus cifras.\n"
           "6. Nunca inventes datos, fechas, equipos ni cifras.\n"
           "Formato ejecutivo de 200 palabras como máximo: 1) Desviación del mes. 2) Causa operacional. 3) Impacto en el "
           "forecast a 18 meses. 4) Fuentes."),
    "en": ("You are the AI FP&A analyst of Nodara Minería Chile and explain the OPEX deviations of the 18-month rolling "
           "forecast to the Finance Manager.\n"
           "Mandatory rules:\n"
           "1. Answer EXCLUSIVELY in English: also translate the maintenance logs (written in Spanish); keep only SAP "
           "codes, units and proper names untranslated.\n"
           "2. Do NOT calculate: never add, subtract, multiply, divide, average or convert figures. Use ONLY the figures of "
           "the «DETERMINISTIC CALCULATION» block, copied exactly as written with their unit, keeping the sign of every Δ "
           "(negative = decrease). If a figure is missing, say it is not available.\n"
           "3. Explain the operational cause ONLY with the retrieved logs and cite them as [DOC-ID §section]. If there are "
           "no logs for the period, say so and do not guess causes.\n"
           "4. Link the cause to the calculated drivers: spend per account (ACDOCA), operating hours and tonnes (FINSSKF) "
           "and unit OPEX.\n"
           "5. State what the plan (ACDOCP) projects for the coming months with its figures.\n"
           "6. Never invent data, dates, equipment or figures.\n"
           "Executive format, at most 200 words: 1) Deviation of the month. 2) Operational cause. 3) Impact on the "
           "18-month forecast. 4) Sources."),
    "pt": ("Você é o analista FP&A com IA da Nodara Minería Chile e explica ao Gerente Financeiro os desvios de OPEX do "
           "Rolling Forecast de 18 meses.\n"
           "Regras obrigatórias:\n"
           "1. Responda EXCLUSIVAMENTE em português do Brasil: traduza também os diários de manutenção (escritos em "
           "espanhol); mantenha sem tradução apenas códigos SAP, unidades e nomes próprios.\n"
           "2. NÃO calcule: nunca some, subtraia, multiplique, divida, faça médias nem converta números. Use SOMENTE os "
           "números do bloco «CÁLCULO DETERMINÍSTICO», copiados exatamente como aparecem e com sua unidade, respeitando o "
           "sinal de cada Δ (negativo = redução). Se um número não estiver lá, diga que não está disponível.\n"
           "3. Explique a causa operacional SOMENTE com os diários recuperados e cite-os como [DOC-ID §seção]. Se não "
           "houver diários do período, diga isso e não suponha causas.\n"
           "4. Relacione a causa com os direcionadores calculados: gasto por conta (ACDOCA), horas operacionais e "
           "toneladas (FINSSKF) e OPEX unitário.\n"
           "5. Indique o que o plano (ACDOCP) projeta para os próximos meses com seus números.\n"
           "6. Nunca invente dados, datas, equipamentos ou números.\n"
           "Formato executivo de no máximo 200 palavras: 1) Desvio do mês. 2) Causa operacional. 3) Impacto no forecast "
           "de 18 meses. 4) Fontes."),
}

HUMAN_PROMPTS = {
    "es": ("Pregunta del Gerente de Finanzas:\n{question}\n\n=== CÁLCULO DETERMINISTA (Trino · lakehouse silver) ===\n"
           "{facts}\n\n=== BITÁCORAS OPERACIONALES (pgvector · filtro Año {year} · Mes {month} · RCNTR {rcntr}) ===\n"
           "{logs}\n\nResponde ahora en español."),
    "en": ("Finance Manager question:\n{question}\n\n=== DETERMINISTIC CALCULATION (Trino · lakehouse silver) ===\n"
           "{facts}\n\n=== OPERATIONAL LOGS (pgvector · filter Year {year} · Month {month} · RCNTR {rcntr}) ===\n"
           "{logs}\n\nAnswer now in English."),
    "pt": ("Pergunta do Gerente Financeiro:\n{question}\n\n=== CÁLCULO DETERMINÍSTICO (Trino · lakehouse silver) ===\n"
           "{facts}\n\n=== DIÁRIOS OPERACIONAIS (pgvector · filtro Ano {year} · Mês {month} · RCNTR {rcntr}) ===\n"
           "{logs}\n\nResponda agora em português do Brasil."),
}

ANSWER_PROMPTS = {language: ChatPromptTemplate.from_messages([("system", SYSTEM_PROMPTS[language]),
                                                             ("human", HUMAN_PROMPTS[language])])
                  for language in LANGUAGE_NAMES}

ANSWER_TRANSLATION = ChatPromptTemplate.from_messages([
    ("system",
     "You are a professional translator for a mining company. Translate the user's text into {language}. "
     "Keep the structure, the numbering, every figure exactly as written (same digits, separators and units), "
     "SAP codes and citations [DOC-ID §section] unchanged. Output only the translation."),
    ("human", "{text}"),
])

# Labels of the deterministic facts block, per answer language.
LABELS = {
    "es": {
        "scope": "Centro de costo {rcntr} ({name}) · moneda de grupo {currency} (KSL)",
        "frame": ("Período analizado: {period} (real, ACDOCA) · mes anterior: {previous} · línea base: promedio de "
                  "{months} mes(es) real(es) previo(s), {first} a {last}"),
        "frame_alone": "Período analizado: {period} (real, ACDOCA) · sin meses reales previos para comparar",
        "OPEX": "OPEX total", "HOROP": "Horas operativas (FINSSKF HOROP)", "TONMOV": "Toneladas movidas (FINSSKF TONMOV)",
        "USD_H": "OPEX unitario por hora", "USD_T": "OPEX unitario por tonelada",
        "previous": "mes anterior", "baseline": "línea base", "share": "del OPEX",
        "accounts": "Por cuenta de costo (ACDOCA, KSL):",
        "postings": "Mayores partidas del período (ACDOCA):",
        "posting": "{budat} · documento {belnr} · cuenta {racct} ({name}): {amount} «{text}»",
        "plan": "Plan (ACDOCP, categoría {category}: {name}) · {months} meses, {first} a {last}:",
        "plan_first": "primer mes {period}: OPEX {opex} · {unit}",
        "plan_last": "último mes {period}: OPEX {opex} · {unit} ({pct} frente a {analyzed})",
        "plan_stable": "OPEX unitario estable (±1 %) desde {period}",
        "plan_total": "OPEX total planificado del horizonte (ACDOCP): {total} · OPEX unitario planificado del horizonte: {unit}",
        "no_plan": "Sin plan en ACDOCP para la categoría {category} después de {period}.",
        "no_logs": "No hay bitácoras indexadas para RCNTR {rcntr} en {period}.",
        "log": "Año {gjahr} · Mes {monat} · RCNTR {rcntr} · {author}",
        "na": "n/d",
    },
    "en": {
        "scope": "Cost center {rcntr} ({name}) · group currency {currency} (KSL)",
        "frame": ("Analyzed period: {period} (actual, ACDOCA) · previous month: {previous} · baseline: average of "
                  "{months} earlier actual month(s), {first} to {last}"),
        "frame_alone": "Analyzed period: {period} (actual, ACDOCA) · no earlier actual month to compare with",
        "OPEX": "Total OPEX", "HOROP": "Operating hours (FINSSKF HOROP)", "TONMOV": "Tonnes hauled (FINSSKF TONMOV)",
        "USD_H": "Unit OPEX per hour", "USD_T": "Unit OPEX per tonne",
        "previous": "previous month", "baseline": "baseline", "share": "of OPEX",
        "accounts": "By cost element (ACDOCA, KSL):",
        "postings": "Largest postings of the period (ACDOCA):",
        "posting": "{budat} · document {belnr} · account {racct} ({name}): {amount} «{text}»",
        "plan": "Plan (ACDOCP, category {category}: {name}) · {months} months, {first} to {last}:",
        "plan_first": "first month {period}: OPEX {opex} · {unit}",
        "plan_last": "last month {period}: OPEX {opex} · {unit} ({pct} vs {analyzed})",
        "plan_stable": "unit OPEX stable (±1%) from {period}",
        "plan_total": "total planned OPEX of the horizon (ACDOCP): {total} · planned unit OPEX of the horizon: {unit}",
        "no_plan": "No ACDOCP plan for category {category} after {period}.",
        "no_logs": "No indexed logs for RCNTR {rcntr} in {period}.",
        "log": "Year {gjahr} · Month {monat} · RCNTR {rcntr} · {author}",
        "na": "n/a",
    },
    "pt": {
        "scope": "Centro de custo {rcntr} ({name}) · moeda do grupo {currency} (KSL)",
        "frame": ("Período analisado: {period} (real, ACDOCA) · mês anterior: {previous} · linha de base: média de "
                  "{months} mês(es) real(is) anterior(es), {first} a {last}"),
        "frame_alone": "Período analisado: {period} (real, ACDOCA) · sem meses reais anteriores para comparar",
        "OPEX": "OPEX total", "HOROP": "Horas operacionais (FINSSKF HOROP)",
        "TONMOV": "Toneladas movimentadas (FINSSKF TONMOV)",
        "USD_H": "OPEX unitário por hora", "USD_T": "OPEX unitário por tonelada",
        "previous": "mês anterior", "baseline": "linha de base", "share": "do OPEX",
        "accounts": "Por conta de custo (ACDOCA, KSL):",
        "postings": "Maiores lançamentos do período (ACDOCA):",
        "posting": "{budat} · documento {belnr} · conta {racct} ({name}): {amount} «{text}»",
        "plan": "Plano (ACDOCP, categoria {category}: {name}) · {months} meses, {first} a {last}:",
        "plan_first": "primeiro mês {period}: OPEX {opex} · {unit}",
        "plan_last": "último mês {period}: OPEX {opex} · {unit} ({pct} frente a {analyzed})",
        "plan_stable": "OPEX unitário estável (±1 %) desde {period}",
        "plan_total": "OPEX total planejado do horizonte (ACDOCP): {total} · OPEX unitário planejado do horizonte: {unit}",
        "no_plan": "Sem plano na ACDOCP para a categoria {category} depois de {period}.",
        "no_logs": "Não há diários indexados para RCNTR {rcntr} em {period}.",
        "log": "Ano {gjahr} · Mês {monat} · RCNTR {rcntr} · {author}",
        "na": "n/d",
    },
}
# (unit suffix or prefix, decimals) per metric; cost elements and OPEX are USD amounts.
UNITS = {"OPEX": ("USD", 0), "HOROP": ("h", 0), "TONMOV": ("t", 0), "USD_H": ("USD/h", 2), "USD_T": ("USD/t", 4)}


def _number(value: float | None, decimals: int, language: str, signed: bool = False) -> str:
    """Formats a Trino figure for the answer language (formatting only: no arithmetic)."""
    if value is None:
        return LABELS[language]["na"]
    text = f"{value:{'+' if signed else ''},.{decimals}f}"
    return text.translate(str.maketrans(",.", ".,")) if language in ("es", "pt") else text


def _quantity(value: float | None, metric: str, language: str, signed: bool = False) -> str:
    unit, decimals = UNITS.get(metric, UNITS["OPEX"])
    number = _number(value, decimals, language, signed)
    if value is None or unit != "USD":
        return number if value is None else f"{number} {unit}"
    return f"{number[0]}USD {number[1:]}" if signed and number[0] in "+-" else f"USD {number}"


def _percent(value: float | None, language: str) -> str:
    return LABELS[language]["na"] if value is None else f"{_number(value, 1, language, signed=True)} %"


def _metric_line(name: str, metric: str, values: dict, language: str) -> str:
    labels = LABELS[language]
    line = f"- {name}: {_quantity(values['current'], metric, language)}"
    for key in ("previous", "baseline"):
        if values[key] is not None:
            line += (f" | {labels[key]} {_quantity(values[key], metric, language)} "
                     f"(Δ {_quantity(values[f'delta_{key}'], metric, language, signed=True)}; "
                     f"{_percent(values[f'delta_{key}_pct'], language)})")
    if values.get("share_pct") is not None:
        line += f" | {_number(values['share_pct'], 1, language)} % {labels['share']}"
    return line


def format_facts(analysis: dict, language: str) -> str:
    """Deterministic facts block (every figure computed by Trino), worded in the answer language."""
    labels, baseline = LABELS[language], analysis["baseline"]
    lines = [labels["scope"].format(rcntr=analysis["rcntr"], name=analysis["rcntr_texts"][language],
                                    currency=analysis["currency"])]
    lines.append(labels["frame"].format(period=analysis["period"], previous=analysis["previous_period"],
                                        months=baseline["months"], first=baseline["from"], last=baseline["to"])
                 if baseline["months"] else labels["frame_alone"].format(period=analysis["period"]))
    lines += [_metric_line(labels[metric], metric, values, language) for metric, values in analysis["totals"].items()]
    lines.append(labels["accounts"])
    lines += [_metric_line(f"{a['racct']} {a['texts'][language]}", "OPEX", a, language) for a in analysis["accounts"]]
    lines.append(labels["postings"])
    lines += [f"- {labels['posting'].format(budat=p['budat'], belnr=p['belnr'], racct=p['racct'], text=p['sgtxt'], name=texts(ACCOUNTS, p['racct'])[language], amount=_quantity(p['ksl'], 'OPEX', language))}"
              for p in analysis["top_postings"]]
    plan = analysis["forecast"]
    if plan.get("months"):
        lines.append(labels["plan"].format(category=analysis["category"], name=analysis["category_texts"][language],
                                           months=plan["months"], first=plan["first_period"], last=plan["last_period"]))
        lines.append("- " + labels["plan_first"].format(
            period=plan["first_period"], opex=_quantity(plan["first_opex"], "OPEX", language),
            unit=_quantity(plan["first_usd_per_hour"], "USD_H", language)))
        lines.append("- " + labels["plan_last"].format(
            period=plan["last_period"], opex=_quantity(plan["last_opex"], "OPEX", language),
            unit=_quantity(plan["last_usd_per_hour"], "USD_H", language),
            pct=_percent(plan["last_vs_period_pct"], language), analyzed=analysis["period"]))
        if plan["stable_from"]:
            lines.append("- " + labels["plan_stable"].format(period=plan["stable_from"]))
        lines.append("- " + labels["plan_total"].format(
            total=_quantity(plan["total_opex"], "OPEX", language),
            unit=_quantity(plan["horizon_usd_per_hour"], "USD_H", language)))
    else:
        lines.append(labels["no_plan"].format(category=analysis["category"] or "-", period=analysis["period"]))
    return "\n".join(lines)


def format_logs(logs: list[dict], language: str, rcntr: str, period: str) -> str:
    if not logs:
        return LABELS[language]["no_logs"].format(rcntr=rcntr, period=period)
    return "\n\n".join(
        f"[{log['doc_id']} §{log['section']}] ("
        + LABELS[language]["log"].format(gjahr=log["gjahr"], monat=log["monat"], rcntr=log["rcntr"],
                                         author=log["author_role"])
        + f")\n{log['content']}" for log in logs)


def detect_language(text: str) -> str | None:
    """Most probable supported language of a text (statistical detector with a fixed seed)."""
    try:
        candidates = [c for c in detect_langs(text) if c.lang in LANGUAGE_NAMES]
    except LangDetectException:
        return None
    return max(candidates, key=lambda c: c.prob).lang if candidates else None


def _elapsed_ms(start: float) -> int:
    return int((time.perf_counter() - start) * 1000)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def answer_question(question: str, language: str = "es", engine: str = "nim", rcntr: str | None = None,
                    period: str | None = None, top_k: int | None = None) -> dict:
    s = get_settings()
    # Embeddings are always local; the chat model only when the local engine is selected.
    llm.require_models(s.ollama_embed_model, *([s.ollama_chat_model] if engine == "ollama" else []),
                       language=language)
    rcntr, category = opex.scope(rcntr, None)
    trace = observability.start_trace(question, language, engine, rcntr)
    callbacks = observability.callbacks(trace)
    timings: dict[str, int] = {}
    attempts: list[dict] = []

    # 1 · Deterministic math in Trino: the only source of figures.
    start, started_at = time.perf_counter(), _now()
    analysis = opex.analyze(rcntr, category, period)
    observability.span(trace, "trino · OPEX unitario (determinista)", started_at,
                       {"rcntr": rcntr, "category": category, "period": period or "latest"},
                       {"period": analysis["period"], "totals": analysis["totals"]})
    timings["analysis_ms"] = _elapsed_ms(start)

    # 2 · Logs of exactly that cost center and month (metadata pre-filter, then similarity).
    start, started_at = time.perf_counter(), _now()
    if not knowledge.stats()["embedded"]:
        raise KnowledgeBaseEmpty(message("kb_empty", language))
    year, month = int(analysis["period"][:4]), int(analysis["period"][5:])
    query_vector = llm.embedder().embed_query(f"search_query: {question}")
    logs = knowledge.search(query_vector, rcntr, year, month, top_k or s.rag_top_k)
    retrieval_filter = {"Año": year, "Mes": month, "RCNTR": rcntr}
    observability.span(trace, "retrieval · pgvector (Año/Mes/RCNTR)", started_at, retrieval_filter,
                       {"documents": sorted({log["doc_id"] for log in logs}), "chunks": len(logs)})
    timings["retrieve_ms"] = _elapsed_ms(start)

    # 3 · The LLM explains the variance with those figures and logs, in the requested language.
    start = time.perf_counter()
    facts, logs_text = format_facts(analysis, language), format_logs(logs, language, rcntr, analysis["period"])
    answer, model_used, tried = llm.generate(
        ANSWER_PROMPTS[language].invoke({"question": question, "facts": facts, "logs": logs_text,
                                         "year": year, "month": month, "rcntr": rcntr}),
        engine, "answer", language, callbacks)
    attempts += tried
    timings["generate_ms"] = _elapsed_ms(start)

    detected, status = detect_language(answer), "ok"
    if detected != language:  # language guard: one corrective translation pass
        start = time.perf_counter()
        answer, _, tried = llm.generate(
            ANSWER_TRANSLATION.invoke({"language": LANGUAGE_NAMES[language], "text": answer}),
            engine, "utility", language, callbacks)
        attempts += tried
        timings["language_fix_ms"] = _elapsed_ms(start)
        detected, status = detect_language(answer), "corrected"
    figures_check = figures.check(answer, f"{question}\n{facts}\n{logs_text}")

    language_check = {"requested": language, "detected": detected, "status": status}
    trace_id, trace_url = observability.finish(trace, answer, {
        "engine": engine, "model_used": model_used, "attempts": attempts, "language_check": language_check,
        "figures_check": figures_check, "retrieval_filter": retrieval_filter, "timings_ms": timings})

    return {
        "answer": answer,
        "language": language,
        "language_check": language_check,
        "figures_check": figures_check,
        "engine": engine,
        "model_used": model_used,
        "attempts": attempts,
        "trace_id": trace_id,
        "trace_url": trace_url,
        "rcntr": rcntr,
        "period": analysis["period"],
        "analysis": analysis,
        "retrieval_filter": retrieval_filter,
        "sources": [{"doc_id": log["doc_id"], "title": log["title"], "author_role": log["author_role"],
                     "source_uri": log["source_uri"], "section": log["section"],
                     "similarity": round(float(log["similarity"]), 4), "excerpt": log["content"][:280],
                     "metadata": {"Año": log["gjahr"], "Mes": log["monat"], "RCNTR": log["rcntr"]}} for log in logs],
        "models": {"chat": model_used, "embeddings": f"ollama/{s.ollama_embed_model}"},
        "timings_ms": timings,
    }
