"""Deterministic OPEX C1 analytics in Trino over the lakehouse (current state of the SAP tables replicated
by CDC). The SQL reads the gold views that the trino-init job publishes before the backend starts
(lakehouse/trino/gold — the backend never runs DDL):
  vw_opex_c1_pxq           master P x Q view: one row per version (ACTUAL, BUDG, RF18M), month, cost center
                           (RCNTR) and G/L account (RACCT) — cost KSL, quantity MSL in its own unit RUOM, price,
                           driver (FINSSKF) and specific consumption
  vw_opex_c1_pxq_variance  actual vs base budget (BUDG) on a flexible budget: price P, efficiency Q, volume and
                           spending effects
Results are cached in memory per query until the lakehouse changes: the cache key carries the Delta version of
the bronze tables, so a new CDC commit invalidates it and a stale figure is never served. Every figure the AI
explains is computed here, in SQL; Python only validates inputs and shapes rows."""
from __future__ import annotations

import re
import threading
import time
from decimal import Decimal

import trino

from .settings import get_settings

GROUP_CURRENCY = "USD"   # KSL of controlling area CL01
ACTUAL = "ACTUAL"        # version of the actuals in the gold views
BUDGET_CATEGORY = "BUDG"  # base budget: the reference of the deviation of an actual month
STABLE_BAND = 0.01       # the plan is "stable" once every later month stays within ±1 % of its last month
TOP_POSTINGS = 5
TOP_EFFECTS = 5
VERSION_TTL_S = 2.0      # one freshness probe per burst of queries (a request runs several)
GOLD = "lakehouse.gold"
PXQ_VIEW = f"{GOLD}.vw_opex_c1_pxq"
VARIANCE_VIEW = f"{GOLD}.vw_opex_c1_pxq_variance"
EFFECTS = ("price", "efficiency", "volume", "spending")
COST_CENTER = re.compile(r"^[A-Z0-9_]{1,10}$")  # KOSTL, CHAR 10
CATEGORY = re.compile(r"^[A-Z0-9_]{1,10}$")
KEY_FIGURE = re.compile(r"^[A-Z0-9_]{1,6}$")
PERIOD = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


class LakehouseNotReady(RuntimeError):
    """Raised while the CDC has not created the silver tables yet."""


class AnalysisNotFound(LookupError):
    """Raised when a cost center or period has no actual data."""


def _connect():
    s = get_settings()
    return trino.dbapi.connect(host=s.trino_host, port=s.trino_port, user=s.trino_user, source="nodara-backend")


def query(sql: str, params: list | None = None) -> list[dict]:
    try:
        with _connect() as conn:
            cur = conn.cursor()
            cur.execute(sql, params)
            rows = cur.fetchall()
            columns = [c[0] for c in cur.description]
    except trino.exceptions.TrinoUserError as exc:
        if exc.error_name in ("TABLE_NOT_FOUND", "SCHEMA_NOT_FOUND"):
            raise LakehouseNotReady(exc.message) from exc
        raise
    return [{col: float(v) if isinstance(v, Decimal) else v for col, v in zip(columns, row)} for row in rows]


_lock = threading.Lock()
_results: dict[tuple, tuple[str, list[dict]]] = {}  # (sql, params) → (data version, rows)
_version: tuple[float, str] = (0.0, "")
_stats = {"hits": 0, "misses": 0}


def data_version() -> str:
    """Freshness token of the lakehouse: the latest Delta version of every bronze table (metadata only)."""
    global _version
    with _lock:
        if time.monotonic() - _version[0] < VERSION_TTL_S:
            return _version[1]
    row = query("""
        SELECT (SELECT max(version) FROM lakehouse.bronze."acdoca$history") AS acdoca,
               (SELECT max(version) FROM lakehouse.bronze."acdocp$history") AS acdocp,
               (SELECT max(version) FROM lakehouse.bronze."finsskf$history") AS finsskf""")[0]
    token = f"{row['acdoca']}.{row['acdocp']}.{row['finsskf']}"
    with _lock:
        _version = (time.monotonic(), token)
    return token


def cached(sql: str, params: list | None = None) -> list[dict]:
    """Query result kept in memory until the lakehouse changes (a new CDC commit in bronze)."""
    key, version = (sql, tuple(params or ())), data_version()
    with _lock:
        hit = _results.get(key)
        if hit and hit[0] == version:
            _stats["hits"] += 1
            return hit[1]
        _stats["misses"] += 1
    rows = query(sql, params)
    with _lock:
        _results[key] = (version, rows)
    return rows


