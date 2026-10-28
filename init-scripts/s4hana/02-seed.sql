-- ═══════════════════════════════════════════════════════════════════════════
-- Seed data · SAP S/4HANA (simulated) — STRICTLY the CAEX OPEX case. Synthetic: no real companies.
--   Cost center RCNTR_MINA_CAEX (mine haul fleet, Komatsu CAEX trucks), group currency USD (KSL):
--   ACDOCA   3 actual months (2026-08 .. 2026-10): spare parts (0061100100) rise every month; the
--            current month (2026-10) adds the emergency injector replacement of 3 trucks
--   ACDOCP   18 plan months (2026-11 .. 2028-04), plan category RF18M (SAC export, one request):
--            costs converge back to the steady state (stabilization)
--   FINSSKF  operating hours (HOROP) and tonnes (TONMOV): actual drop in 2026-10, plan recovery
-- ═══════════════════════════════════════════════════════════════════════════

-- ── ACDOCA · actuals (balanced journal entries, Dr cost center / Cr offset) ──
SELECT sap.post_cost_center_document(d.belnr, d.budat, d.blart, d.racct, 'RCNTR_MINA_CAEX', d.amount,
                                     d.sgtxt, d.usnam, d.matnr)
  FROM (VALUES
    -- 2026-08
    ('4900010001', date '2026-08-31', 'WA', '0061100100', 1150000.00, 'Consumo repuestos flota CAEX ago-2026',    'MMBODEGA',  NULL),
    ('4900010002', date '2026-08-31', 'WA', '0061100200', 1520000.00, 'Consumo diésel flota CAEX ago-2026',       'MMBODEGA',  NULL),
    ('4900010003', date '2026-08-31', 'WA', '0061100300',  320000.00, 'Consumo neumáticos flota CAEX ago-2026',   'MMBODEGA',  NULL),
    ('5000010001', date '2026-08-31', 'WE', '0062100100',  210000.00, 'Servicios mantención CAEX ago-2026',       'MMCOMPRAS', NULL),
    ('0100010001', date '2026-08-31', 'SA', '0063100100',  425000.00, 'Remuneraciones operación CAEX ago-2026',   'HRNOMINA',  NULL),
    -- 2026-09
    ('4900010004', date '2026-09-30', 'WA', '0061100100', 1290000.00, 'Consumo repuestos flota CAEX sep-2026',    'MMBODEGA',  NULL),
    ('4900010005', date '2026-09-30', 'WA', '0061100200', 1505000.00, 'Consumo diésel flota CAEX sep-2026',       'MMBODEGA',  NULL),
    ('4900010006', date '2026-09-30', 'WA', '0061100300',  316000.00, 'Consumo neumáticos flota CAEX sep-2026',   'MMBODEGA',  NULL),
    ('5000010002', date '2026-09-30', 'WE', '0062100100',  212000.00, 'Servicios mantención CAEX sep-2026',       'MMCOMPRAS', NULL),
    ('0100010002', date '2026-09-30', 'SA', '0063100100',  425000.00, 'Remuneraciones operación CAEX sep-2026',   'HRNOMINA',  NULL),
    -- 2026-10 (current month): unplanned stop of 3 trucks
    ('4900010007', date '2026-10-16', 'WA', '0061100100',  740000.00, 'Reemplazo inyectores 3 CAEX Komatsu (emergencia)', 'MMBODEGA', 'SKU-CL-INY-930E'),
    ('4900010008', date '2026-10-27', 'WA', '0061100100', 1240000.00, 'Consumo repuestos flota CAEX oct-2026',    'MMBODEGA',  NULL),
    ('4900010009', date '2026-10-27', 'WA', '0061100200', 1310000.00, 'Consumo diésel flota CAEX oct-2026',       'MMBODEGA',  NULL),
    ('4900010010', date '2026-10-27', 'WA', '0061100300',  275000.00, 'Consumo neumáticos flota CAEX oct-2026',   'MMBODEGA',  NULL),
    ('5000010003', date '2026-10-27', 'WE', '0062100100',  214000.00, 'Servicios mantención CAEX oct-2026',       'MMCOMPRAS', NULL),
    ('0100010003', date '2026-10-27', 'SA', '0063100100',  428000.00, 'Remuneraciones operación CAEX oct-2026',   'HRNOMINA',  NULL)
  ) AS d(belnr, budat, blart, racct, amount, sgtxt, usnam, matnr)
 ORDER BY d.belnr;

