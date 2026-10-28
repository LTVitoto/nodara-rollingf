-- ═══════════════════════════════════════════════════════════════════════════
-- Seed data · SAP S/4HANA (simulated) — STRICTLY the approved cases of the C1 OPEX value chain.
-- Synthetic: no real companies. Group currency USD (KSL). Current month = 2026-10 (latest actual).
--   RCNTR               driver (FINSSKF)        event of the current month (bitácora 2026-10)
--   RCNTR_MINA_CAEX     HOROP  operating hours  3 Komatsu trucks stopped (injectors): spare parts up
--   RCNTR_MINA_TRUCK    TONMOV tonnes moved     seasonal pit flooding: extraction -15 %, diesel up (pumps)
--   RCNTR_LIXIV_SXEW    TONAPI tonnes stacked   main sulfuric acid pump failure: spare parts up, tonnes down
--   RCNTR_CONCEN_FLOT   TONPRO tonnes processed ore grade drop: xanthate collector at 15 g/t, reagents up
--   RCNTR_PUERTO_EMB    TONEMB tonnes shipped   swells, 5 days without berthing: shipments down, fixed costs flat
-- Per cost center:
--   ACDOCA   3 actual months (2026-08 .. 2026-10), balanced documents
--   ACDOCP   BUDG base budget for the same 3 months (SAC export 2025-12) and RF18M rolling forecast for
--            18 months (2026-11 .. 2028-04, SAC export 2026-10) converging back to the budget levels
--   FINSSKF  actual drivers (RRCTY 0) and planned drivers (RRCTY 1) for BUDG and RF18M
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Cost centers of the value chain: profit center and source system of their drivers ──
CREATE TEMPORARY TABLE centers (seq, rcntr, prctr, logsys) AS VALUES
    (1, 'RCNTR_MINA_CAEX',   'CL01MINA', 'DISPATCH'),
    (2, 'RCNTR_MINA_TRUCK',  'CL01MINA', 'DISPATCH'),
    (3, 'RCNTR_LIXIV_SXEW',  'CL01SXEW', 'PIMS'),
    (4, 'RCNTR_CONCEN_FLOT', 'CL01CONC', 'PIMS'),
    (5, 'RCNTR_PUERTO_EMB',  'CL01PUER', 'PORTMS');

