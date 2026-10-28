-- ═══════════════════════════════════════════════════════════════════════════
-- Gold layer of the lakehouse · OPEX C1 P x Q (applied by the trino-init job before the backend starts)
--   vw_opex_c1_pxq           master P x Q view: one row per version (ACTUAL, BUDG, RF18M), month, cost center
--                            (RCNTR) and G/L account (RACCT) — cost KSL, quantity MSL in its own unit RUOM (units
--                            are never added across accounts), price, driver (FINSSKF) and specific consumption
--   vw_opex_c1_pxq_variance  actual vs base budget (BUDG) on a flexible budget (the fixed share KFSL / VMFSL stays,
--                            the variable share follows the driver): price P, efficiency Q, volume and spending
-- Reads the silver views of delta-sink (current state of ACDOCA / ACDOCP / FINSSKF). Every division goes
-- through nullif: a zero driver (e.g. no shipments) yields NULL, never an error. Idempotent (OR REPLACE).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS lakehouse.gold WITH (location = 's3://lakehouse/gold/');

CREATE OR REPLACE VIEW lakehouse.gold.vw_opex_c1_pxq
COMMENT 'OPEX C1 P x Q per version, month, cost center (RCNTR) and G/L account (RACCT): KSL, MSL in RUOM, price, driver and specific consumption'
AS
WITH
lines AS (  -- one row per version, month, cost center and account: quantities never mix units
    SELECT 'ACTUAL' AS version, substr(fiscyearper, 1, 4) || '-' || substr(fiscyearper, 6, 2) AS period,
           rcntr, racct, runit AS ruom, sum(ksl) AS ksl, sum(msl) AS msl,
           CAST(0 AS decimal(38, 2)) AS fixed_ksl, CAST(0 AS decimal(38, 3)) AS fixed_msl
      FROM lakehouse.silver.acdoca
     WHERE rcntr IS NOT NULL AND rkcur = 'USD'
     GROUP BY 2, 3, 4, 5
    UNION ALL
    SELECT category, substr(fiscyearper, 1, 4) || '-' || substr(fiscyearper, 6, 2), rcntr, racct, rvunit,
           sum(ksl), sum(vmsl), sum(kfsl), sum(vmfsl)
      FROM lakehouse.silver.acdocp
     WHERE rkcur = 'USD'
     GROUP BY 1, 2, 3, 4, 5),
unit_drivers (rcntr, stagr) AS (  -- the statistical key figure of the unit OPEX of each cost center
    VALUES ('MIN_PERF', 'METPER'), ('MIN_TRON', 'TONTRO'), ('MIN_CARG', 'TONCAR'), ('MIN_TRAN', 'TONMOV'),
           ('CON_MOLI', 'TONMOL'), ('CON_FLOT', 'TONFLO'), ('CON_RELA', 'TONREL'),
           ('LIX_RIEG', 'TONAPI'), ('LIX_SX', 'M3PLS'), ('LIX_EW', 'TONCAT'),
           ('PTO_FILT', 'TONFIL'), ('PTO_EMBA', 'TONEMB')),
drivers AS (  -- FINSSKF totals value of the month (GRTYP 2) per version
    SELECT CASE WHEN f.rrcty = '0' THEN 'ACTUAL' ELSE f.category END AS version,
           substr(CAST(f.date_from AS varchar), 1, 7) AS period, f.rcntr, f.stagr,
           max(f.runit) AS driver_unit, sum(f.msl) AS driver_qty
      FROM lakehouse.silver.finsskf f
      JOIN unit_drivers u ON u.rcntr = f.rcntr AND u.stagr = f.stagr
     WHERE f.grtyp = '2'
     GROUP BY 1, 2, 3, 4)
SELECT l.version, l.period, l.rcntr, l.racct, l.ruom,
       CAST(l.ksl AS double) AS ksl, CAST(l.msl AS double) AS msl,
       CAST(l.fixed_ksl AS double) AS fixed_ksl, CAST(l.fixed_msl AS double) AS fixed_msl,
       d.stagr, d.driver_unit, CAST(d.driver_qty AS double) AS driver_qty,
       if(l.ruom IS NOT NULL, CAST(l.ksl AS double) / nullif(CAST(l.msl AS double), 0)) AS unit_price,
       if(l.ruom IS NOT NULL, CAST(l.msl AS double) / nullif(CAST(d.driver_qty AS double), 0)) AS specific_consumption,
       CAST(l.ksl AS double) / nullif(CAST(d.driver_qty AS double), 0) AS cost_per_driver_unit
  FROM lines l
  LEFT JOIN drivers d ON d.version = l.version AND d.period = l.period AND d.rcntr = l.rcntr;

CREATE OR REPLACE VIEW lakehouse.gold.vw_opex_c1_pxq_variance
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
           max(a.driver_qty) OVER (PARTITION BY coalesce(a.period, b.period), coalesce(a.rcntr, b.rcntr)) AS actual_driver,
           max(b.driver_qty) OVER (PARTITION BY coalesce(a.period, b.period), coalesce(a.rcntr, b.rcntr)) AS budget_driver
      FROM (SELECT * FROM lakehouse.gold.vw_opex_c1_pxq WHERE version = 'ACTUAL') a
      FULL OUTER JOIN (SELECT * FROM lakehouse.gold.vw_opex_c1_pxq WHERE version = 'BUDG') b
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
       actual_price, budget_price, round((actual_price - budget_price) / nullif(budget_price, 0) * 100, 1) AS price_pct,
       actual_sc, budget_sc, round((actual_sc - budget_sc) / nullif(budget_sc, 0) * 100, 1) AS sc_pct,
       if(physical, round(actual_ksl - pb * actual_msl, 2)) AS price_effect,
       if(physical, round(pb * (actual_msl - flex_msl), 2)) AS efficiency_effect,
       round(flex_ksl - budget_ksl, 2) AS volume_effect,
       if(NOT physical, round(actual_ksl - flex_ksl, 2)) AS spending_effect
  FROM effects;
