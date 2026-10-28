"""Deterministic OPEX analytics in Trino over the lakehouse silver layer (current state of the SAP
tables replicated by CDC): monthly OPEX in group currency (KSL) per account, physical drivers
(FINSSKF) and unit OPEX, for the actuals (ACDOCA) against the base budget (ACDOCP · CATEGORY BUDG),
followed by a plan category (ACDOCP · CATEGORY, e.g. RF18M). Every figure the AI explains is computed
here, in SQL; Python only validates inputs and shapes rows."""
from __future__ import annotations

import re
from decimal import Decimal

import trino

from .settings import get_settings

GROUP_CURRENCY = "USD"   # KSL of controlling area CL01
BUDGET_CATEGORY = "BUDG"  # base budget: the reference of the deviation of an actual month
STABLE_BAND = 0.01       # the plan is "stable" once every later month stays within ±1 % of its last month
TOP_POSTINGS = 5
COST_CENTER = re.compile(r"^[A-Z0-9_]{1,20}$")
CATEGORY = re.compile(r"^[A-Z0-9_]{1,10}$")
KEY_FIGURE = re.compile(r"^[A-Z0-9_]{1,6}$")
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
# Month of a FINSSKF totals value (GRTYP 2: the quantity of the month that starts on DATE_FROM).
_SKF_PERIOD = "substr(CAST(date_from AS varchar), 1, 7)"


def _decimals(runit: str) -> str:
    """Decimals of a unit OPEX by the unit of its driver: USD/h with 2, per tonne (TO, WMT) with 4."""
    return f"CASE {runit} WHEN 'H' THEN 2 ELSE 4 END"


def _validate(rcntr: str, category: str | None = None, period: str | None = None, stagr: str | None = None) -> None:
    if (not COST_CENTER.match(rcntr) or (category and not CATEGORY.match(category))
            or (period and not PERIOD.match(period)) or (stagr and not KEY_FIGURE.match(stagr))):
        raise ValueError(f"invalid cost center '{rcntr}', category '{category}', period '{period}' or key figure '{stagr}'")