-- ── ACDOCA · actuals: one document per cost center, cost element and month (m08 / m09 / m10) ──
CREATE TEMPORARY TABLE actual_costs (rcntr, racct, blart, usnam, sgtxt, m08, m09, m10) AS VALUES
    -- Mina · Flota CAEX: spare parts rise every month
    ('RCNTR_MINA_CAEX',   '0061100100', 'WA', 'MMBODEGA',  'Consumo repuestos flota CAEX',        1150000, 1290000, 1240000),
    ('RCNTR_MINA_CAEX',   '0061100200', 'WA', 'MMBODEGA',  'Consumo diésel flota CAEX',           1520000, 1505000, 1310000),
    ('RCNTR_MINA_CAEX',   '0061100300', 'WA', 'MMBODEGA',  'Consumo neumáticos flota CAEX',        320000,  316000,  275000),
    ('RCNTR_MINA_CAEX',   '0062100100', 'WE', 'MMCOMPRAS', 'Servicios mantención CAEX',            210000,  212000,  214000),
    ('RCNTR_MINA_CAEX',   '0063100100', 'SA', 'HRNOMINA',  'Remuneraciones operación CAEX',        425000,  425000,  428000),
    -- Mina · Extracción: haulage diesel falls with the tonnes in October (pumps posted apart)
    ('RCNTR_MINA_TRUCK',  '0061100200', 'WA', 'MMBODEGA',  'Combustible diésel extracción mina',   2390000, 2415000, 2040000),
    ('RCNTR_MINA_TRUCK',  '0061100300', 'WA', 'MMBODEGA',  'Neumáticos equipos extracción mina',    378000,  383000,  326000),
    ('RCNTR_MINA_TRUCK',  '0061100100', 'WA', 'MMBODEGA',  'Repuestos equipos extracción mina',     905000,  893000,  912000),
    ('RCNTR_MINA_TRUCK',  '0062100100', 'WE', 'MMCOMPRAS', 'Servicios mantención extracción mina',  448000,  452000,  455000),
    ('RCNTR_MINA_TRUCK',  '0063100100', 'SA', 'HRNOMINA',  'Remuneraciones extracción mina',       1100000, 1100000, 1104000),
    -- Planta de Lixiviación SX-EW: less acid while irrigation stopped, fixed costs flat
    ('RCNTR_LIXIV_SXEW',  '0061100400', 'WA', 'MMBODEGA',  'Consumo ácido sulfúrico planta SX-EW', 1645000, 1662000, 1548000),
    ('RCNTR_LIXIV_SXEW',  '0062100300', 'WE', 'MMCOMPRAS', 'Energía eléctrica planta SX-EW',       1296000, 1305000, 1301000),
    ('RCNTR_LIXIV_SXEW',  '0061100100', 'WA', 'MMBODEGA',  'Repuestos planta SX-EW',                418000,  426000,  431000),
    ('RCNTR_LIXIV_SXEW',  '0062100100', 'WE', 'MMCOMPRAS', 'Servicios mantención planta SX-EW',     309000,  311000,  312000),
    ('RCNTR_LIXIV_SXEW',  '0063100100', 'SA', 'HRNOMINA',  'Remuneraciones planta SX-EW',           780000,  780000,  783000),
    -- Planta Concentradora · Flotación: throughput on budget, reagents up in October (dosage posted apart)
    ('RCNTR_CONCEN_FLOT', '0062100300', 'WE', 'MMCOMPRAS', 'Energía eléctrica planta concentradora', 4185000, 4210000, 4196000),
    ('RCNTR_CONCEN_FLOT', '0061100100', 'WA', 'MMBODEGA',  'Repuestos molienda concentradora',     1795000, 1812000, 1806000),
    ('RCNTR_CONCEN_FLOT', '0061100400', 'WA', 'MMBODEGA',  'Reactivos flotación concentradora',    1246000, 1262000, 1268000),
    ('RCNTR_CONCEN_FLOT', '0062100100', 'WE', 'MMCOMPRAS', 'Servicios mantención concentradora',    648000,  651000,  653000),
    ('RCNTR_CONCEN_FLOT', '0063100100', 'SA', 'HRNOMINA',  'Remuneraciones concentradora',         1250000, 1250000, 1254000),
    -- Puerto · Embarque: fixed costs (storage contract) flat every month
    ('RCNTR_PUERTO_EMB',  '0062100200', 'WE', 'MMCOMPRAS', 'Almacenamiento concentrado puerto',     520000,  520000,  520000),
    ('RCNTR_PUERTO_EMB',  '0063100100', 'SA', 'HRNOMINA',  'Remuneraciones puerto',                 310000,  310000,  311000),
    ('RCNTR_PUERTO_EMB',  '0062100100', 'WE', 'MMCOMPRAS', 'Servicios mantención puerto',           139000,  142000,  140000),
    ('RCNTR_PUERTO_EMB',  '0062100300', 'WE', 'MMCOMPRAS', 'Energía eléctrica puerto',               96000,   95000,   91000);

-- Event postings of the current month (the cost side of each bitácora).
CREATE TEMPORARY TABLE events (rcntr, budat, blart, racct, amount, sgtxt, usnam, matnr) AS VALUES
    ('RCNTR_MINA_CAEX',   date '2026-10-16', 'WA', '0061100100', 740000, 'Reemplazo inyectores 3 CAEX Komatsu (emergencia)', 'MMBODEGA', 'SKU-CL-INY-930E'),
    ('RCNTR_MINA_TRUCK',  date '2026-10-14', 'WA', '0061100200', 760000, 'Diésel motobombas de achique (inundación rajo)',   'MMBODEGA', 'SKU-CL-DSL-B5'),
    ('RCNTR_LIXIV_SXEW',  date '2026-10-09', 'WA', '0061100100', 585000, 'Reparación bomba ácido sulfúrico (emergencia)',    'MMBODEGA', 'SKU-CL-BOM-H2SO4'),
    ('RCNTR_CONCEN_FLOT', date '2026-10-20', 'WA', '0061100400', 512000, 'Colector xantato 15 g/t (caída de ley)',           'MMBODEGA', 'SKU-CL-XAN-SIPX');

-- Balanced journal entries (Dr cost center / Cr offset), numbered per document type:
-- WA 49000100nn, WE 50000100nn, SA 01000100nn (the simulator continues at 4900020001).
WITH months (m, budat, label) AS (
         VALUES (8, date '2026-08-31', 'ago-2026'), (9, date '2026-09-30', 'sep-2026'), (10, date '2026-10-27', 'oct-2026')),
     documents AS (
         SELECT c.rcntr, c.racct, c.blart, c.usnam, c.sgtxt || ' ' || m.label AS sgtxt, m.budat,
                CASE m.m WHEN 8 THEN c.m08 WHEN 9 THEN c.m09 ELSE c.m10 END AS amount, NULL AS matnr
           FROM actual_costs c CROSS JOIN months m
         UNION ALL
         SELECT rcntr, racct, blart, usnam, sgtxt, budat, amount, matnr FROM events)
