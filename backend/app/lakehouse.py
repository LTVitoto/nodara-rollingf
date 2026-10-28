"""Deterministic OPEX analytics in Trino over the lakehouse silver layer (current state of the SAP
tables replicated by CDC): monthly OPEX in group currency (KSL) per account, physical drivers
(FINSSKF) and unit OPEX, for the actuals (ACDOCA) followed by a plan category (ACDOCP · CATEGORY).
Every figure the AI explains is computed here, in SQL; Python only validates inputs and shapes rows."""
from __future__ import annotations

import re
from decimal import Decimal

import trino

from .settings import get_settings

GROUP_CURRENCY = "USD"  # KSL of controlling area CL01
STABLE_BAND = 0.01      # the plan is "stable" once every later month stays within ±1 % of its last month
TOP_POSTINGS = 5
COST_CENTER = re.compile(r"^[A-Z0-9_]{1,20}$")
CATEGORY = re.compile(r"^[A-Z0-9_]{1,10}$")
PERIOD = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


class LakehouseNotReady(RuntimeError):
    """Raised while the CDC has not created the silver tables yet."""


class AnalysisNotFound(LookupError):
    """Raised when a cost center or period has no actual data."""


def query(sql: str, params: list | None = None) -> list[dict]:
    s = get_settings()
    try:
        with trino.dbapi.connect(host=s.trino_host, port=s.trino_port, user=s.trino_user,
                                 source="nodara-backend") as conn:
            cur = conn.cursor()
            cur.execute(sql, params)
            rows = cur.fetchall()
            columns = [c[0] for c in cur.description]
    except trino.exceptions.TrinoUserError as exc:
        if exc.error_name in ("TABLE_NOT_FOUND", "SCHEMA_NOT_FOUND"):
            raise LakehouseNotReady(exc.message) from exc
        raise
    return [{col: float(v) if isinstance(v, Decimal) else v for col, v in zip(columns, row)} for row in rows]


# Period key 'YYYY-MM' from FISCYEARPER 'YYYYPPP' (fiscal year variant K4: period = calendar month).
_PERIOD = "substr(fiscyearper, 1, 4) || '-' || substr(fiscyearper, 6, 2)"

# Monthly OPEX per account: actual periods (ACDOCA) and, after the last of them, the plan category
# (ACDOCP). Unit OPEX = OPEX / driver of the same month and record type (FINSSKF totals values).
# Parameters: rcntr, currency, rcntr, currency, category, rcntr, category.
_MONTHS = f"""
    actual AS (
        SELECT {_PERIOD} AS period, racct, sum(ksl) AS ksl
          FROM lakehouse.silver.acdoca
         WHERE rcntr = ? AND rkcur = ?
         GROUP BY 1, 2),
    cutoff AS (SELECT max(period) AS period FROM actual),
    plan AS (
        SELECT {_PERIOD} AS period, racct, sum(ksl) AS ksl
          FROM lakehouse.silver.acdocp
         WHERE rcntr = ? AND rkcur = ? AND category = ?
         GROUP BY 1, 2),
    costs AS (
        SELECT 'actual' AS kind, period, racct, ksl FROM actual
        UNION ALL
        SELECT 'plan', p.period, p.racct, p.ksl FROM plan p CROSS JOIN cutoff c WHERE p.period > c.period),
    drivers AS (
        SELECT CASE rrcty WHEN '0' THEN 'actual' ELSE 'plan' END AS kind,
               substr(CAST(date_from AS varchar), 1, 7) AS period,
               sum(msl) FILTER (WHERE stagr = 'HOROP') AS hours,
               sum(msl) FILTER (WHERE stagr = 'TONMOV') AS tonnes
          FROM lakehouse.silver.finsskf
         WHERE rcntr = ? AND grtyp = '2' AND (rrcty = '0' OR (rrcty = '1' AND category = ?))
         GROUP BY 1, 2),
    months AS (
        SELECT c.kind, c.period, sum(c.ksl) AS opex, d.hours, d.tonnes,
               round(CAST(sum(c.ksl) AS double) / nullif(CAST(d.hours AS double), 0), 2) AS usd_per_hour,
               round(CAST(sum(c.ksl) AS double) / nullif(CAST(d.tonnes AS double), 0), 4) AS usd_per_tonne
          FROM costs c
          LEFT JOIN drivers d ON d.kind = c.kind AND d.period = c.period
         GROUP BY c.kind, c.period, d.hours, d.tonnes)"""


