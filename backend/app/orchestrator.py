"""Variance explanation with engine and language routing:
question (ES / EN / PT) → deterministic P x Q analysis in Trino (actual vs budget per G/L account: price,
efficiency, volume and spending effects, driver, unit OPEX, plan horizon) → operational logs from pgvector pre-filtered by Año / Mes / RCNTR of the analyzed month
→ answer from the selected engine (NVIDIA NIM with local fallback, or local Ollama) written EXACTLY in
the requested language. The LLM never calculates: a figures guard checks that every number it quotes
comes from Trino or the logs, and a language guard re-translates a drifted answer. Every question is
traced in Langfuse v2."""
from __future__ import annotations

import math
import time
from datetime import datetime, timezone

from langchain_core.prompts import ChatPromptTemplate
from langdetect import DetectorFactory, LangDetectException, detect_langs

from . import figures, knowledge, llm, observability, opex
from .masterdata import UNITS
from .messages import LANGUAGE_NAMES, message
from .settings import get_settings

DetectorFactory.seed = 0  # deterministic language detection


class KnowledgeBaseEmpty(RuntimeError):
    """Raised when the logs have not been embedded yet."""


SYSTEM_PROMPTS = {
    "es": ("Eres el analista FP&A con IA de Nodara Minería Chile y explicas al Gerente de Finanzas las desviaciones del "
           "OPEX C1 frente al presupuesto, cuenta por cuenta (P × Q), dentro del Rolling Forecast a 18 meses.\n"
           "Reglas obligatorias:\n"
           "1. Responde EXCLUSIVAMENTE en español; deja sin traducir solo códigos SAP (RCNTR, RACCT, STAGR), unidades y "
           "nombres propios.\n"
           "2. NO calcules: nunca sumes, restes, multipliques, dividas, promedies ni conviertas cifras. Usa SOLO las cifras "
           "del bloque «CÁLCULO DETERMINISTA», copiadas tal como aparecen y con su unidad. Un efecto o una desviación "
           "positivos son desfavorables (sobre presupuesto); negativos, favorables. Si una cifra figura como n/d, dilo.\n"
           "3. Analiza la matriz por cuenta (RACCT): la desviación real − presupuesto (BUDG) de cada cuenta se descompone "
           "en efecto Precio (P: precio unitario), efecto Eficiencia (Q: consumo específico por unidad del impulsor), "
           "efecto Volumen (nivel del impulsor FINSSKF sobre la parte variable) y Gasto (cuentas sin cantidad física).\n"
           "4. El origen de la desviación es el primer elemento del «Ranking de efectos desfavorables» calculado por "
           "Trino: nombra exactamente esa cuenta RACCT y su efecto, y confírmalo con la bitácora citada como "
           "[DOC-ID §sección]. Si no hay bitácoras del período, dilo y no supongas causas.\n"
           "5. Si el impulsor real es 0, el OPEX unitario y los consumos específicos no son calculables: dilo y explica "
           "qué cuentas se mantuvieron fijas.\n"
           "6. Indica qué proyecta el plan (ACDOCP) con sus cifras. Nunca inventes datos, fechas, equipos ni cifras.\n"
           "Formato ejecutivo de 220 palabras como máximo. Primera línea, exacta: «Origen: <RACCT> · efecto <Precio (P) "
           "| Eficiencia (Q) | Volumen | Gasto>», o «Origen: impulsor <STAGR> (Volumen)» si el ranking no tiene efectos "
           "desfavorables. Luego: 1) Desviación del mes: OPEX total real vs presupuesto (cifra y %) y el efecto de la "
           "cuenta origen. 2) Causa operacional según la bitácora. 3) Impacto en el forecast a 18 meses: primer y último "
           "mes del plan y su OPEX unitario. 4) Fuentes."),
    "en": ("You are the AI FP&A analyst of Nodara Minería Chile and explain to the Finance Manager the deviations of the "
           "C1 OPEX against the budget, account by account (P × Q), within the 18-month rolling forecast.\n"
           "Mandatory rules:\n"
           "1. Answer EXCLUSIVELY in English: also translate the operational logs (written in Spanish); keep only SAP "
           "codes (RCNTR, RACCT, STAGR), units and proper names untranslated.\n"
           "2. Do NOT calculate: never add, subtract, multiply, divide, average or convert figures. Use ONLY the figures of "
           "the «DETERMINISTIC CALCULATION» block, copied exactly as written with their unit. A positive effect or "
           "deviation is unfavorable (over budget); a negative one is favorable. If a figure shows as n/a, say so.\n"
           "3. Analyze the matrix by account (RACCT): the actual − budget (BUDG) deviation of every account splits into "
           "the Price effect (P: unit price), the Efficiency effect (Q: specific consumption per driver unit), the Volume "
           "effect (level of the FINSSKF driver on the variable share) and Spending (accounts without a physical quantity).\n"
           "4. The origin of the deviation is the first item of the «Ranking of unfavorable effects» computed by Trino: "
           "name exactly that RACCT account and its effect, and confirm it with the log cited as [DOC-ID §section]. If "
           "there are no logs for the period, say so and do not guess causes.\n"
           "5. If the actual driver is 0, the unit OPEX and the specific consumptions cannot be computed: say so and "
           "explain which accounts stayed fixed.\n"
           "6. State what the plan (ACDOCP) projects with its figures. Never invent data, dates, equipment or figures.\n"
           "Executive format, at most 220 words. First line, exactly: «Origin: <RACCT> · <Price (P) | Efficiency (Q) | "
           "Volume | Spending> effect», or «Origin: driver <STAGR> (Volume)» if the ranking has no unfavorable effects. "
           "Then: 1) Deviation of the month: total actual OPEX vs budget (amount and %) and the effect of the origin "
           "account. 2) Operational cause according to the log. 3) Impact on the 18-month forecast: first and last plan "
           "month and their unit OPEX. 4) Sources."),
    "pt": ("Você é o analista FP&A com IA da Nodara Minería Chile e explica ao Gerente Financeiro os desvios do OPEX C1 "
           "frente ao orçamento, conta por conta (P × Q), dentro do Rolling Forecast de 18 meses.\n"
           "Regras obrigatórias:\n"
           "1. Responda EXCLUSIVAMENTE em português do Brasil: traduza também os diários operacionais (escritos em "
           "espanhol); mantenha sem tradução apenas códigos SAP (RCNTR, RACCT, STAGR), unidades e nomes próprios.\n"
           "2. NÃO calcule: nunca some, subtraia, multiplique, divida, faça médias nem converta números. Use SOMENTE os "
           "números do bloco «CÁLCULO DETERMINÍSTICO», copiados exatamente como aparecem e com sua unidade. Um efeito ou "
           "desvio positivo é desfavorável (acima do orçamento); negativo, favorável. Se um número aparecer como n/d, "
           "diga isso.\n"
           "3. Analise a matriz por conta (RACCT): o desvio real − orçamento (BUDG) de cada conta se decompõe em efeito "
           "Preço (P: preço unitário), efeito Eficiência (Q: consumo específico por unidade do direcionador), efeito "
           "Volume (nível do direcionador FINSSKF sobre a parte variável) e Gasto (contas sem quantidade física).\n"
           "4. A origem do desvio é o primeiro item do «Ranking de efeitos desfavoráveis» calculado pelo Trino: nomeie "
           "exatamente essa conta RACCT e seu efeito, e confirme com o diário citado como [DOC-ID §seção]. Se não houver "
           "diários do período, diga isso e não suponha causas.\n"
           "5. Se o direcionador real for 0, o OPEX unitário e os consumos específicos não podem ser calculados: diga "
           "isso e explique quais contas ficaram fixas.\n"
           "6. Indique o que o plano (ACDOCP) projeta com seus números. Nunca invente dados, datas, equipamentos ou "
           "números.\n"
           "Formato executivo de no máximo 220 palavras. Primeira linha, exata: «Origem: <RACCT> · efeito <Preço (P) | "
           "Eficiência (Q) | Volume | Gasto>», ou «Origem: direcionador <STAGR> (Volume)» se o ranking não tiver efeitos "
           "desfavoráveis. Depois: 1) Desvio do mês: OPEX total real vs orçamento (valor e %) e o efeito da conta de "
           "origem. 2) Causa operacional segundo o diário. 3) Impacto no forecast de 18 meses: primeiro e último mês do "
           "plano e seu OPEX unitário. 4) Fontes."),
}