SELECT sap.post_cost_center_document(
           CASE d.blart WHEN 'WA' THEN '49000' WHEN 'WE' THEN '50000' ELSE '01000' END
               || (10000 + row_number() OVER (PARTITION BY d.blart ORDER BY d.budat, v.seq, d.racct))::text,
           d.budat, d.blart, d.racct, d.rcntr, v.prctr, d.amount, d.sgtxt, d.usnam, d.matnr)
  FROM documents d
  JOIN centers v USING (rcntr)
 ORDER BY d.budat, v.seq, d.racct;

-- ── FINSSKF · actual drivers from the source systems (totals values per month) ──
-- RECID identifies the key figure item (record type, category, company code, cost center, key figure).
CREATE TEMPORARY TABLE actual_drivers (rcntr, stagr, runit, m08, m09, m10) AS VALUES
    ('RCNTR_MINA_CAEX',   'HOROP',  'H',      8850,    8790,    7640),   -- 3 trucks stopped from 2026-10-16
    ('RCNTR_MINA_CAEX',   'TONMOV', 'TO',  4600000, 4570000, 3970000),
    ('RCNTR_MINA_TRUCK',  'TONMOV', 'TO',  6030000, 5970000, 5100000),   -- flooding: -15 % vs budget
    ('RCNTR_LIXIV_SXEW',  'TONAPI', 'TO',  1492000, 1506000, 1290000),   -- irrigation stopped 48 h
    ('RCNTR_CONCEN_FLOT', 'TONPRO', 'TO',  3094000, 3108000, 3071000),   -- throughput kept, grade fell
    ('RCNTR_PUERTO_EMB',  'TONEMB', 'WMT',  258000,  263000,  212000);   -- 5 days with zero shipments

INSERT INTO sap.finsskf (stagr, recid, date_from, grtyp, msl, runit, timestamp, rbukrs, rrcty, category, rcntr,
                         prctr, logsys)
SELECT d.stagr, upper(substr(md5('0' || 'CL01' || d.rcntr || d.stagr), 1, 22)), m.date_from, '2',
       CASE m.m WHEN 8 THEN d.m08 WHEN 9 THEN d.m09 ELSE d.m10 END, d.runit, m.loaded_at, 'CL01', '0', '',
       d.rcntr, v.prctr, v.logsys
  FROM actual_drivers d
  JOIN centers v USING (rcntr)
 CROSS JOIN (VALUES (8, date '2026-08-01', 20260831235900),
                    (9, date '2026-09-01', 20260930235900),
                    (10, date '2026-10-01', 20261027235900)) AS m(m, date_from, loaded_at);

-- ── BUDG · base budget 2026 (SAC export of 2025-12-15) for the actual months: flat monthly levels ──
CREATE TEMPORARY TABLE budget_costs (rcntr, racct, amount) AS VALUES
    ('RCNTR_MINA_CAEX',   '0061100100', 1180000), ('RCNTR_MINA_CAEX',   '0061100200', 1515000),
    ('RCNTR_MINA_CAEX',   '0061100300',  318000), ('RCNTR_MINA_CAEX',   '0062100100',  212000),
    ('RCNTR_MINA_CAEX',   '0063100100',  425000),
    ('RCNTR_MINA_TRUCK',  '0061100200', 2400000), ('RCNTR_MINA_TRUCK',  '0061100300',  380000),
    ('RCNTR_MINA_TRUCK',  '0061100100',  900000), ('RCNTR_MINA_TRUCK',  '0062100100',  450000),
    ('RCNTR_MINA_TRUCK',  '0063100100', 1100000),
    ('RCNTR_LIXIV_SXEW',  '0061100400', 1650000), ('RCNTR_LIXIV_SXEW',  '0062100300', 1300000),
    ('RCNTR_LIXIV_SXEW',  '0061100100',  420000), ('RCNTR_LIXIV_SXEW',  '0062100100',  310000),
    ('RCNTR_LIXIV_SXEW',  '0063100100',  780000),
    ('RCNTR_CONCEN_FLOT', '0062100300', 4200000), ('RCNTR_CONCEN_FLOT', '0061100100', 1800000),
    ('RCNTR_CONCEN_FLOT', '0061100400', 1250000), ('RCNTR_CONCEN_FLOT', '0062100100',  650000),
    ('RCNTR_CONCEN_FLOT', '0063100100', 1250000),
    ('RCNTR_PUERTO_EMB',  '0062100200',  520000), ('RCNTR_PUERTO_EMB',  '0063100100',  310000),
    ('RCNTR_PUERTO_EMB',  '0062100100',  140000), ('RCNTR_PUERTO_EMB',  '0062100300',   95000);