def cache_stats() -> dict:
    with _lock:
        return {"entries": len(_results), **_stats, "data_version": _version[1]}


# Period key 'YYYY-MM' from FISCYEARPER 'YYYYPPP' (fiscal year variant K4: period = calendar month).
_PERIOD = "substr(fiscyearper, 1, 4) || '-' || substr(fiscyearper, 6, 2)"


def _validate(rcntr: str | None = None, category: str | None = None, period: str | None = None,
              stagr: str | None = None) -> None:
    if ((rcntr is not None and not COST_CENTER.match(rcntr)) or (category and not CATEGORY.match(category))
            or (period and not PERIOD.match(period)) or (stagr and not KEY_FIGURE.match(stagr))):
        raise ValueError(f"invalid cost center '{rcntr}', category '{category}', period '{period}' or key figure '{stagr}'")


def cost_centers() -> list[dict]:
    """Cost centers with actual data and/or plan data: their plan categories (the budget apart)."""
    return cached(f"""
        WITH a AS (SELECT rcntr, min({_PERIOD}) AS first_actual, max({_PERIOD}) AS last_actual
                     FROM lakehouse.silver.acdoca WHERE rcntr IS NOT NULL GROUP BY rcntr),
             p AS (SELECT rcntr, array_sort(array_agg(DISTINCT category) FILTER (WHERE category <> ?)) AS categories,
                          bool_or(category = ?) AS budget
                     FROM lakehouse.silver.acdocp GROUP BY rcntr)
        SELECT coalesce(a.rcntr, p.rcntr) AS rcntr, a.first_actual, a.last_actual,
               coalesce(p.categories, CAST(ARRAY[] AS array(varchar))) AS categories,
               coalesce(p.budget, false) AS budget
          FROM a FULL OUTER JOIN p ON p.rcntr = a.rcntr
         ORDER BY 1""", [BUDGET_CATEGORY, BUDGET_CATEGORY])


def _cutoff(period: str | None) -> str:
    """Latest actual month, or the latest up to the requested one (its placeholder comes first)."""
    return f"max({_PERIOD}) FILTER (WHERE {_PERIOD} <= ?)" if period else f"max({_PERIOD})"


def timeline(rcntr: str, category: str) -> list[dict]:
    """One row per month and account: the actual months with their budget alongside, then the plan
    months of the category; OPEX, driver and unit OPEX of each month and version."""
    _validate(rcntr, category)
    return cached(f"""
        WITH
        cutoff AS (SELECT max({_PERIOD}) AS period FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?),
        scoped AS (  -- actuals and their budget up to the last actual month, the plan after it
            SELECT v.version, v.period, v.racct, v.ksl, v.stagr, v.driver_unit, v.driver_qty,
                   sum(v.ksl) OVER (PARTITION BY v.version, v.period) AS opex
              FROM {PXQ_VIEW} v CROSS JOIN cutoff c
             WHERE v.rcntr = ? AND v.version IN (?, ?, ?) AND (v.version = ?) = (v.period > c.period)),
        compared AS (
            SELECT s.*, s.opex / nullif(s.driver_qty, 0) AS unit_cost,
                   max(if(s.version = ?, s.ksl)) OVER (PARTITION BY s.period, s.racct) AS budget_ksl,
                   max(if(s.version = ?, s.opex)) OVER (PARTITION BY s.period) AS budget_opex,
                   max(if(s.version = ?, s.driver_qty)) OVER (PARTITION BY s.period) AS budget_driver
              FROM scoped s)
        SELECT version AS kind, period, racct, ksl, opex, stagr, driver_unit, driver_qty, unit_cost,
               budget_ksl, budget_opex, budget_driver, budget_opex / nullif(budget_driver, 0) AS budget_unit_cost,
               round((opex - budget_opex) / nullif(budget_opex, 0) * 100, 1) AS opex_delta_budget_pct,
               round((unit_cost - budget_opex / nullif(budget_driver, 0)) / nullif(budget_opex / nullif(budget_driver, 0), 0)
                     * 100, 1) AS unit_delta_budget_pct
          FROM compared
         WHERE version <> ?
         ORDER BY period, racct""",
        [rcntr, GROUP_CURRENCY, rcntr, ACTUAL, BUDGET_CATEGORY, category, category,
         BUDGET_CATEGORY, BUDGET_CATEGORY, BUDGET_CATEGORY, BUDGET_CATEGORY])