HUMAN_PROMPTS = {
    "es": ("Pregunta del Gerente de Finanzas:\n{question}\n\n=== CÁLCULO DETERMINISTA (Trino · gold vw_opex_c1_pxq) ===\n"
           "{facts}\n\n=== BITÁCORAS OPERACIONALES (pgvector · filtro Año {year} · Mes {month} · RCNTR {rcntr}) ===\n"
           "{logs}\n\nResponde ahora en español."),
    "en": ("Finance Manager question:\n{question}\n\n=== DETERMINISTIC CALCULATION (Trino · gold vw_opex_c1_pxq) ===\n"
           "{facts}\n\n=== OPERATIONAL LOGS (pgvector · filter Year {year} · Month {month} · RCNTR {rcntr}) ===\n"
           "{logs}\n\nAnswer now in English."),
    "pt": ("Pergunta do Gerente Financeiro:\n{question}\n\n=== CÁLCULO DETERMINÍSTICO (Trino · gold vw_opex_c1_pxq) ===\n"
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

# Effect names and labels of the deterministic facts block, per answer language.
EFFECTS = {
    "es": {"price": "Precio (P)", "efficiency": "Eficiencia (Q)", "volume": "Volumen", "spending": "Gasto"},
    "en": {"price": "Price (P)", "efficiency": "Efficiency (Q)", "volume": "Volume", "spending": "Spending"},
    "pt": {"price": "Preço (P)", "efficiency": "Eficiência (Q)", "volume": "Volume", "spending": "Gasto"},
}
LABELS = {
    "es": {
        "scope": "Centro de costo {rcntr} ({name} · área {area}) · moneda de grupo {currency} (KSL)",
        "frame": ("Período analizado: {period} (real, ACDOCA) frente al presupuesto {budget} ({budget_name}, "
                  "ACDOCP/FINSSKF) con presupuesto flexible: la parte fija (KFSL/VMFSL) no varía con el impulsor"),
        "opex": "OPEX total: real {actual} | presupuesto {budget} | presupuesto flexible {flex} | desviación {variance} ({pct})",
        "driver": "Impulsor {stagr} {name}: real {actual} | presupuesto {budget} ({pct})",
        "unit": "OPEX unitario ({unit}): real {actual} | presupuesto {budget} ({pct})",
        "unit_na": "no calculable (impulsor real = 0)",
        "effects": "Efectos totales:",
        "ranking": "Ranking de efectos desfavorables (origen de la desviación, calculado por Trino):",
        "no_unfavorable": "ninguna cuenta tiene efectos desfavorables",
        "matrix": "Matriz por cuenta (RACCT · real vs presupuesto):",
        "behavior": {"F": "fijo", "V": "variable", "M": "mixto"},
        "amount_only": "monto USD",
        "cost": "costo real {actual} vs presupuesto {budget} ({pct})",
        "quantity": "cantidad {actual} vs {budget} (flexible {flex})",
        "consumption": "consumo específico {actual} vs {budget} {unit} ({pct})",
        "price": "precio {actual} vs {budget} {unit} ({pct})",
        "line_effects": "efectos:",
        "postings": "Mayores partidas del período (ACDOCA):",
        "posting": "{budat} · documento {belnr} · cuenta {racct}: {amount}{quantity} «{text}»",
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
        "scope": "Cost center {rcntr} ({name} · area {area}) · group currency {currency} (KSL)",
        "frame": ("Analyzed period: {period} (actual, ACDOCA) against the {budget} budget ({budget_name}, "
                  "ACDOCP/FINSSKF) on a flexible budget: the fixed share (KFSL/VMFSL) does not move with the driver"),
        "opex": "Total OPEX: actual {actual} | budget {budget} | flexible budget {flex} | deviation {variance} ({pct})",
        "driver": "Driver {stagr} {name}: actual {actual} | budget {budget} ({pct})",
        "unit": "Unit OPEX ({unit}): actual {actual} | budget {budget} ({pct})",
        "unit_na": "not computable (actual driver = 0)",
        "effects": "Total effects:",
        "ranking": "Ranking of unfavorable effects (origin of the deviation, computed by Trino):",
        "no_unfavorable": "no account has unfavorable effects",
        "matrix": "Matrix by account (RACCT · actual vs budget):",
        "behavior": {"F": "fixed", "V": "variable", "M": "mixed"},
        "amount_only": "USD amount",
        "cost": "actual cost {actual} vs budget {budget} ({pct})",
        "quantity": "quantity {actual} vs {budget} (flexible {flex})",
        "consumption": "specific consumption {actual} vs {budget} {unit} ({pct})",
        "price": "price {actual} vs {budget} {unit} ({pct})",
        "line_effects": "effects:",
        "postings": "Largest postings of the period (ACDOCA):",
        "posting": "{budat} · document {belnr} · account {racct}: {amount}{quantity} «{text}»",
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
        "scope": "Centro de custo {rcntr} ({name} · área {area}) · moeda do grupo {currency} (KSL)",
        "frame": ("Período analisado: {period} (real, ACDOCA) frente ao orçamento {budget} ({budget_name}, "
                  "ACDOCP/FINSSKF) com orçamento flexível: a parte fixa (KFSL/VMFSL) não varia com o direcionador"),
        "opex": "OPEX total: real {actual} | orçamento {budget} | orçamento flexível {flex} | desvio {variance} ({pct})",
        "driver": "Direcionador {stagr} {name}: real {actual} | orçamento {budget} ({pct})",
        "unit": "OPEX unitário ({unit}): real {actual} | orçamento {budget} ({pct})",
        "unit_na": "não calculável (direcionador real = 0)",
        "effects": "Efeitos totais:",
        "ranking": "Ranking de efeitos desfavoráveis (origem do desvio, calculado pelo Trino):",
        "no_unfavorable": "nenhuma conta tem efeitos desfavoráveis",
        "matrix": "Matriz por conta (RACCT · real vs orçamento):",
        "behavior": {"F": "fixo", "V": "variável", "M": "misto"},
        "amount_only": "valor em USD",
        "cost": "custo real {actual} vs orçamento {budget} ({pct})",
        "quantity": "quantidade {actual} vs {budget} (flexível {flex})",
        "consumption": "consumo específico {actual} vs {budget} {unit} ({pct})",
        "price": "preço {actual} vs {budget} {unit} ({pct})",
        "line_effects": "efeitos:",
        "postings": "Maiores lançamentos do período (ACDOCA):",
        "posting": "{budat} · documento {belnr} · conta {racct}: {amount}{quantity} «{text}»",
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
CURRENCY = "USD"  # cost lines, OPEX and the numerator of every price and unit OPEX


def _number(value: float | None, decimals: int, language: str, signed: bool = False) -> str:
    """Formats a Trino figure for the answer language (formatting only: no arithmetic)."""
    if value is None:
        return LABELS[language]["na"]
    text = f"{value:{'+' if signed else ''},.{decimals}f}"
    if text.lstrip("+-") == f"{0:.{decimals}f}":  # a rounded zero carries no sign
        text = text.lstrip("+-")
    return text.translate(str.maketrans(",.", ".,")) if language in ("es", "pt") else text


def _significant(value: float | None, language: str, digits: int = 4) -> str:
    """Specific consumption with `digits` significant digits and no scientific notation."""
    if value is None:
        return LABELS[language]["na"]
    magnitude = math.floor(math.log10(abs(value))) if value else 0
    return _number(value, max(0, digits - 1 - magnitude), language)


def _usd(value: float | None, language: str, signed: bool = False) -> str:
    number = _number(value, 0, language, signed)
    if value is None:
        return number
    return f"{number[0]}{CURRENCY} {number[1:]}" if number[0] in "+-" else f"{CURRENCY} {number}"


def _quantity(value: float | None, symbol: str, language: str) -> str:
    """Physical quantity: whole units from 100, two decimals below (e.g. a flexed 60.86 PC)."""
    if value is None:
        return LABELS[language]["na"]
    return f"{_number(value, 0 if abs(value) >= 100 else 2, language)} {symbol}"


def _price(value: float | None, language: str) -> str:
    """Unit price: two decimals from 10 USD, four below (e.g. 0.1085 USD/kWh)."""
    return _number(value, 2 if value is not None and abs(value) >= 10 else 4, language)


def _percent(value: float | None, language: str) -> str:
    return LABELS[language]["na"] if value is None else f"{_number(value, 1, language, signed=True)} %"


def _line_facts(line: dict, driver: dict, language: str) -> str:
    labels, names = LABELS[language], EFFECTS[language]
    nature = labels["behavior"].get(line["behavior"], line["behavior"])
    unit = f"{line['symbol']} · {nature}" if line["ruom"] else f"{labels['amount_only']} · {nature}"
    parts = [f"- {line['racct']} {line['texts'][language]} [{unit}]: "
             + labels["cost"].format(actual=_usd(line["actual_ksl"], language), budget=_usd(line["budget_ksl"], language),
                                     pct=_percent(line["variance_pct"], language))]
    if line["ruom"]:
        symbol = line["symbol"]
        parts.append(labels["quantity"].format(actual=_quantity(line["actual_msl"], symbol, language),
                                               budget=_quantity(line["budget_msl"], symbol, language),
                                               flex=_quantity(line["flex_msl"], symbol, language)))
        parts.append(labels["consumption"].format(actual=_significant(line["actual_sc"], language),
                                                  budget=_significant(line["budget_sc"], language),
                                                  unit=f"{symbol}/{driver['symbol']}",
                                                  pct=_percent(line["sc_pct"], language)))
        parts.append(labels["price"].format(actual=_price(line["actual_price"], language),
                                            budget=_price(line["budget_price"], language),
                                            unit=f"{CURRENCY}/{symbol}", pct=_percent(line["price_pct"], language)))
    effects = [f"{names[effect]} {_usd(line[f'{effect}_effect'], language, signed=True)}"
               for effect in names if line[f"{effect}_effect"] is not None]
    parts.append(f"{labels['line_effects']} " + "; ".join(effects))
    return " · ".join(parts)


def format_facts(analysis: dict, language: str) -> str:
    """Deterministic facts block (every figure computed by Trino), worded in the answer language."""
    labels, names = LABELS[language], EFFECTS[language]
    driver, opex_values, unit = analysis["driver"], analysis["opex"], analysis["unit_cost"]
    unit_label, decimals = f"{CURRENCY}/{driver['symbol']}", driver["decimals"]
    lines = [labels["scope"].format(rcntr=analysis["rcntr"], name=analysis["rcntr_texts"][language],
                                    area=analysis["area_texts"][language], currency=analysis["currency"]),
             labels["frame"].format(period=analysis["period"], budget=analysis["budget_category"],
                                    budget_name=analysis["budget_texts"][language]),
             "- " + labels["opex"].format(actual=_usd(opex_values["actual"], language),
                                          budget=_usd(opex_values["budget"], language),
                                          flex=_usd(opex_values["flex"], language),
                                          variance=_usd(opex_values["variance"], language, signed=True),
                                          pct=_percent(opex_values["variance_pct"], language)),
             "- " + labels["driver"].format(stagr=driver["stagr"], name=driver["texts"][language],
                                            actual=_quantity(driver["actual"], driver["symbol"], language),
                                            budget=_quantity(driver["budget"], driver["symbol"], language),
                                            pct=_percent(driver["delta_pct"], language)),
             "- " + labels["unit"].format(unit=unit_label,
                                          actual=labels["unit_na"] if unit["actual"] is None
                                          else _number(unit["actual"], decimals, language),
                                          budget=_number(unit["budget"], decimals, language),
                                          pct=_percent(unit["delta_pct"], language)),
             "- " + labels["effects"] + " " + " | ".join(
                 f"{names[effect]} {_usd(amount, language, signed=True)}"
                 for effect, amount in analysis["effects"].items() if amount is not None),
             labels["ranking"]]
    lines += [f"{rank}. {origin['racct']} {origin['texts'][language]}: {names[origin['effect']]} "
              f"{_usd(origin['amount'], language, signed=True)}" for rank, origin in enumerate(analysis["origins"], 1)]
    if not analysis["origins"]:
        lines.append(f"- {labels['no_unfavorable']}")
    lines.append(labels["matrix"])
    lines += [_line_facts(line, driver, language) for line in analysis["lines"]]
    lines.append(labels["postings"])
    for p in analysis["top_postings"]:
        quantity = f" · {_quantity(p['msl'], UNITS.get(p['runit'], p['runit']), language)}" if p["runit"] else ""
        lines.append("- " + labels["posting"].format(budat=p["budat"], belnr=p["belnr"], racct=p["racct"], text=p["sgtxt"],
                                                     amount=_usd(p["ksl"], language), quantity=quantity))
    plan = analysis["forecast"]
    if plan.get("months"):
        lines.append(labels["plan"].format(category=analysis["category"], name=analysis["category_texts"][language],
                                           months=plan["months"], first=plan["first_period"], last=plan["last_period"]))
        lines.append("- " + labels["plan_first"].format(
            period=plan["first_period"], opex=_usd(plan["first_opex"], language),
            unit=f"{_number(plan['first_unit_cost'], decimals, language)} {unit_label}"))
        lines.append("- " + labels["plan_last"].format(
            period=plan["last_period"], opex=_usd(plan["last_opex"], language),
            unit=f"{_number(plan['last_unit_cost'], decimals, language)} {unit_label}",
            pct=_percent(plan["last_vs_period_pct"], language), analyzed=analysis["period"]))
        if plan["stable_from"]:
            lines.append("- " + labels["plan_stable"].format(period=plan["stable_from"]))
        lines.append("- " + labels["plan_total"].format(
            total=_usd(plan["total_opex"], language),
            unit=f"{_number(plan['horizon_unit_cost'], decimals, language)} {unit_label}"))
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
                       {"period": analysis["period"], "opex": analysis["opex"], "unit_cost": analysis["unit_cost"],
                        "origins": [(o["racct"], o["effect"], o["amount"]) for o in analysis["origins"]]})
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
