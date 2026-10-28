"""Deterministic OPEX C1 analytics in Trino over the lakehouse (current state of the SAP tables replicated
by CDC). The gold layer publishes two views, generated here from the master data:
  vw_opex_c1_pxq           master P x Q view: one row per version (ACTUAL, BUDG, RF18M), month, cost center
                           (RCNTR) and G/L account (RACCT) — cost KSL, quantity MSL in its own unit RUOM (units
                           are never added across accounts), price, driver (FINSSKF) and specific consumption
  vw_opex_c1_pxq_variance  actual vs base budget (BUDG) on a flexible budget (fixed share KFSL / VMFSL stays,
                           the variable share follows the driver): price P, efficiency Q, volume and spending
Every figure the AI explains is computed here, in SQL; Python only validates inputs and shapes rows.
Divisions go through nullif: a zero driver (e.g. no shipments) yields NULL, never an error."""
from __future__ import annotations

import re
import threading
from decimal import Decimal

import trino

from . import masterdata
from .settings import get_settings

GROUP_CURRENCY = "USD"   # KSL of controlling area CL01
ACTUAL = "ACTUAL"        # version of the actuals in the gold views
BUDGET_CATEGORY = "BUDG"  # base budget: the reference of the deviation of an actual month
STABLE_BAND = 0.01       # the plan is "stable" once every later month stays within ±1 % of its last month
TOP_POSTINGS = 5
TOP_EFFECTS = 5
GOLD = "lakehouse.gold"
PXQ_VIEW = f"{GOLD}.vw_opex_c1_pxq"
VARIANCE_VIEW = f"{GOLD}.vw_opex_c1_pxq_variance"
EFFECTS = ("price", "efficiency", "volume", "spending")
COST_CENTER = re.compile(r"^[A-Z0-9_]{1,20}$")
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


def _run(sql: str, params: list | None = None) -> tuple[list, list[str]]:
    try:
        with _connect() as conn:
            cur = conn.cursor()
            cur.execute(sql, params)
            rows = cur.fetchall()
            return rows, [c[0] for c in cur.description or []]
    except trino.exceptions.TrinoUserError as exc:
        if exc.error_name in ("TABLE_NOT_FOUND", "SCHEMA_NOT_FOUND"):
            raise LakehouseNotReady(exc.message) from exc
        raise


def query(sql: str, params: list | None = None) -> list[dict]:
    rows, columns = _run(sql, params)
    return [{col: float(v) if isinstance(v, Decimal) else v for col, v in zip(columns, row)} for row in rows]


# Period key 'YYYY-MM' from FISCYEARPER 'YYYYPPP' (fiscal year variant K4: period = calendar month).
_PERIOD = "substr(fiscyearper, 1, 4) || '-' || substr(fiscyearper, 6, 2)"
# Month of a FINSSKF totals value (GRTYP 2: the quantity of the month that starts on DATE_FROM).
_SKF_PERIOD = "substr(CAST(date_from AS varchar), 1, 7)"


def _unit_drivers() -> str:
    """Cost center → statistical key figure of its unit OPEX, as an inline relation (from the master data)."""
    pairs = [(rcntr, stagr) for rcntr, stagr in masterdata.UNIT_DRIVERS.items()
             if COST_CENTER.match(rcntr) and KEY_FIGURE.match(stagr)]
    return "(VALUES " + ", ".join(f"('{rcntr}', '{stagr}')" for rcntr, stagr in pairs) + ") AS u(rcntr, stagr)"