def _months_params(rcntr: str, category: str) -> list:
    return [rcntr, GROUP_CURRENCY, rcntr, GROUP_CURRENCY, category, rcntr, category]


def _validate(rcntr: str, category: str | None = None, period: str | None = None) -> None:
    if (not COST_CENTER.match(rcntr) or (category and not CATEGORY.match(category))
            or (period and not PERIOD.match(period))):
        raise ValueError(f"invalid cost center '{rcntr}', plan category '{category}' or period '{period}'")


def cost_centers() -> list[dict]:
    """Cost centers with actual data and/or plan categories, from the silver layer."""
    return query(f"""
        WITH a AS (SELECT rcntr, min({_PERIOD}) AS first_actual, max({_PERIOD}) AS last_actual
                     FROM lakehouse.silver.acdoca WHERE rcntr IS NOT NULL GROUP BY rcntr),
             p AS (SELECT rcntr, array_sort(array_agg(DISTINCT category)) AS categories
                     FROM lakehouse.silver.acdocp GROUP BY rcntr)
        SELECT coalesce(a.rcntr, p.rcntr) AS rcntr, a.first_actual, a.last_actual,
               coalesce(p.categories, CAST(ARRAY[] AS array(varchar))) AS categories
          FROM a FULL OUTER JOIN p ON p.rcntr = a.rcntr
         ORDER BY 1""")


def timeline(rcntr: str, category: str) -> list[dict]:
    """One row per month and account: actual months, then the plan months of the category."""
    _validate(rcntr, category)
    return query(f"""
        WITH {_MONTHS}
        SELECT m.kind, m.period, m.opex, m.hours, m.tonnes, m.usd_per_hour, m.usd_per_tonne, c.racct, c.ksl
          FROM months m
          JOIN costs c ON c.kind = m.kind AND c.period = m.period
         ORDER BY m.period, c.racct""", _months_params(rcntr, category))


