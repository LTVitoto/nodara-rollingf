-- ═══════════════════════════════════════════════════════════════════════════
-- Seed data · SAP S/4HANA (simulated) — production seed of the OPEX C1 value chain: 12 cost centers,
-- every cost line priced as P x Q at G/L account level (RACCT). Synthetic: no real companies.
-- Group currency USD (KSL). Current month = 2026-10 (latest actual, open: last postings on 2026-10-27).
--   ACDOCA   6 actual months (2026-05 .. 2026-10): weekly goods issues (WA), monthly service entries (WE),
--            payroll (SA) and depreciation (AF), each with its quantity (MSL in RUNIT)
--   ACDOCP   BUDG for the same 6 months (SAC export 2025-12-15) and RF18M for 18 months (2026-11 .. 2028-04,
--            SAC export 2026-10-28): KSL = KPRICE x VMSL, fixed share VMFSL / KFSL
--   FINSSKF  the driver of every cost center: actual, BUDG and RF18M
-- Quantities follow the driver through budget specific consumptions (rate per driver unit) or a fixed
-- daily capacity. Deterministic noise (md5) keeps the seed reproducible. 2026-10 carries the 4 events of
-- the bitácoras, at input level:
--   RCNTR_MIN_PERF  abrasive rock: drill-bit life 2,400 → 1,550 m              Q on RACCT_ACEROS
--   RCNTR_CON_FLOT  xanthate supplier tariff 3.18 → 4.05 USD/kg               P on RACCT_REACTIVOS
--   RCNTR_CON_MOLI  SAG liner failure: 58 h stop, overtime hours and premium   Q + P on RACCT_LABOR;
--                   −9 % throughput that flows to flotation, tailings and filtering
--   RCNTR_PTO_EMBA  no vessel berthed: zero shipments                          driver 0; RACCT_LABOR and
--                                                                              RACCT_MANTEN stay fixed
-- ═══════════════════════════════════════════════════════════════════════════