def _gold_ddl() -> list[str]:
    return [
        f"CREATE SCHEMA IF NOT EXISTS {GOLD} WITH (location = 's3://lakehouse/gold/')",
        f"""CREATE OR REPLACE VIEW {PXQ_VIEW}
        COMMENT 'OPEX C1 P x Q per version, month, cost center (RCNTR) and G/L account (RACCT): KSL, MSL in RUOM, price, driver and specific consumption'
        AS
        WITH
        lines AS (  -- one row per version, month, cost center and account: quantities never mix units
            SELECT '{ACTUAL}' AS version, {_PERIOD} AS period, rcntr, racct, runit AS ruom,
                   sum(ksl) AS ksl, sum(msl) AS msl, CAST(0 AS decimal(38, 2)) AS fixed_ksl,
                   CAST(0 AS decimal(38, 3)) AS fixed_msl
              FROM lakehouse.silver.acdoca
             WHERE rcntr IS NOT NULL AND rkcur = '{GROUP_CURRENCY}'
             GROUP BY 2, 3, 4, 5
            UNION ALL
            SELECT category, {_PERIOD}, rcntr, racct, rvunit, sum(ksl), sum(vmsl), sum(kfsl), sum(vmfsl)
              FROM lakehouse.silver.acdocp
             WHERE rkcur = '{GROUP_CURRENCY}'
             GROUP BY 1, 2, 3, 4, 5),
        drivers AS (  -- the unit-OPEX driver of each cost center (FINSSKF totals value of the month)
            SELECT CASE WHEN f.rrcty = '0' THEN '{ACTUAL}' ELSE f.category END AS version, {_SKF_PERIOD} AS period,
                   f.rcntr, f.stagr, max(f.runit) AS driver_unit, sum(f.msl) AS driver_qty
              FROM lakehouse.silver.finsskf f
              JOIN {_unit_drivers()} ON u.rcntr = f.rcntr AND u.stagr = f.stagr
             WHERE f.grtyp = '2'
             GROUP BY 1, 2, 3, 4)
        SELECT l.version, l.period, l.rcntr, l.racct, l.ruom,
               CAST(l.ksl AS double) AS ksl, CAST(l.msl AS double) AS msl,
               CAST(l.fixed_ksl AS double) AS fixed_ksl, CAST(l.fixed_msl AS double) AS fixed_msl,
               d.stagr, d.driver_unit, CAST(d.driver_qty AS double) AS driver_qty,
               if(l.ruom IS NOT NULL, CAST(l.ksl AS double) / nullif(CAST(l.msl AS double), 0)) AS unit_price,
               if(l.ruom IS NOT NULL, CAST(l.msl AS double) / nullif(CAST(d.driver_qty AS double), 0))
                   AS specific_consumption,
               CAST(l.ksl AS double) / nullif(CAST(d.driver_qty AS double), 0) AS cost_per_driver_unit
          FROM lines l
          LEFT JOIN drivers d ON d.version = l.version AND d.period = l.period AND d.rcntr = l.rcntr""",
        f"""CREATE OR REPLACE VIEW {VARIANCE_VIEW}
        COMMENT 'OPEX C1 actual vs base budget (BUDG) per month, cost center and G/L account on a flexible budget: price P, efficiency Q, volume and spending effects'
        AS
        WITH
        joined AS (
            SELECT coalesce(a.period, b.period) AS period, coalesce(a.rcntr, b.rcntr) AS rcntr,
                   coalesce(a.racct, b.racct) AS racct, coalesce(a.ruom, b.ruom) AS ruom,
                   coalesce(a.stagr, b.stagr) AS stagr, coalesce(a.driver_unit, b.driver_unit) AS driver_unit,
                   coalesce(a.ksl, 0) AS actual_ksl, coalesce(a.msl, 0) AS actual_msl,
                   coalesce(b.ksl, 0) AS budget_ksl, coalesce(b.msl, 0) AS budget_msl,
                   coalesce(b.fixed_ksl, 0) AS budget_fixed_ksl, coalesce(b.fixed_msl, 0) AS budget_fixed_msl,
                   a.unit_price AS actual_price, b.unit_price AS budget_price,
                   a.specific_consumption AS actual_sc, b.specific_consumption AS budget_sc,
                   max(a.driver_qty) OVER (PARTITION BY coalesce(a.period, b.period), coalesce(a.rcntr, b.rcntr))
                       AS actual_driver,
                   max(b.driver_qty) OVER (PARTITION BY coalesce(a.period, b.period), coalesce(a.rcntr, b.rcntr))
                       AS budget_driver
              FROM (SELECT * FROM {PXQ_VIEW} WHERE version = '{ACTUAL}') a
              FULL OUTER JOIN (SELECT * FROM {PXQ_VIEW} WHERE version = '{BUDGET_CATEGORY}') b
                ON b.period = a.period AND b.rcntr = a.rcntr AND b.racct = a.racct),
        flexed AS (  -- activity = driver actual / budget (no flex without a budget driver)
            SELECT j.*, j.ruom IS NOT NULL AND j.budget_msl > 0 AS physical,
                   coalesce(j.actual_driver / nullif(j.budget_driver, 0), 1) AS activity,
                   j.budget_ksl / nullif(j.budget_msl, 0) AS pb
              FROM joined j),
        effects AS (  -- flexible budget: the fixed share stays, the variable share follows the driver
            SELECT f.*,
                   f.budget_fixed_msl + (f.budget_msl - f.budget_fixed_msl) * f.activity AS flex_msl,
                   CASE WHEN f.physical
                        THEN f.pb * (f.budget_fixed_msl + (f.budget_msl - f.budget_fixed_msl) * f.activity)
                        ELSE f.budget_fixed_ksl + (f.budget_ksl - f.budget_fixed_ksl) * f.activity END AS flex_ksl
              FROM flexed f)
        SELECT period, rcntr, racct, ruom, stagr, driver_unit, actual_driver, budget_driver,
               CASE WHEN budget_ksl <> 0 AND budget_fixed_ksl = budget_ksl THEN 'F'
                    WHEN budget_fixed_ksl = 0 THEN 'V' ELSE 'M' END AS behavior,
               round(actual_ksl, 2) AS actual_ksl, round(budget_ksl, 2) AS budget_ksl, round(flex_ksl, 2) AS flex_ksl,
               round(actual_ksl - budget_ksl, 2) AS variance,
               round((actual_ksl - budget_ksl) / nullif(budget_ksl, 0) * 100, 1) AS variance_pct,
               if(ruom IS NOT NULL, actual_msl) AS actual_msl, if(ruom IS NOT NULL, budget_msl) AS budget_msl,
               if(physical, flex_msl) AS flex_msl,
               actual_price, budget_price, round((actual_price - budget_price) / nullif(budget_price, 0) * 100, 1)
                   AS price_pct,
               actual_sc, budget_sc, round((actual_sc - budget_sc) / nullif(budget_sc, 0) * 100, 1) AS sc_pct,
               if(physical, round(actual_ksl - pb * actual_msl, 2)) AS price_effect,
               if(physical, round(pb * (actual_msl - flex_msl), 2)) AS efficiency_effect,
               round(flex_ksl - budget_ksl, 2) AS volume_effect,
               if(NOT physical, round(actual_ksl - flex_ksl, 2)) AS spending_effect
          FROM effects""",
    ]