CREATE TEMPORARY TABLE budget_drivers (rcntr, stagr, runit, msl) AS VALUES
    ('RCNTR_MINA_CAEX',   'HOROP',  'H',      8820), ('RCNTR_MINA_CAEX',  'TONMOV', 'TO', 4586000),
    ('RCNTR_MINA_TRUCK',  'TONMOV', 'TO',  6000000), ('RCNTR_LIXIV_SXEW', 'TONAPI', 'TO', 1500000),
    ('RCNTR_CONCEN_FLOT', 'TONPRO', 'TO',  3100000), ('RCNTR_PUERTO_EMB', 'TONEMB', 'WMT', 260000);

CREATE TEMPORARY TABLE budget_months (date_from, budat) AS VALUES
    (date '2026-08-01', date '2026-08-31'), (date '2026-09-01', date '2026-09-30'), (date '2026-10-01', date '2026-10-31');

INSERT INTO sap.acdocp (reqtsn, datapakid, record, ryear, rbukrs, category, racct, wsl, hsl, ksl, rcntr, prctr,
                        poper, fiscyearper, budat, sgtxt, usnam)
SELECT '20251215100000000000001', '000001', row_number() OVER (ORDER BY m.budat, v.seq, b.racct)::int,
       to_char(m.budat, 'YYYY'), 'CL01', 'BUDG', b.racct, b.amount, b.amount, b.amount, b.rcntr, v.prctr,
       to_char(m.budat, '"0"MM'), to_char(m.budat, 'YYYY"0"MM'), m.budat, 'SAC Presupuesto base 2026', 'SAC_EXPORT'
  FROM budget_costs b
  JOIN centers v USING (rcntr)
 CROSS JOIN budget_months m;

INSERT INTO sap.finsskf (stagr, recid, date_from, grtyp, msl, runit, timestamp, rbukrs, rrcty, category, rcntr,
                         prctr, logsys)
SELECT b.stagr, upper(substr(md5('1BUDG' || 'CL01' || b.rcntr || b.stagr), 1, 22)), m.date_from, '2', b.msl, b.runit,
       20251215100000, 'CL01', '1', 'BUDG', b.rcntr, v.prctr, 'SAC'
  FROM budget_drivers b
  JOIN centers v USING (rcntr)
 CROSS JOIN budget_months m;

-- ── RF18M · rolling forecast 18M (SAC export of 2026-10-28): 2026-11 .. 2028-04 ──
-- Post-event levels converge to the budget levels with a one-month half-life:
--   level(n) = steady + (first - steady) * 0.5^(n-1)
CREATE TEMPORARY TABLE horizon AS
SELECT n, m::date AS date_from, (m + interval '1 month - 1 day')::date AS budat,
       power(0.5::numeric, (n - 1)::numeric) AS decay
  FROM generate_series(1, 18) AS n,
       LATERAL (SELECT date '2026-11-01' + make_interval(months => n - 1) AS m) AS months;

-- Planned drivers: CAEX hours 8,600 → 8,820 H (tonnes at 520 t/H); extraction 5.6 → 6.0 Mt after the
-- flooding; stacking 1.42 → 1.50 Mt; processing 3.07 → 3.10 Mt; shipments 300 → 260 kWMT (backlog first).
CREATE TEMPORARY TABLE forecast_drivers AS
SELECT h.n, h.date_from, h.budat, h.decay, d.rcntr, d.stagr, d.runit, d.msl
  FROM (SELECT horizon.*, round(8820 - (8820 - 8600) * decay) AS caex_hours FROM horizon) h
 CROSS JOIN LATERAL (VALUES
    ('RCNTR_MINA_CAEX',   'HOROP',  'H',   h.caex_hours),
    ('RCNTR_MINA_CAEX',   'TONMOV', 'TO',  round(h.caex_hours * 520, -3)),
    ('RCNTR_MINA_TRUCK',  'TONMOV', 'TO',  round(6000000 - (6000000 - 5600000) * h.decay, -3)),
    ('RCNTR_LIXIV_SXEW',  'TONAPI', 'TO',  round(1500000 - (1500000 - 1420000) * h.decay, -3)),
    ('RCNTR_CONCEN_FLOT', 'TONPRO', 'TO',  round(3100000 - (3100000 - 3070000) * h.decay, -3)),
    ('RCNTR_PUERTO_EMB',  'TONEMB', 'WMT', round(260000 + (300000 - 260000) * h.decay, -3))
  ) AS d(rcntr, stagr, runit, msl);