def variance(rcntr: str, period: str | None = None) -> list[dict]:
    """P x Q deviation of the analyzed actual month (the requested one or the latest) against the budget:
    one row per account and effect, with the cost center totals alongside (window aggregates) and the rank
    of every effect (1 = the largest unfavorable amount, the origin of the deviation)."""
    _validate(rcntr, period=period)
    rows = cached(f"""
        WITH
        frame AS (SELECT {_cutoff(period)} AS period FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?),
        lines AS (
            SELECT v.*,
                   sum(v.actual_ksl) OVER () AS opex_actual, sum(v.budget_ksl) OVER () AS opex_budget,
                   sum(v.flex_ksl) OVER () AS opex_flex,
                   sum(v.price_effect) OVER () AS total_price, sum(v.efficiency_effect) OVER () AS total_efficiency,
                   sum(v.volume_effect) OVER () AS total_volume, sum(v.spending_effect) OVER () AS total_spending
              FROM {VARIANCE_VIEW} v JOIN frame f ON v.period = f.period
             WHERE v.rcntr = ?),
        totals AS (
            SELECT l.*,
                   round(opex_actual - opex_budget, 2) AS opex_variance,
                   round((opex_actual - opex_budget) / nullif(opex_budget, 0) * 100, 1) AS opex_variance_pct,
                   round((actual_driver - budget_driver) / nullif(budget_driver, 0) * 100, 1) AS driver_pct,
                   opex_actual / nullif(actual_driver, 0) AS unit_actual,
                   opex_budget / nullif(budget_driver, 0) AS unit_budget
              FROM lines l)
        SELECT t.*, round((unit_actual - unit_budget) / nullif(unit_budget, 0) * 100, 1) AS unit_pct,
               e.effect, e.amount, row_number() OVER (ORDER BY e.amount DESC NULLS LAST, t.racct) AS effect_rank
          FROM totals t
         CROSS JOIN UNNEST(ARRAY['price', 'efficiency', 'volume', 'spending'],
                           ARRAY[t.price_effect, t.efficiency_effect, t.volume_effect, t.spending_effect])
               AS e(effect, amount)
         ORDER BY t.racct, e.effect""",
        ([period] if period else []) + [rcntr, GROUP_CURRENCY, rcntr])
    # A requested month must be an actual period itself, never the closest earlier one.
    return [] if rows and period and rows[0]["period"] != period else rows


def matrix(period: str | None = None) -> list[dict]:
    """P x Q matrix of every cost center for the latest actual month (or the requested one): one row per
    cost center and account with the cost center totals and its top unfavorable effect."""
    _validate(period=period)
    return cached(f"""
        WITH
        frame AS (SELECT {_cutoff(period)} AS period FROM lakehouse.silver.acdoca WHERE rcntr IS NOT NULL AND rkcur = ?),
        lines AS (
            SELECT v.*,
                   sum(v.actual_ksl) OVER (PARTITION BY v.rcntr) AS opex_actual,
                   sum(v.budget_ksl) OVER (PARTITION BY v.rcntr) AS opex_budget
              FROM {VARIANCE_VIEW} v JOIN frame f ON v.period = f.period),
        ranked AS (  -- the largest unfavorable effect of each cost center: account and effect
            SELECT l.rcntr, e.effect, e.amount, l.racct,
                   row_number() OVER (PARTITION BY l.rcntr ORDER BY e.amount DESC NULLS LAST, l.racct) AS rk
              FROM lines l
             CROSS JOIN UNNEST(ARRAY['price', 'efficiency', 'volume', 'spending'],
                               ARRAY[l.price_effect, l.efficiency_effect, l.volume_effect, l.spending_effect])
                   AS e(effect, amount))
        SELECT l.*, round(l.opex_actual - l.opex_budget, 2) AS opex_variance,
               round((l.opex_actual - l.opex_budget) / nullif(l.opex_budget, 0) * 100, 1) AS opex_variance_pct,
               round((l.actual_driver - l.budget_driver) / nullif(l.budget_driver, 0) * 100, 1) AS driver_pct,
               l.opex_actual / nullif(l.actual_driver, 0) AS unit_actual,
               l.opex_budget / nullif(l.budget_driver, 0) AS unit_budget,
               round((l.opex_actual / nullif(l.actual_driver, 0) - l.opex_budget / nullif(l.budget_driver, 0))
                     / nullif(l.opex_budget / nullif(l.budget_driver, 0), 0) * 100, 1) AS unit_pct,
               if(r.amount > 0, r.racct) AS origin_racct, if(r.amount > 0, r.effect) AS origin_effect,
               if(r.amount > 0, r.amount) AS origin_amount
          FROM lines l
          LEFT JOIN ranked r ON r.rcntr = l.rcntr AND r.rk = 1
         ORDER BY l.rcntr, l.racct""", ([period] if period else []) + [GROUP_CURRENCY])