def variance(rcntr: str, category: str, period: str | None = None) -> list[dict]:
    """Analyzed actual period (the requested one or the latest) vs the previous actual month and vs the
    baseline (average of every earlier actual month): per cost element, total OPEX, drivers and unit OPEX.
    Each silver table is read a few times only: Trino inlines CTEs on every reference."""
    _validate(rcntr, category, period)
    rows = query(f"""
        WITH
        periods AS (  -- actual months up to the analyzed one, newest first (rk 1 analyzed, 2 previous)
            SELECT period, dense_rank() OVER (ORDER BY period DESC) AS rk
              FROM (SELECT DISTINCT {_PERIOD} AS period FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?) a
             {"WHERE period <= ?" if period else ""}),
        series AS (  -- actual values per month: cost elements, total OPEX and drivers
            SELECT {_PERIOD} AS period, racct AS metric, CAST(ksl AS decimal(38, 3)) AS value
              FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?
            UNION ALL
            SELECT {_PERIOD}, 'OPEX', CAST(ksl AS decimal(38, 3))
              FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?
            UNION ALL
            SELECT substr(CAST(date_from AS varchar), 1, 7), stagr, CAST(msl AS decimal(38, 3))
              FROM lakehouse.silver.finsskf
             WHERE rcntr = ? AND rrcty = '0' AND grtyp = '2' AND stagr IN ('HOROP', 'TONMOV')),
        pivot AS (
            SELECT s.metric,
                   sum(s.value) FILTER (WHERE p.rk = 1) AS cur,
                   sum(s.value) FILTER (WHERE p.rk = 2) AS prev,
                   sum(s.value) FILTER (WHERE p.rk > 1) AS history,
                   max(p.period) FILTER (WHERE p.rk = 1) AS period
              FROM series s JOIN periods p ON p.period = s.period
             GROUP BY s.metric),
        framed AS (  -- every metric with the analyzed frame and the OPEX / driver figures alongside
            SELECT v.metric, v.period, f.previous_period, f.baseline_months, f.baseline_from,
                   CAST(v.cur AS double) AS cur, CAST(v.prev AS double) AS prev,
                   CAST(v.history / nullif(f.baseline_months, 0) AS double) AS base
              FROM pivot v
             CROSS JOIN (SELECT max(period) FILTER (WHERE rk = 2) AS previous_period, count(*) - 1 AS baseline_months,
                                min(period) FILTER (WHERE rk > 1) AS baseline_from
                           FROM periods) f),
        windowed AS (
            SELECT w.*, max(w.period) OVER () AS target,
                   max(CASE WHEN w.metric = 'OPEX' THEN w.cur END) OVER () AS opex_cur,
                   max(CASE WHEN w.metric = 'OPEX' THEN w.prev END) OVER () AS opex_prev,
                   max(CASE WHEN w.metric = 'OPEX' THEN w.base END) OVER () AS opex_base,
                   max(CASE WHEN w.metric = 'HOROP' THEN w.cur END) OVER () AS hours_cur,
                   max(CASE WHEN w.metric = 'HOROP' THEN w.prev END) OVER () AS hours_prev,
                   max(CASE WHEN w.metric = 'HOROP' THEN w.base END) OVER () AS hours_base,
                   max(CASE WHEN w.metric = 'TONMOV' THEN w.cur END) OVER () AS tonnes_cur,
                   max(CASE WHEN w.metric = 'TONMOV' THEN w.prev END) OVER () AS tonnes_prev,
                   max(CASE WHEN w.metric = 'TONMOV' THEN w.base END) OVER () AS tonnes_base
              FROM framed w),
        lines AS (  -- unit OPEX = OPEX / driver, rounded like the timeline (USD/H 2, USD/TO 4 decimals)
            SELECT metric, target, previous_period, baseline_months, baseline_from, cur, prev, base, opex_cur
              FROM windowed
            UNION ALL
            SELECT u.metric, w.target, w.previous_period, w.baseline_months, w.baseline_from, u.cur, u.prev, u.base,
                   w.opex_cur
              FROM windowed w
             CROSS JOIN UNNEST(ARRAY['USD_H', 'USD_T'],
                               ARRAY[round(w.opex_cur / nullif(w.hours_cur, 0), 2),
                                     round(w.opex_cur / nullif(w.tonnes_cur, 0), 4)],
                               ARRAY[round(w.opex_prev / nullif(w.hours_prev, 0), 2),
                                     round(w.opex_prev / nullif(w.tonnes_prev, 0), 4)],
                               ARRAY[round(w.opex_base / nullif(w.hours_base, 0), 2),
                                     round(w.opex_base / nullif(w.tonnes_base, 0), 4)]) AS u(metric, cur, prev, base)
             WHERE w.metric = 'OPEX')
        SELECT metric, target AS period, previous_period, baseline_months, baseline_from,
               previous_period AS baseline_to,
               round(cur, 4) AS current, round(prev, 4) AS previous, round(base, 4) AS baseline,
               round(cur - prev, 4) AS delta_previous,
               round((cur - prev) / nullif(prev, 0) * 100, 1) AS delta_previous_pct,
               round(cur - base, 4) AS delta_baseline,
               round((cur - base) / nullif(base, 0) * 100, 1) AS delta_baseline_pct,
               CASE WHEN metric NOT IN ('OPEX', 'HOROP', 'TONMOV', 'USD_H', 'USD_T')
                    THEN round(cur / nullif(opex_cur, 0) * 100, 1) END AS share_pct
          FROM lines
         WHERE target IS NOT NULL
         ORDER BY metric""",
        [rcntr, GROUP_CURRENCY] + ([period] if period else []) + [rcntr, GROUP_CURRENCY, rcntr, GROUP_CURRENCY, rcntr])
    # A requested month must be an actual period itself, never the closest earlier one.
    return [] if rows and period and rows[0]["period"] != period else rows