-- ── FINSSKF · actual drivers from the fleet dispatch system (totals values per month) ──
INSERT INTO sap.finsskf (stagr, recid, date_from, grtyp, msl, runit, timestamp, rbukrs, rrcty, category, rcntr,
                         prctr, logsys)
SELECT s.stagr, upper(substr(md5('0' || s.stagr || d.date_from), 1, 22)), d.date_from, '2',
       CASE s.stagr WHEN 'HOROP' THEN d.hours ELSE d.tonnes END, s.runit, d.loaded_at, 'CL01', '0', '',
       'RCNTR_MINA_CAEX', 'CL01MINA', 'DISPATCH'
  FROM (VALUES
    (date '2026-08-01', 20260831235900, 8850, 4600000),
    (date '2026-09-01', 20260930235900, 8790, 4570000),
    (date '2026-10-01', 20261027235900, 7640, 3970000)   -- 3 trucks stopped: hours and tonnes fall
  ) AS d(date_from, loaded_at, hours, tonnes)
 CROSS JOIN (VALUES ('HOROP', 'H'), ('TONMOV', 'TO')) AS s(stagr, runit);

-- ── Rolling forecast 18M (plan category RF18M, SAC export): 2026-11 .. 2028-04 ──
-- Post-event levels converge to the steady state with a one-month half-life:
--   level(n) = steady + (first - steady) * 0.5^(n-1)
-- Hours 8,600 → 8,820 H; tonnes at 520 t/H; diesel 171.80 USD/H; tyres 36.05 USD/H;
-- spare parts 1,450,000 → 1,180,000 USD; maintenance services and payroll flat.
CREATE TEMPORARY TABLE forecast_drivers AS
SELECT n, m::date AS date_from, (m + interval '1 month - 1 day')::date AS budat,
       round(8820 - (8820 - 8600) * power(0.5::numeric, (n - 1)::numeric)) AS hours,
       power(0.5::numeric, (n - 1)::numeric) AS decay
  FROM generate_series(1, 18) AS n,
       LATERAL (SELECT date '2026-11-01' + make_interval(months => n - 1) AS m) AS months;

-- One SAC export request (REQTSN), one data packet, one record per month and cost element.
INSERT INTO sap.acdocp (reqtsn, datapakid, record, ryear, rbukrs, category, racct, wsl, hsl, ksl, rcntr, prctr,
                        poper, fiscyearper, budat, sgtxt, usnam)
SELECT '20261028100000000000001', '000001', row_number() OVER (ORDER BY f.n, a.racct)::int,
       to_char(f.budat, 'YYYY'), 'CL01', 'RF18M', a.racct, a.amount, a.amount, a.amount, 'RCNTR_MINA_CAEX',
       'CL01MINA', to_char(f.budat, '"0"MM'), to_char(f.budat, 'YYYY"0"MM'), f.budat,
       'SAC Rolling Forecast 18M ciclo 2026-10', 'SAC_EXPORT'
  FROM forecast_drivers f
 CROSS JOIN LATERAL (VALUES
    ('0061100100', round(1180000 + (1450000 - 1180000) * f.decay, -3)),
    ('0061100200', round(f.hours * 171.80, -3)),
    ('0061100300', round(f.hours * 36.05, -3)),
    ('0062100100', 212000::numeric),
    ('0063100100', 425000::numeric)
  ) AS a(racct, amount);

INSERT INTO sap.finsskf (stagr, recid, date_from, grtyp, msl, runit, timestamp, rbukrs, rrcty, category, rcntr,
                         prctr, logsys)
SELECT s.stagr, upper(substr(md5('1RF18M' || s.stagr || f.date_from), 1, 22)), f.date_from, '2', s.msl, s.runit,
       20261028100000, 'CL01', '1', 'RF18M', 'RCNTR_MINA_CAEX', 'CL01MINA', 'SAC'
  FROM forecast_drivers f
 CROSS JOIN LATERAL (VALUES
    ('HOROP',  f.hours,                   'H'),
    ('TONMOV', round(f.hours * 520, -3),  'TO')
  ) AS s(stagr, msl, runit);

DROP TABLE forecast_drivers;