def forecast(rcntr: str, category: str, period: str) -> dict:
    """Plan horizon after the actuals: first and last month, totals, stabilization point of the unit OPEX
    and the last planned unit OPEX against the analyzed actual period (NULL when its driver is zero)."""
    _validate(rcntr, category, period)
    rows = cached(f"""
        WITH
        cutoff AS (SELECT max({_PERIOD}) AS period FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?),
        months AS (  -- plan months after the actuals and the analyzed actual month: OPEX, driver, unit OPEX
            SELECT v.version, v.period, sum(v.ksl) AS opex, max(v.driver_qty) AS driver_qty,
                   sum(v.ksl) / nullif(max(v.driver_qty), 0) AS unit_cost
              FROM {PXQ_VIEW} v CROSS JOIN cutoff c
             WHERE v.rcntr = ? AND ((v.version = ? AND v.period > c.period) OR (v.version = ? AND v.period = ?))
             GROUP BY v.version, v.period),
        anchored AS (
            SELECT m.*, max(if(m.version = ?, m.unit_cost)) OVER () AS reference_unit,
                   max_by(m.unit_cost, if(m.version <> ?, m.period)) OVER () AS last_unit
              FROM months m),
        banded AS (  -- largest deviation from the last planned unit OPEX from each plan month onwards
            SELECT a.*, max(if(a.version <> ?, abs(a.unit_cost - a.last_unit) / nullif(a.last_unit, 0)))
                            OVER (ORDER BY a.period ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS deviation
              FROM anchored a)
        SELECT count(*) FILTER (WHERE version <> ?) AS months,
               min(period) FILTER (WHERE version <> ?) AS first_period, max(period) FILTER (WHERE version <> ?) AS last_period,
               sum(opex) FILTER (WHERE version <> ?) AS total_opex,
               sum(opex) FILTER (WHERE version <> ?) / nullif(sum(driver_qty) FILTER (WHERE version <> ?), 0)
                   AS horizon_unit_cost,
               min_by(opex, if(version <> ?, period)) AS first_opex, min_by(unit_cost, if(version <> ?, period)) AS first_unit_cost,
               max_by(opex, if(version <> ?, period)) AS last_opex, max(last_unit) AS last_unit_cost,
               min(period) FILTER (WHERE version <> ? AND deviation <= {STABLE_BAND}) AS stable_from,
               round((max(last_unit) - max(reference_unit)) / nullif(max(reference_unit), 0) * 100, 1)
                   AS last_vs_period_pct
          FROM banded""",
        [rcntr, GROUP_CURRENCY, rcntr, category, ACTUAL, period, ACTUAL, ACTUAL, ACTUAL]
        + [ACTUAL] * 10)
    return rows[0] if rows and rows[0]["months"] else {"months": 0}


def top_postings(rcntr: str, period: str) -> list[dict]:
    """Largest cost center postings of the period (ACDOCA line items) with their quantity."""
    _validate(rcntr, period=period)
    return cached(f"""
        SELECT belnr, CAST(budat AS varchar) AS budat, racct, sgtxt, ksl, msl, runit
          FROM lakehouse.silver.acdoca
         WHERE rcntr = ? AND {_PERIOD} = ?
         ORDER BY ksl DESC, belnr
         LIMIT {TOP_POSTINGS}""", [rcntr, period])


def s4_live_summary() -> dict:
    """Row counts of the financial tables, read live from S/4HANA through Trino federation."""
    return query("""
        SELECT (SELECT count(*) FROM s4hana.sap.acdoca) AS acdoca_rows,
               (SELECT count(*) FROM s4hana.sap.acdocp) AS acdocp_rows,
               (SELECT count(*) FROM s4hana.sap.finsskf) AS finsskf_rows""")[0]


def cdc_freshness() -> dict:
    """How current the lakehouse is: CDC events landed in bronze and the latency of the last one."""
    return query("""
        SELECT count(*) AS events,
               max(_source_ts) AS last_source_commit,
               max(_ingested_at) AS last_ingested,
               max_by(date_diff('millisecond', _source_ts, _ingested_at), _ingested_at) AS last_lag_ms
          FROM (SELECT _source_ts, _ingested_at FROM lakehouse.bronze.acdoca
                UNION ALL SELECT _source_ts, _ingested_at FROM lakehouse.bronze.acdocp
                UNION ALL SELECT _source_ts, _ingested_at FROM lakehouse.bronze.finsskf)""")[0]