def forecast(rcntr: str, category: str, period: str) -> dict:
    """Plan horizon after the actuals: first and last month, totals, stabilization point and the last
    planned unit OPEX against the analyzed actual period."""
    _validate(rcntr, category, period)
    rows = query(f"""
        WITH
        cutoff AS (SELECT max({_PERIOD}) AS period FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?),
        fc AS (  -- plan months after the actuals with OPEX, planned hours and unit OPEX
            SELECT p.period, p.opex, d.hours,
                   round(CAST(p.opex AS double) / nullif(CAST(d.hours AS double), 0), 2) AS usd_per_hour
              FROM (SELECT {_PERIOD} AS period, sum(ksl) AS opex FROM lakehouse.silver.acdocp
                     WHERE rcntr = ? AND rkcur = ? AND category = ? GROUP BY 1) p
              LEFT JOIN (SELECT substr(CAST(date_from AS varchar), 1, 7) AS period, sum(msl) AS hours
                           FROM lakehouse.silver.finsskf
                          WHERE rcntr = ? AND rrcty = '1' AND category = ? AND grtyp = '2' AND stagr = 'HOROP'
                          GROUP BY 1) d ON d.period = p.period
             CROSS JOIN cutoff c
             WHERE p.period > c.period),
        anchored AS (SELECT f.*, max_by(f.usd_per_hour, f.period) OVER () AS last_unit FROM fc f),
        banded AS (  -- largest deviation from the last planned unit OPEX from each month onwards
            SELECT a.*, max(abs(a.usd_per_hour - a.last_unit) / a.last_unit)
                            OVER (ORDER BY a.period ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS deviation
              FROM anchored a),
        reference AS (  -- unit OPEX of the analyzed actual period
            SELECT round(CAST(o.opex AS double) / nullif(CAST(h.hours AS double), 0), 2) AS usd_per_hour
              FROM (SELECT sum(ksl) AS opex FROM lakehouse.silver.acdoca
                     WHERE rcntr = ? AND rkcur = ? AND {_PERIOD} = ?) o
             CROSS JOIN (SELECT sum(msl) AS hours FROM lakehouse.silver.finsskf
                          WHERE rcntr = ? AND rrcty = '0' AND grtyp = '2' AND stagr = 'HOROP'
                            AND substr(CAST(date_from AS varchar), 1, 7) = ?) h)
        SELECT count(*) AS months, min(b.period) AS first_period, max(b.period) AS last_period,
               CAST(sum(b.opex) AS double) AS total_opex,
               round(CAST(sum(b.opex) AS double) / nullif(CAST(sum(b.hours) AS double), 0), 2) AS horizon_usd_per_hour,
               CAST(min_by(b.opex, b.period) AS double) AS first_opex, min_by(b.usd_per_hour, b.period) AS first_usd_per_hour,
               CAST(max_by(b.opex, b.period) AS double) AS last_opex, max_by(b.usd_per_hour, b.period) AS last_usd_per_hour,
               min(b.period) FILTER (WHERE b.deviation <= {STABLE_BAND}) AS stable_from,
               round((max_by(b.usd_per_hour, b.period) - arbitrary(r.usd_per_hour)) / arbitrary(r.usd_per_hour) * 100, 1)
                   AS last_vs_period_pct
          FROM banded b CROSS JOIN reference r""",
        [rcntr, GROUP_CURRENCY, rcntr, GROUP_CURRENCY, category, rcntr, category,
         rcntr, GROUP_CURRENCY, period, rcntr, period])
    return rows[0] if rows and rows[0]["months"] else {"months": 0}


def top_postings(rcntr: str, period: str) -> list[dict]:
    """Largest cost center postings of the period (ACDOCA line items)."""
    _validate(rcntr, period=period)
    return query(f"""
        SELECT belnr, CAST(budat AS varchar) AS budat, racct, sgtxt, ksl
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