def cost_centers() -> list[dict]:
    """Cost centers with actual data and/or plan data: their plan categories (the budget apart)."""
    return query(f"""
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


def timeline(rcntr: str, category: str) -> list[dict]:
    """One row per month and item (cost element or driver): the actual months with their budget
    alongside, then the plan months of the category. Unit OPEX = month OPEX / driver of the same month
    and version; the deviation of an actual month = actual - budget."""
    _validate(rcntr, category)
    return query(f"""
        WITH
        actual AS (
            SELECT {_PERIOD} AS period, racct, sum(ksl) AS ksl
              FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ? GROUP BY 1, 2),
        cutoff AS (SELECT max(period) AS period FROM actual),
        items AS (  -- version: actual | budget | plan · item: cost element (KSL) or driver (FINSSKF)
            SELECT 'actual' AS version, period, 'account' AS item, racct AS key, CAST(NULL AS varchar) AS runit,
                   CAST(ksl AS decimal(38, 3)) AS value
              FROM actual
            UNION ALL
            SELECT if(category = ?, 'budget', 'plan'), {_PERIOD}, 'account', racct, NULL, CAST(ksl AS decimal(38, 3))
              FROM lakehouse.silver.acdocp WHERE rcntr = ? AND rkcur = ? AND category IN (?, ?)
            UNION ALL
            SELECT CASE WHEN rrcty = '0' THEN 'actual' WHEN category = ? THEN 'budget' ELSE 'plan' END,
                   {_SKF_PERIOD}, 'driver', stagr, runit, CAST(msl AS decimal(38, 3))
              FROM lakehouse.silver.finsskf
             WHERE rcntr = ? AND grtyp = '2' AND (rrcty = '0' OR (rrcty = '1' AND category IN (?, ?)))),
        scoped AS (  -- actuals and their budget up to the last actual month, the plan after it
            SELECT i.version, i.period, i.item, i.key, max(i.runit) AS runit, sum(i.value) AS value
              FROM items i CROSS JOIN cutoff c
             WHERE (i.version = 'plan') = (i.period > c.period)
             GROUP BY 1, 2, 3, 4),
        totals AS (
            SELECT s.*, sum(if(s.item = 'account', s.value)) OVER (PARTITION BY s.version, s.period) AS opex
              FROM scoped s),
        unitized AS (
            SELECT t.*, if(t.item = 'driver', round(CAST(t.opex AS double) / nullif(CAST(t.value AS double), 0),
                                                     {_decimals('t.runit')})) AS unit_cost
              FROM totals t),
        compared AS (  -- every row next to the budget of the same month and item
            SELECT u.*,
                   max(if(u.version = 'budget', u.value)) OVER (PARTITION BY u.period, u.item, u.key) AS budget_value,
                   max(if(u.version = 'budget', u.unit_cost)) OVER (PARTITION BY u.period, u.item, u.key) AS budget_unit_cost,
                   max(if(u.version = 'budget', u.opex)) OVER (PARTITION BY u.period) AS budget_opex
              FROM unitized u)
        SELECT version AS kind, period, item, key, runit, if(item = 'driver', {_decimals('runit')}) AS decimals,
               CAST(value AS double) AS value, CAST(opex AS double) AS opex, unit_cost,
               CAST(budget_value AS double) AS budget_value, budget_unit_cost, CAST(budget_opex AS double) AS budget_opex,
               CAST(opex - budget_opex AS double) AS opex_delta_budget,
               round(CAST(opex - budget_opex AS double) / nullif(CAST(budget_opex AS double), 0) * 100, 1)
                   AS opex_delta_budget_pct,
               round((unit_cost - budget_unit_cost) / nullif(budget_unit_cost, 0) * 100, 1) AS unit_delta_budget_pct
          FROM compared
         WHERE version <> 'budget'
         ORDER BY period, item, key""",
        [rcntr, GROUP_CURRENCY, BUDGET_CATEGORY, rcntr, GROUP_CURRENCY, BUDGET_CATEGORY, category,
         BUDGET_CATEGORY, rcntr, BUDGET_CATEGORY, category])


def variance(rcntr: str, period: str | None = None) -> list[dict]:
    """Deviation of the analyzed actual month (the requested one or the latest) = actual - budget (BUDG),
    with the previous actual month as context: per cost element, total OPEX, every driver and its unit
    OPEX. One pass over each silver table (Trino inlines a CTE on every reference)."""
    _validate(rcntr, period=period)
    rows = query(f"""
        WITH
        periods AS (  -- actual months up to the analyzed one, newest first (rk 1 analyzed, 2 previous)
            SELECT period, dense_rank() OVER (ORDER BY period DESC) AS rk
              FROM (SELECT DISTINCT {_PERIOD} AS period FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?) a
             {"WHERE period <= ?" if period else ""}),
        frame AS (
            SELECT max(period) FILTER (WHERE rk = 1) AS period, max(period) FILTER (WHERE rk = 2) AS previous_period
              FROM periods),
        series AS (  -- actual (ACDOCA, FINSSKF RRCTY 0) and budget (ACDOCP, FINSSKF CATEGORY BUDG) values
            SELECT 'actual' AS version, {_PERIOD} AS period, 'account' AS kind, racct AS metric,
                   CAST(NULL AS varchar) AS runit, CAST(ksl AS decimal(38, 3)) AS value
              FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?
            UNION ALL
            SELECT 'budget', {_PERIOD}, 'account', racct, NULL, CAST(ksl AS decimal(38, 3))
              FROM lakehouse.silver.acdocp WHERE rcntr = ? AND rkcur = ? AND category = ?
            UNION ALL
            SELECT if(rrcty = '0', 'actual', 'budget'), {_SKF_PERIOD}, 'driver', stagr, runit, CAST(msl AS decimal(38, 3))
              FROM lakehouse.silver.finsskf
             WHERE rcntr = ? AND grtyp = '2' AND (rrcty = '0' OR (rrcty = '1' AND category = ?))),
        pivot AS (  -- per metric: analyzed month (actual and budget) and previous month (actual)
            SELECT s.kind, s.metric, max(s.runit) AS runit, f.period, f.previous_period,
                   CAST(sum(s.value) FILTER (WHERE s.version = 'actual' AND s.period = f.period) AS double) AS cur,
                   CAST(sum(s.value) FILTER (WHERE s.version = 'budget') AS double) AS bud,
                   CAST(sum(s.value) FILTER (WHERE s.version = 'actual' AND s.period = f.previous_period) AS double) AS prev
              FROM series s CROSS JOIN frame f
             WHERE (s.version = 'actual' AND (s.period = f.period OR s.period = f.previous_period))
                OR (s.version = 'budget' AND s.period = f.period)
             GROUP BY s.kind, s.metric, f.period, f.previous_period),
        windowed AS (  -- month OPEX (sum of the cost elements) next to every metric
            SELECT p.*,
                   sum(if(p.kind = 'account', p.cur)) OVER () AS opex_cur,
                   sum(if(p.kind = 'account', p.bud)) OVER () AS opex_bud,
                   sum(if(p.kind = 'account', p.prev)) OVER () AS opex_prev,
                   count(if(p.kind = 'account', p.bud)) OVER () AS budget_lines,
                   row_number() OVER (ORDER BY p.kind, p.metric) AS rn
              FROM pivot p),
        lines AS (  -- each metric as is, plus the OPEX total (once) and the unit OPEX of every driver
            SELECT if(v.variant = 'self', w.kind, v.variant) AS kind, if(v.variant = 'opex', 'OPEX', w.metric) AS metric,
                   if(v.variant = 'opex', NULL, w.runit) AS runit,
                   if(v.variant = 'unit', {_decimals('w.runit')}) AS decimals,
                   w.period, w.previous_period, w.opex_cur,
                   CASE v.variant WHEN 'opex' THEN w.opex_cur
                                  WHEN 'unit' THEN round(w.opex_cur / nullif(w.cur, 0), {_decimals('w.runit')})
                                  ELSE if(w.kind = 'account', coalesce(w.cur, 0), w.cur) END AS cur,
                   CASE WHEN w.budget_lines = 0 THEN NULL
                        WHEN v.variant = 'opex' THEN w.opex_bud
                        WHEN v.variant = 'unit' THEN round(w.opex_bud / nullif(w.bud, 0), {_decimals('w.runit')})
                        ELSE if(w.kind = 'account', coalesce(w.bud, 0), w.bud) END AS bud,
                   CASE WHEN w.previous_period IS NULL THEN NULL
                        WHEN v.variant = 'opex' THEN w.opex_prev
                        WHEN v.variant = 'unit' THEN round(w.opex_prev / nullif(w.prev, 0), {_decimals('w.runit')})
                        ELSE if(w.kind = 'account', coalesce(w.prev, 0), w.prev) END AS prev
              FROM windowed w
             CROSS JOIN UNNEST(ARRAY['self', 'opex', 'unit']) AS v(variant)
             WHERE v.variant = 'self' OR (v.variant = 'opex' AND w.rn = 1) OR (v.variant = 'unit' AND w.kind = 'driver'))
        SELECT kind, metric, runit, decimals, period, previous_period,
               round(cur, 4) AS current, round(bud, 4) AS budget, round(prev, 4) AS previous,
               round(cur - bud, 4) AS delta_budget, round((cur - bud) / nullif(bud, 0) * 100, 1) AS delta_budget_pct,
               round(cur - prev, 4) AS delta_previous, round((cur - prev) / nullif(prev, 0) * 100, 1) AS delta_previous_pct,
               if(kind = 'account', round(cur / nullif(opex_cur, 0) * 100, 1)) AS share_pct
          FROM lines
         WHERE period IS NOT NULL
         ORDER BY kind, metric""",
        [rcntr, GROUP_CURRENCY] + ([period] if period else [])
        + [rcntr, GROUP_CURRENCY, rcntr, GROUP_CURRENCY, BUDGET_CATEGORY, rcntr, BUDGET_CATEGORY])
    # A requested month must be an actual period itself, never the closest earlier one.
    return [] if rows and period and rows[0]["period"] != period else rows


def forecast(rcntr: str, category: str, period: str, stagr: str) -> dict:
    """Plan horizon after the actuals: first and last month, totals, stabilization point and the last
    planned unit OPEX (per driver STAGR) against the analyzed actual period."""
    _validate(rcntr, category, period, stagr)
    rows = query(f"""
        WITH
        cutoff AS (SELECT max({_PERIOD}) AS period FROM lakehouse.silver.acdoca WHERE rcntr = ? AND rkcur = ?),
        fc AS (  -- plan months after the actuals with OPEX, planned driver and unit OPEX
            SELECT p.period, p.opex, d.quantity, d.runit,
                   round(CAST(p.opex AS double) / nullif(CAST(d.quantity AS double), 0), {_decimals('d.runit')}) AS unit_cost
              FROM (SELECT {_PERIOD} AS period, sum(ksl) AS opex FROM lakehouse.silver.acdocp
                     WHERE rcntr = ? AND rkcur = ? AND category = ? GROUP BY 1) p
              LEFT JOIN (SELECT {_SKF_PERIOD} AS period, sum(msl) AS quantity, max(runit) AS runit
                           FROM lakehouse.silver.finsskf
                          WHERE rcntr = ? AND rrcty = '1' AND category = ? AND grtyp = '2' AND stagr = ?
                          GROUP BY 1) d ON d.period = p.period
             CROSS JOIN cutoff c
             WHERE p.period > c.period),
        anchored AS (SELECT f.*, max_by(f.unit_cost, f.period) OVER () AS last_unit FROM fc f),
        banded AS (  -- largest deviation from the last planned unit OPEX from each month onwards
            SELECT a.*, max(abs(a.unit_cost - a.last_unit) / a.last_unit)
                            OVER (ORDER BY a.period ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS deviation
              FROM anchored a),
        reference AS (  -- unit OPEX of the analyzed actual period
            SELECT round(CAST(o.opex AS double) / nullif(CAST(q.quantity AS double), 0), {_decimals('q.runit')}) AS unit_cost
              FROM (SELECT sum(ksl) AS opex FROM lakehouse.silver.acdoca
                     WHERE rcntr = ? AND rkcur = ? AND {_PERIOD} = ?) o
             CROSS JOIN (SELECT sum(msl) AS quantity, max(runit) AS runit FROM lakehouse.silver.finsskf
                          WHERE rcntr = ? AND rrcty = '0' AND grtyp = '2' AND stagr = ? AND {_SKF_PERIOD} = ?) q)
        SELECT count(*) AS months, min(b.period) AS first_period, max(b.period) AS last_period, ? AS stagr,
               max(b.runit) AS runit, max({_decimals('b.runit')}) AS decimals,
               CAST(sum(b.opex) AS double) AS total_opex,
               round(CAST(sum(b.opex) AS double) / nullif(CAST(sum(b.quantity) AS double), 0), max({_decimals('b.runit')}))
                   AS horizon_unit_cost,
               CAST(min_by(b.opex, b.period) AS double) AS first_opex, min_by(b.unit_cost, b.period) AS first_unit_cost,
               CAST(max_by(b.opex, b.period) AS double) AS last_opex, max_by(b.unit_cost, b.period) AS last_unit_cost,
               min(b.period) FILTER (WHERE b.deviation <= {STABLE_BAND}) AS stable_from,
               round((max_by(b.unit_cost, b.period) - arbitrary(r.unit_cost)) / arbitrary(r.unit_cost) * 100, 1)
                   AS last_vs_period_pct
          FROM banded b CROSS JOIN reference r""",
        [rcntr, GROUP_CURRENCY, rcntr, GROUP_CURRENCY, category, rcntr, category, stagr,
         rcntr, GROUP_CURRENCY, period, rcntr, stagr, period, stagr])
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