_gold_lock = threading.Lock()
_gold_ready = False


def ensure_gold() -> None:
    """Publishes the gold views (CREATE OR REPLACE) once per process, as soon as the silver layer exists."""
    global _gold_ready
    if _gold_ready:
        return
    with _gold_lock:
        if not _gold_ready:
            for statement in _gold_ddl():
                _run(statement)
            _gold_ready = True


def _validate(rcntr: str | None = None, category: str | None = None, period: str | None = None,
              stagr: str | None = None) -> None:
    if ((rcntr is not None and not COST_CENTER.match(rcntr)) or (category and not CATEGORY.match(category))
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


def _cutoff(period: str | None) -> str:
    """Latest actual month, or the latest up to the requested one (its placeholder comes first)."""
    return f"max({_PERIOD}) FILTER (WHERE {_PERIOD} <= ?)" if period else f"max({_PERIOD})"


def timeline(rcntr: str, category: str) -> list[dict]:
    """One row per month and account: the actual months with their budget alongside, then the plan
    months of the category; OPEX, driver and unit OPEX of each month and version."""
    _validate(rcntr, category)
    ensure_gold()
    return query(f"""
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
    ensure_gold()
    rows = query(f"""
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
    ensure_gold()
    return query(f"""
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
    ensure_gold()
    rows = query(f"""
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
    return query(f"""
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