-- Planned cost elements from the planned driver of the same month (the unit-cost driver of each cost
-- center): variable costs at budget rates, event effects fading out, fixed costs flat at budget.
INSERT INTO sap.acdocp (reqtsn, datapakid, record, ryear, rbukrs, category, racct, wsl, hsl, ksl, rcntr, prctr,
                        poper, fiscyearper, budat, sgtxt, usnam)
SELECT '20261028100000000000001', '000001', row_number() OVER (ORDER BY f.n, v.seq, a.racct)::int,
       to_char(f.budat, 'YYYY'), 'CL01', 'RF18M', a.racct, a.amount, a.amount, a.amount, f.rcntr, v.prctr,
       to_char(f.budat, '"0"MM'), to_char(f.budat, 'YYYY"0"MM'), f.budat, 'SAC Rolling Forecast 18M ciclo 2026-10',
       'SAC_EXPORT'
  FROM forecast_drivers f
  JOIN centers v USING (rcntr)
 CROSS JOIN LATERAL (VALUES
    ('RCNTR_MINA_CAEX',   'HOROP',  '0061100100', round(1180000 + (1450000 - 1180000) * f.decay, -3)),
    ('RCNTR_MINA_CAEX',   'HOROP',  '0061100200', round(f.msl * 171.80, -3)),
    ('RCNTR_MINA_CAEX',   'HOROP',  '0061100300', round(f.msl * 36.05, -3)),
    ('RCNTR_MINA_CAEX',   'HOROP',  '0062100100', 212000),
    ('RCNTR_MINA_CAEX',   'HOROP',  '0063100100', 425000),
    ('RCNTR_MINA_TRUCK',  'TONMOV', '0061100200', round(f.msl * 0.40 + 300000 * f.decay, -3)),
    ('RCNTR_MINA_TRUCK',  'TONMOV', '0061100300', round(f.msl * 0.0633, -3)),
    ('RCNTR_MINA_TRUCK',  'TONMOV', '0061100100', 900000),
    ('RCNTR_MINA_TRUCK',  'TONMOV', '0062100100', 450000),
    ('RCNTR_MINA_TRUCK',  'TONMOV', '0063100100', 1100000),
    ('RCNTR_LIXIV_SXEW',  'TONAPI', '0061100400', round(f.msl * 1.10, -3)),
    ('RCNTR_LIXIV_SXEW',  'TONAPI', '0062100300', 1300000),
    ('RCNTR_LIXIV_SXEW',  'TONAPI', '0061100100', round(420000 + (520000 - 420000) * f.decay, -3)),
    ('RCNTR_LIXIV_SXEW',  'TONAPI', '0062100100', 310000),
    ('RCNTR_LIXIV_SXEW',  'TONAPI', '0063100100', 780000),
    ('RCNTR_CONCEN_FLOT', 'TONPRO', '0062100300', 4200000),
    ('RCNTR_CONCEN_FLOT', 'TONPRO', '0061100100', 1800000),
    ('RCNTR_CONCEN_FLOT', 'TONPRO', '0061100400', round(1250000 + (1700000 - 1250000) * f.decay, -3)),
    ('RCNTR_CONCEN_FLOT', 'TONPRO', '0062100100', 650000),
    ('RCNTR_CONCEN_FLOT', 'TONPRO', '0063100100', 1250000),
    ('RCNTR_PUERTO_EMB',  'TONEMB', '0062100200', 520000),
    ('RCNTR_PUERTO_EMB',  'TONEMB', '0063100100', 310000),
    ('RCNTR_PUERTO_EMB',  'TONEMB', '0062100100', 140000),
    ('RCNTR_PUERTO_EMB',  'TONEMB', '0062100300', round(f.msl * 0.3654, -3))
  ) AS a(rcntr, stagr, racct, amount)
 WHERE a.rcntr = f.rcntr AND a.stagr = f.stagr;

INSERT INTO sap.finsskf (stagr, recid, date_from, grtyp, msl, runit, timestamp, rbukrs, rrcty, category, rcntr,
                         prctr, logsys)
SELECT f.stagr, upper(substr(md5('1RF18M' || 'CL01' || f.rcntr || f.stagr), 1, 22)), f.date_from, '2', f.msl,
       f.runit, 20261028100000, 'CL01', '1', 'RF18M', f.rcntr, v.prctr, 'SAC'
  FROM forecast_drivers f
  JOIN centers v USING (rcntr);

DROP TABLE centers, actual_costs, events, actual_drivers, budget_costs, budget_drivers, budget_months, horizon,
           forecast_drivers;