-- Deterministic noise in [-amplitude, +amplitude] derived from a key (reproducible, no random()).
CREATE FUNCTION pg_temp.noise(p_key text, p_amplitude numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_amplitude * (((('x' || substr(md5(p_key), 1, 7))::bit(28)::int % 2001) - 1000) / 1000.0)
$$;

CREATE FUNCTION pg_temp.month_label(p_date date) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT (ARRAY['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'])
               [extract(month FROM p_date)::int] || '-' || extract(year FROM p_date)::int
$$;

-- ── Months: 6 actual months with their budget, then the 18 forecast months ──
CREATE TEMPORARY TABLE periods AS
SELECT horizon, n, m::date AS period_start, extract(day FROM m + interval '1 month - 1 day')::int AS days,
       (m + interval '1 month - 1 day')::date AS period_end
  FROM (SELECT 'ACTUAL' AS horizon, n, date '2026-05-01' + make_interval(months => n - 1) AS m
          FROM generate_series(1, 6) AS n
        UNION ALL
        SELECT 'RF18M', n, date '2026-11-01' + make_interval(months => n - 1)
          FROM generate_series(1, 18) AS n) x;

-- ── Cost centers of the OPEX C1 value chain and their driver (FINSSKF statistical key figure) ──
CREATE TEMPORARY TABLE centers (seq, rcntr, prctr, logsys, stagr, runit, daily) AS VALUES
    (1,  'RCNTR_MIN_PERF', 'CL01MINA', 'DISPATCH', 'METPER', 'M',     4800),   -- meters drilled
    (2,  'RCNTR_MIN_TRON', 'CL01MINA', 'DISPATCH', 'TONTRO', 'TO',  405000),   -- tonnes blasted
    (3,  'RCNTR_MIN_CARG', 'CL01MINA', 'DISPATCH', 'TONCAR', 'TO',  400000),   -- tonnes loaded
    (4,  'RCNTR_MIN_TRAN', 'CL01MINA', 'DISPATCH', 'TONMOV', 'TO',  400000),   -- tonnes hauled
    (5,  'RCNTR_CON_MOLI', 'CL01CONC', 'PIMS',     'TONMOL', 'TO',  100000),   -- tonnes milled
    (6,  'RCNTR_CON_FLOT', 'CL01CONC', 'PIMS',     'TONFLO', 'TO',  100000),   -- tonnes floated
    (7,  'RCNTR_CON_RELA', 'CL01CONC', 'PIMS',     'TONREL', 'TO',   97000),   -- tailings deposited
    (8,  'RCNTR_LIX_RIEG', 'CL01LIXI', 'PIMS',     'TONAPI', 'TO',   48000),   -- tonnes stacked under irrigation
    (9,  'RCNTR_LIX_SX',   'CL01LIXI', 'PIMS',     'M3PLS',  'M3',   60000),   -- PLS treated
    (10, 'RCNTR_LIX_EW',   'CL01LIXI', 'PIMS',     'TONCAT', 'TO',     165),   -- copper cathode
    (11, 'RCNTR_PTO_FILT', 'CL01PUER', 'PORTMS',   'TONFIL', 'WMT',   3300),   -- concentrate filtered
    (12, 'RCNTR_PTO_EMBA', 'CL01PUER', 'PORTMS',   'TONEMB', 'WMT',   3300);   -- concentrate shipped

-- ── Cost lines per cost center and G/L account (budget 2026) ──
-- behavior: V variable (rate = specific consumption per driver unit), F fixed (capacity per calendar day),
-- M mixed (fixed per day + rate per driver unit), A amount only (monthly USD, no quantity).
-- blart: WA goods issue (posted weekly), WE service entry, SA payroll, AF depreciation (monthly).
CREATE TEMPORARY TABLE lines (rcntr, racct, runit, behavior, rate, fixed_daily, price, blart, usnam, matnr, sgtxt) AS VALUES
    -- Perforación · per meter drilled
    ('RCNTR_MIN_PERF', 'RACCT_ACEROS',    'PC',  'V', 1 / 2400.0,     0, 10850.00, 'WA', 'MMBODEGA',  'SKU-CL-BRO-1058',  'Brocas tricónicas 10 5/8 perforación'),
    ('RCNTR_MIN_PERF', 'RACCT_DIESEL',    'L',   'V', 2.65,           0,     1.042, 'WA', 'MMBODEGA',  'SKU-CL-DSL-B5',    'Diésel perforadoras'),
    ('RCNTR_MIN_PERF', 'RACCT_LABOR',     'HR',  'F', 0,            470,    33.80, 'SA', 'HRNOMINA',  NULL,               'Horas hombre perforación'),
    ('RCNTR_MIN_PERF', 'RACCT_MANTEN',    'HR',  'F', 0,            120,    86.50, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención perforadoras'),
    ('RCNTR_MIN_PERF', 'RACCT_DEPREC',    NULL,  'A', 429200,         0,     NULL, 'AF', 'FIAA',      NULL,               'Depreciación flota de perforadoras'),
    -- Tronadura · per tonne blasted
    ('RCNTR_MIN_TRON', 'RACCT_EXPLOSIV',  'KG',  'V', 0.305,          0,    0.912, 'WA', 'MMBODEGA',  'SKU-CL-ANFO-EMU',  'Explosivo ANFO y emulsión'),
    ('RCNTR_MIN_TRON', 'RACCT_ACCESOR',   'PC',  'V', 0.00165,        0,    21.70, 'WA', 'MMBODEGA',  'SKU-CL-DET-ELEC',  'Detonadores electrónicos y boosters'),
    ('RCNTR_MIN_TRON', 'RACCT_SERVIC',    'HR',  'V', 0.00026,        0,   118.00, 'WE', 'MMCOMPRAS', NULL,               'Servicio camión fábrica de explosivos'),
    ('RCNTR_MIN_TRON', 'RACCT_LABOR',     'HR',  'F', 0,            350,    34.10, 'SA', 'HRNOMINA',  NULL,               'Horas hombre tronadura'),
    -- Carguío · per tonne loaded
    ('RCNTR_MIN_CARG', 'RACCT_ENERGIA',   'KWH', 'V', 0.41,           0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía palas eléctricas'),
    ('RCNTR_MIN_CARG', 'RACCT_DIESEL',    'L',   'V', 0.052,          0,    1.042, 'WA', 'MMBODEGA',  'SKU-CL-DSL-B5',    'Diésel cargadores frontales'),
    ('RCNTR_MIN_CARG', 'RACCT_REPUEST',   'PC',  'V', 0.000122,       0,   640.00, 'WA', 'MMBODEGA',  'SKU-CL-GET-PALA',  'Dientes y adaptadores de pala'),
    ('RCNTR_MIN_CARG', 'RACCT_LABOR',     'HR',  'F', 0,            590,    34.10, 'SA', 'HRNOMINA',  NULL,               'Horas hombre carguío'),
    ('RCNTR_MIN_CARG', 'RACCT_DEPREC',    NULL,  'A', 1056600,        0,     NULL, 'AF', 'FIAA',      NULL,               'Depreciación palas y cargadores'),
    -- Transporte · per tonne hauled
    ('RCNTR_MIN_TRAN', 'RACCT_DIESEL',    'L',   'V', 0.452,          0,    1.042, 'WA', 'MMBODEGA',  'SKU-CL-DSL-B5',    'Diésel camiones de extracción'),
    ('RCNTR_MIN_TRAN', 'RACCT_NEUMAT',    'PC',  'V', 0.0000046,      0, 41800.00, 'WA', 'MMBODEGA',  'SKU-CL-NEU-5980R63', 'Neumáticos 59/80R63 CAEX'),
    ('RCNTR_MIN_TRAN', 'RACCT_REPUEST',   'PC',  'V', 0.00049,        0,   245.00, 'WA', 'MMBODEGA',  'SKU-CL-REP-930E',  'Repuestos CAEX'),
    ('RCNTR_MIN_TRAN', 'RACCT_LABOR',     'HR',  'F', 0,           1570,    33.80, 'SA', 'HRNOMINA',  NULL,               'Horas hombre transporte'),
    ('RCNTR_MIN_TRAN', 'RACCT_DEPREC',    NULL,  'A', 2924000,        0,     NULL, 'AF', 'FIAA',      NULL,               'Depreciación flota CAEX'),
    -- Molienda · per tonne milled
    ('RCNTR_CON_MOLI', 'RACCT_ENERGIA',   'KWH', 'V', 14.2,           0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía molinos SAG y de bolas'),
    ('RCNTR_CON_MOLI', 'RACCT_BOLAS',     'KG',  'V', 0.62,           0,    1.268, 'WA', 'MMBODEGA',  'SKU-CL-BOL-5PUL',  'Bolas de molienda 5 pulgadas'),
    ('RCNTR_CON_MOLI', 'RACCT_REVEST',    'KG',  'V', 0.058,          0,     3.42, 'WA', 'MMBODEGA',  'SKU-CL-LIN-SAG',   'Revestimientos molino SAG'),
    ('RCNTR_CON_MOLI', 'RACCT_LABOR',     'HR',  'F', 0,            201,    36.20, 'SA', 'HRNOMINA',  NULL,               'Horas hombre molienda'),
    ('RCNTR_CON_MOLI', 'RACCT_MANTEN',    'HR',  'F', 0,             66,    89.00, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención molinos'),
    -- Flotación · per tonne floated
    ('RCNTR_CON_FLOT', 'RACCT_REACTIVOS', 'KG',  'V', 0.0235,         0,     3.18, 'WA', 'MMBODEGA',  'SKU-CL-XAN-SIPX',  'Colector xantato SIPX'),
    ('RCNTR_CON_FLOT', 'RACCT_CAL',       'KG',  'V', 0.88,           0,    0.162, 'WA', 'MMBODEGA',  'SKU-CL-CAL-VIVA',  'Cal viva regulador de pH'),
    ('RCNTR_CON_FLOT', 'RACCT_ENERGIA',   'KWH', 'V', 2.6,            0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía celdas y sopladores'),
    ('RCNTR_CON_FLOT', 'RACCT_LABOR',     'HR',  'F', 0,            143,    36.20, 'SA', 'HRNOMINA',  NULL,               'Horas hombre flotación'),
    ('RCNTR_CON_FLOT', 'RACCT_MANTEN',    'HR',  'F', 0,             40,    89.00, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención flotación'),
    -- Relaves · per tonne of tailings
    ('RCNTR_CON_RELA', 'RACCT_ENERGIA',   'KWH', 'V', 1.82,           0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía bombeo de relaves'),
    ('RCNTR_CON_RELA', 'RACCT_FLOCUL',    'KG',  'V', 0.0248,         0,     3.85, 'WA', 'MMBODEGA',  'SKU-CL-FLO-ANION', 'Floculante espesadores'),
    ('RCNTR_CON_RELA', 'RACCT_AGUA',      'M3',  'V', 0.31,           0,     1.12, 'WE', 'MMCOMPRAS', NULL,               'Agua de reposición'),
    ('RCNTR_CON_RELA', 'RACCT_LABOR',     'HR',  'F', 0,             85,    36.20, 'SA', 'HRNOMINA',  NULL,               'Horas hombre relaves'),
    ('RCNTR_CON_RELA', 'RACCT_MANTEN',    'HR',  'F', 0,             30,    89.00, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención relaves'),
    -- Riego (lixiviación en pilas) · per tonne under irrigation
    ('RCNTR_LIX_RIEG', 'RACCT_ACIDO',     'TO',  'V', 0.0248,         0,   132.00, 'WA', 'MMBODEGA',  'SKU-CL-H2SO4',     'Ácido sulfúrico curado y riego'),
    ('RCNTR_LIX_RIEG', 'RACCT_AGUA',      'M3',  'V', 0.21,           0,     1.12, 'WE', 'MMCOMPRAS', NULL,               'Agua de proceso riego'),
    ('RCNTR_LIX_RIEG', 'RACCT_ENERGIA',   'KWH', 'V', 1.18,           0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía bombeo de soluciones'),
    ('RCNTR_LIX_RIEG', 'RACCT_LABOR',     'HR',  'F', 0,             98,    34.10, 'SA', 'HRNOMINA',  NULL,               'Horas hombre riego'),
    ('RCNTR_LIX_RIEG', 'RACCT_MANTEN',    'HR',  'F', 0,             36,    86.50, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención red de riego'),
    -- Extracción por solventes · per m3 of PLS
    ('RCNTR_LIX_SX',   'RACCT_EXTRACT',   'KG',  'V', 0.0041,         0,    22.40, 'WA', 'MMBODEGA',  'SKU-CL-EXT-ORG',   'Extractante orgánico reposición'),
    ('RCNTR_LIX_SX',   'RACCT_DILUY',     'L',   'V', 0.036,          0,     1.21, 'WA', 'MMBODEGA',  'SKU-CL-DIL-KERO',  'Diluyente queroseno'),
    ('RCNTR_LIX_SX',   'RACCT_ENERGIA',   'KWH', 'V', 0.92,           0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía planta SX'),
    ('RCNTR_LIX_SX',   'RACCT_LABOR',     'HR',  'F', 0,             78,    36.20, 'SA', 'HRNOMINA',  NULL,               'Horas hombre SX'),
    ('RCNTR_LIX_SX',   'RACCT_MANTEN',    'HR',  'F', 0,             23,    89.00, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención SX'),
    -- Electro-obtención · per tonne of cathode
    ('RCNTR_LIX_EW',   'RACCT_ENERGIA',   'KWH', 'V', 2010,           0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía rectificadores EW'),
    ('RCNTR_LIX_EW',   'RACCT_ADITIVOS',  'KG',  'V', 0.61,           0,    27.80, 'WA', 'MMBODEGA',  'SKU-CL-ADT-COSO4', 'Aditivos electrolito cobalto y guar'),
    ('RCNTR_LIX_EW',   'RACCT_ANODOS',    'PC',  'V', 0.0205,         0,  1120.00, 'WA', 'MMBODEGA',  'SKU-CL-ANO-PB',    'Ánodos de plomo reposición'),
    ('RCNTR_LIX_EW',   'RACCT_LABOR',     'HR',  'F', 0,            169,    36.20, 'SA', 'HRNOMINA',  NULL,               'Horas hombre EW'),
    ('RCNTR_LIX_EW',   'RACCT_MANTEN',    'HR',  'F', 0,             29,    89.00, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención EW'),
    -- Filtrado de concentrado · per wet tonne filtered
    ('RCNTR_PTO_FILT', 'RACCT_ENERGIA',   'KWH', 'V', 12.1,           0,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía filtros prensa'),
    ('RCNTR_PTO_FILT', 'RACCT_TELAS',     'PC',  'V', 0.00041,        0,   905.00, 'WA', 'MMBODEGA',  'SKU-CL-TEL-FILT',  'Telas filtrantes'),
    ('RCNTR_PTO_FILT', 'RACCT_AGUA',      'M3',  'V', 0.152,          0,     1.12, 'WE', 'MMCOMPRAS', NULL,               'Agua de lavado de telas'),
    ('RCNTR_PTO_FILT', 'RACCT_LABOR',     'HR',  'F', 0,             71,    34.10, 'SA', 'HRNOMINA',  NULL,               'Horas hombre filtrado'),
    ('RCNTR_PTO_FILT', 'RACCT_MANTEN',    'HR',  'F', 0,             26,    86.50, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención filtros'),
    -- Embarque · per wet tonne shipped
    ('RCNTR_PTO_EMBA', 'RACCT_ENERGIA',   'KWH', 'M', 3.45,        1500,   0.1085, 'WE', 'MMCOMPRAS', NULL,               'Energía correas y cargador de barcos'),
    ('RCNTR_PTO_EMBA', 'RACCT_ALMAC',     NULL,  'A', 521000,         0,     NULL, 'WE', 'MMCOMPRAS', NULL,               'Arriendo cancha de concentrado'),
    ('RCNTR_PTO_EMBA', 'RACCT_LABOR',     'HR',  'F', 0,            194,    34.10, 'SA', 'HRNOMINA',  NULL,               'Horas hombre estiba'),
    ('RCNTR_PTO_EMBA', 'RACCT_MANTEN',    'HR',  'F', 0,             45,    86.50, 'WE', 'MMCOMPRAS', NULL,               'Servicio mantención muelle'),
    ('RCNTR_PTO_EMBA', 'RACCT_DEPREC',    NULL,  'A', 311400,         0,     NULL, 'AF', 'FIAA',      NULL,               'Depreciación muelle y cargador');

-- ── Planned drivers: daily rate x calendar days ──
-- RF18M: the mill ramps up after the reline (98.5 % in 2026-11, downstream included) and the port
-- clears the October stockpile (+45 / +30 / +15 / +5 % shipments).
CREATE TEMPORARY TABLE plan_drivers AS
SELECT CASE p.horizon WHEN 'ACTUAL' THEN 'BUDG' ELSE 'RF18M' END AS category, p.n, p.period_start, p.days,
       p.period_end, c.rcntr,
       round(c.daily * p.days
             * CASE WHEN p.horizon = 'RF18M' AND p.n = 1
                         AND c.rcntr IN ('RCNTR_CON_MOLI', 'RCNTR_CON_FLOT', 'RCNTR_CON_RELA', 'RCNTR_PTO_FILT')
                    THEN 0.985 ELSE 1 END
             * CASE WHEN p.horizon = 'RF18M' AND c.rcntr = 'RCNTR_PTO_EMBA'
                    THEN coalesce((ARRAY[1.45, 1.30, 1.15, 1.05])[p.n], 1) ELSE 1 END) AS msl
  FROM periods p CROSS JOIN centers c;

-- ── Actual drivers: budget ± operational noise, linked along the ore stream ──
CREATE TEMPORARY TABLE actual_drivers AS
SELECT n, period_start, days, least(period_end, date '2026-10-27') AS budat, rcntr, msl AS budget,
       round(msl * (1 + pg_temp.noise('D-' || rcntr || '-' || n, 0.025))) AS msl
  FROM plan_drivers WHERE category = 'BUDG';
-- 2026-10: the SAG mill stopped 58 h for the emergency reline (-9 % throughput).
UPDATE actual_drivers SET msl = round(budget * 0.91) WHERE n = 6 AND rcntr = 'RCNTR_CON_MOLI';
-- One ore stream: loaded = hauled, blasted ≈ 1.0125 x loaded; flotation = mill; tailings 97 % and
-- concentrate 3.3 % (± mass pull) of the mill; shipments follow the concentrate (vessel timing ± 6 %),
-- and no vessel berthed in 2026-10.
UPDATE actual_drivers d SET msl = s.msl FROM actual_drivers s
 WHERE s.n = d.n AND s.rcntr = 'RCNTR_MIN_TRAN' AND d.rcntr = 'RCNTR_MIN_CARG';
UPDATE actual_drivers d SET msl = round(s.msl * 1.0125 * (1 + pg_temp.noise('D-BLAST-' || d.n, 0.012)))
  FROM actual_drivers s WHERE s.n = d.n AND s.rcntr = 'RCNTR_MIN_CARG' AND d.rcntr = 'RCNTR_MIN_TRON';
UPDATE actual_drivers d SET msl = s.msl FROM actual_drivers s
 WHERE s.n = d.n AND s.rcntr = 'RCNTR_CON_MOLI' AND d.rcntr = 'RCNTR_CON_FLOT';
UPDATE actual_drivers d SET msl = round(s.msl * 0.97) FROM actual_drivers s
 WHERE s.n = d.n AND s.rcntr = 'RCNTR_CON_MOLI' AND d.rcntr = 'RCNTR_CON_RELA';
UPDATE actual_drivers d SET msl = round(s.msl * 0.033 * (1 + pg_temp.noise('D-PULL-' || d.n, 0.02)))
  FROM actual_drivers s WHERE s.n = d.n AND s.rcntr = 'RCNTR_CON_MOLI' AND d.rcntr = 'RCNTR_PTO_FILT';
UPDATE actual_drivers d SET msl = CASE WHEN d.n = 6 THEN 0 ELSE round(s.msl * (1 + pg_temp.noise('D-SHIP-' || d.n, 0.06))) END
  FROM actual_drivers s WHERE s.n = d.n AND s.rcntr = 'RCNTR_PTO_FILT' AND d.rcntr = 'RCNTR_PTO_EMBA';

-- ── 2026-10 events at input level (factors over the budget specific consumption, fixed quantity or price) ──
CREATE TEMPORARY TABLE events (n, rcntr, racct, sc_factor, q_factor, p_factor) AS VALUES
    (6, 'RCNTR_MIN_PERF', 'RACCT_ACEROS',    2400.0 / 1550 - 1, NULL::numeric, NULL::numeric),  -- bit life 2,400 → 1,550 m
    (6, 'RCNTR_CON_FLOT', 'RACCT_REACTIVOS', NULL,              NULL,          4.05 / 3.18 - 1), -- new xanthate tariff
    (6, 'RCNTR_CON_MOLI', 'RACCT_LABOR',     NULL,              0.38,          0.095),           -- reline overtime + premium
    (6, 'RCNTR_PTO_EMBA', 'RACCT_LABOR',     NULL,              0,             0),               -- crews kept without vessels
    (6, 'RCNTR_PTO_EMBA', 'RACCT_MANTEN',    NULL,              0,             0),
    (6, 'RCNTR_PTO_EMBA', 'RACCT_ENERGIA',   0,                 0,             0);               -- base load only

-- ── Actual consumption and price per month: V = rate x driver, F = capacity x days, M = both ──
-- Commodity-indexed inputs (diesel, explosives, acid) move with the monthly market index (± 2 %);
-- contract prices (energy PPA, wages, services, reagents, parts) stay at budget unless an event says so.
CREATE TEMPORARY TABLE actual_lines AS
SELECT l.rcntr, l.racct, l.runit, l.behavior, l.rate, l.blart, l.usnam, l.matnr, l.sgtxt, c.seq, c.prctr,
       d.n, d.period_start, d.days, d.budat,
       CASE l.behavior
            WHEN 'V' THEN round(l.rate * (1 + f.sc) * d.msl)
            WHEN 'F' THEN round(l.fixed_daily * d.days * (1 + f.q))
            WHEN 'M' THEN round(l.fixed_daily * d.days * (1 + f.q)) + round(l.rate * (1 + f.sc) * d.msl)
       END AS quantity,
       round(l.price * (1 + f.p), 4) AS price
  FROM lines l
  JOIN centers c USING (rcntr)
  JOIN actual_drivers d USING (rcntr)
  LEFT JOIN events e ON e.n = d.n AND e.rcntr = l.rcntr AND e.racct = l.racct
 CROSS JOIN LATERAL (SELECT
        coalesce(e.sc_factor, pg_temp.noise('S-' || l.rcntr || '-' || l.racct || '-' || d.n, 0.012)) AS sc,
        coalesce(e.q_factor, pg_temp.noise('Q-' || l.rcntr || '-' || l.racct || '-' || d.n, 0.010)) AS q,
        coalesce(e.p_factor, CASE WHEN l.racct IN ('RACCT_DIESEL', 'RACCT_EXPLOSIV', 'RACCT_ACIDO')
                                  THEN pg_temp.noise('P-' || l.racct || '-' || d.n, 0.020) ELSE 0 END) AS p) f;

-- ── ACDOCA · balanced documents: weekly goods issues (days 7, 14, 21 and the last posting date of the
-- month) and monthly service entries, payroll and depreciation. Quantities split without remainder.
WITH postings AS (
    SELECT a.rcntr, a.racct, a.runit, a.blart, a.usnam, a.matnr, a.seq, a.prctr,
           a.sgtxt || ' ' || pg_temp.month_label(a.period_start) || ' S' || w.k AS sgtxt,
           CASE WHEN w.k < 4 THEN a.period_start + (7 * w.k - 1) ELSE a.budat END AS posted,
           round(a.quantity * w.cum) - round(a.quantity * w.prev) AS quantity, a.price, NULL::numeric AS amount
      FROM actual_lines a
     CROSS JOIN LATERAL (VALUES (1, 7.0 / a.days, 0.0), (2, 14.0 / a.days, 7.0 / a.days),
                                (3, 21.0 / a.days, 14.0 / a.days), (4, 1.0, 21.0 / a.days)) AS w(k, cum, prev)
     WHERE a.blart = 'WA'
    UNION ALL
    SELECT a.rcntr, a.racct, a.runit, a.blart, a.usnam, a.matnr, a.seq, a.prctr,
           a.sgtxt || ' ' || pg_temp.month_label(a.period_start), a.budat, a.quantity, a.price,
           CASE WHEN a.behavior = 'A' THEN a.rate END
      FROM actual_lines a
     WHERE a.blart <> 'WA')
SELECT sap.post_cost_center_document(
           CASE p.blart WHEN 'WA' THEN '49000' WHEN 'WE' THEN '50000' WHEN 'SA' THEN '01000' ELSE '02000' END
               || (10000 + row_number() OVER (PARTITION BY p.blart ORDER BY p.posted, p.seq, p.racct))::text,
           p.posted, p.blart, p.racct, p.rcntr, p.prctr, coalesce(p.amount, round(p.price * p.quantity, 2)),
           p.quantity, p.runit, p.sgtxt, p.usnam, p.matnr)
  FROM postings p
 ORDER BY p.posted, p.seq, p.racct;

-- ── ACDOCP · plan lines (BUDG and RF18M) from the planned drivers ──
-- RF18M: abrasive rock persists at drilling (+40 / +25 / +12 / +5 % steel consumption), the new xanthate
-- tariff (4.05 USD/kg) stays, wages are indexed +3.8 % in 2027 and +3.6 % more in 2028.
CREATE TEMPORARY TABLE plan_lines AS
SELECT d.category, d.n, d.period_end, l.rcntr, l.racct, l.runit, l.behavior, c.seq, c.prctr, q.quantity,
       q.fixed_quantity, CASE WHEN l.behavior <> 'A' THEN round(l.price * pr.factor, 4) END AS price,
       CASE WHEN l.behavior = 'A' THEN l.rate END AS amount
  FROM lines l
  JOIN centers c USING (rcntr)
  JOIN plan_drivers d USING (rcntr)
 CROSS JOIN LATERAL (SELECT
        CASE WHEN d.category = 'RF18M' AND l.rcntr = 'RCNTR_MIN_PERF' AND l.racct = 'RACCT_ACEROS'
             THEN coalesce((ARRAY[1.40, 1.25, 1.12, 1.05])[d.n], 1) ELSE 1 END AS sc) s
 CROSS JOIN LATERAL (SELECT
        CASE WHEN d.category = 'RF18M' AND l.racct = 'RACCT_REACTIVOS' THEN 4.05 / l.price
             WHEN d.category = 'RF18M' AND l.racct = 'RACCT_LABOR' AND d.period_start >= date '2028-01-01' THEN 1.038 * 1.036
             WHEN d.category = 'RF18M' AND l.racct = 'RACCT_LABOR' AND d.period_start >= date '2027-01-01' THEN 1.038
             ELSE 1 END AS factor) pr
 CROSS JOIN LATERAL (SELECT
        CASE l.behavior WHEN 'V' THEN round(l.rate * s.sc * d.msl)
                        WHEN 'F' THEN round((l.fixed_daily * d.days)::numeric)
                        WHEN 'M' THEN round((l.fixed_daily * d.days)::numeric) + round(l.rate * d.msl)
                        ELSE 0 END AS quantity,
        CASE l.behavior WHEN 'F' THEN round((l.fixed_daily * d.days)::numeric)
                        WHEN 'M' THEN round((l.fixed_daily * d.days)::numeric)
                        ELSE 0 END AS fixed_quantity) q;

INSERT INTO sap.acdocp (reqtsn, datapakid, record, ryear, rbukrs, category, racct, wsl, hsl, ksl, wfsl, hfsl, kfsl,
                        wprice, hprice, kprice, rvunit, vmsl, vmfsl, rcntr, prctr, poper, fiscyearper, budat,
                        sgtxt, usnam)
SELECT CASE p.category WHEN 'BUDG' THEN '20251215100000000000001' ELSE '20261028100000000000001' END, '000001',
       row_number() OVER (PARTITION BY p.category ORDER BY p.n, p.seq, p.racct)::int,
       to_char(p.period_end, 'YYYY'), 'CL01', p.category, p.racct, v.ksl, v.ksl, v.ksl, v.kfsl, v.kfsl, v.kfsl,
       p.price, p.price, p.price, p.runit, p.quantity, p.fixed_quantity, p.rcntr, p.prctr,
       to_char(p.period_end, '"0"MM'), to_char(p.period_end, 'YYYY"0"MM'), p.period_end,
       CASE p.category WHEN 'BUDG' THEN 'SAC Presupuesto base 2026' ELSE 'SAC Rolling Forecast 18M ciclo 2026-10' END,
       'SAC_EXPORT'
  FROM plan_lines p
 CROSS JOIN LATERAL (SELECT coalesce(p.amount, round(p.price * p.quantity, 2)) AS ksl,
                            coalesce(p.amount, round(p.price * p.fixed_quantity, 2)) AS kfsl) v;

-- ── FINSSKF · drivers: actuals from the source systems, BUDG and RF18M from SAC ──
-- RECID identifies the key figure item (record type, category, company code, cost center, key figure).
INSERT INTO sap.finsskf (stagr, recid, date_from, grtyp, msl, runit, timestamp, rbukrs, rrcty, category, rcntr,
                         prctr, logsys)
SELECT c.stagr, upper(substr(md5('0' || 'CL01' || c.rcntr || c.stagr), 1, 22)), d.period_start, '2', d.msl, c.runit,
       to_char(d.budat, 'YYYYMMDD')::numeric * 1000000 + 235900, 'CL01', '0', '', c.rcntr, c.prctr, c.logsys
  FROM actual_drivers d JOIN centers c USING (rcntr)
UNION ALL
SELECT c.stagr, upper(substr(md5('1' || p.category || 'CL01' || c.rcntr || c.stagr), 1, 22)), p.period_start, '2',
       p.msl, c.runit, CASE p.category WHEN 'BUDG' THEN 20251215100000 ELSE 20261028100000 END, 'CL01', '1',
       p.category, c.rcntr, c.prctr, 'SAC'
  FROM plan_drivers p JOIN centers c USING (rcntr);

DROP TABLE periods, centers, lines, plan_drivers, actual_drivers, events, actual_lines, plan_lines;
