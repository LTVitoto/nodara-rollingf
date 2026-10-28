-- ═══════════════════════════════════════════════════════════════════════════
-- Nodara Rolling Forecast · SAP S/4HANA (simulated) — financial layer, purely relational
-- SAP tables kept with their original names and fields (lower case), client '100':
--   ACDOCA   Universal Journal: actual line items (past). OPEX in group currency (KSL) and the physical
--            quantity of each line (MSL in the base unit of measure RUNIT): the actual P x Q
--   ACDOCP   Plan Data Line Items exported from SAP Analytics Cloud; the plan version is the plan
--            category (CATEGORY: BUDG base budget, RF18M rolling forecast) — ACDOCP has no RVERS. Plan
--            quantity VMSL in RVUNIT, plan price KPRICE and the fixed share of each line (KFSL / VMFSL)
--   FINSSKF  General Ledger statistical key figures (current values): the physical driver of every
--            cost center as actual (RRCTY 0) and plan (RRCTY 1 + CATEGORY) values
-- Fields follow the SAP field lists delivered by the Architect: ACDOCP carries VMSL / RVUNIT (no MSL /
-- RUNIT / RUOM), ACDOCA the standard MSL / RUNIT. Company code / controlling area CL01 (Chile).
-- Functional and group currency USD, so WSL = HSL = KSL. Fiscal year variant K4: POPER = calendar month.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE SCHEMA sap;
COMMENT ON SCHEMA sap IS 'SAP S/4HANA (simulated) - Nodara Mineria Chile, company code CL01';

-- ACDOCA · Universal Journal (actuals) ───────────────────────────────────────
CREATE TABLE sap.acdoca (
    rclnt       char(3)       NOT NULL DEFAULT '100',
    rldnr       varchar(2)    NOT NULL DEFAULT '0L',      -- ledger
    rbukrs      varchar(4)    NOT NULL,                   -- company code
    gjahr       char(4)       NOT NULL,                   -- fiscal year
    belnr       varchar(10)   NOT NULL,                   -- journal entry
    docln       varchar(6)    NOT NULL,                   -- ledger line item
    periv       varchar(2)    NOT NULL DEFAULT 'K4',      -- fiscal year variant
    poper       char(3)       NOT NULL,                   -- posting period
    fiscyearper char(7)       NOT NULL,                   -- period/year YYYYPPP
    budat       date          NOT NULL,                   -- posting date
    blart       varchar(2)    NOT NULL,                   -- WA goods issue, WE service entry, SA payroll, AF depreciation
    racct       varchar(10)   NOT NULL,                   -- G/L account (CHAR 10)
    koart       varchar(1)    NOT NULL,                   -- account type: S G/L, M material, A asset
    drcrk       char(1)       NOT NULL,                   -- S debit / H credit
    rwcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- transaction currency
    wsl         numeric(23,2) NOT NULL,                   -- amount in transaction currency (signed)
    rhcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- company code currency
    hsl         numeric(23,2) NOT NULL,                   -- amount in company code currency (signed)
    rkcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- global (group) currency
    ksl         numeric(23,2) NOT NULL,                   -- amount in group currency (signed): OPEX source
    runit       varchar(3),                               -- base unit of measure of MSL (KG, L, PC, HR, KWH, M3, TO)
    msl         numeric(23,3) NOT NULL DEFAULT 0,         -- quantity in RUNIT (signed like the amount)
    kokrs       varchar(4)    NOT NULL DEFAULT 'CL01',    -- controlling area
    rcntr       varchar(10),                              -- cost center (KOSTL, CHAR 10)
    prctr       varchar(10),                              -- profit center
    matnr       varchar(40),                              -- material
    sgtxt       varchar(50),                              -- item text
    usnam       varchar(12)   NOT NULL,
    PRIMARY KEY (rclnt, rldnr, rbukrs, gjahr, belnr, docln),
    CHECK (drcrk IN ('S', 'H')),
    CHECK (poper BETWEEN '001' AND '016'),
    CHECK (fiscyearper = gjahr || poper),
    CHECK (msl = 0 OR runit IS NOT NULL)
);
CREATE INDEX acdoca_cost_center_idx ON sap.acdoca (rcntr, fiscyearper, racct);
COMMENT ON TABLE sap.acdoca IS 'Universal Journal (actuals) - balanced per BELNR; cost center lines carry the OPEX in KSL and the quantity in MSL/RUNIT';

-- ACDOCP · Plan Data Line Items (SAC export) ─────────────────────────────────
-- Loaded per request like an inbound table (REQTSN / DATAPAKID / RECORD). Cost center planning has
-- no offsetting line: plan data is not balanced. Each line is planned as price x quantity
-- (KSL = KPRICE x VMSL) with its fixed share (KFSL = KPRICE x VMFSL): fixed lines do not flex with the
-- driver, variable lines do.
CREATE TABLE sap.acdocp (
    rclnt       char(3)       NOT NULL DEFAULT '100',
    reqtsn      varchar(23)   NOT NULL,                   -- request transaction sequence number (one per export)
    datapakid   varchar(6)    NOT NULL,                   -- data packet number
    record      integer       NOT NULL,                   -- data record number
    ryear       char(4)       NOT NULL,                   -- general ledger fiscal year
    rldnr       varchar(2)    NOT NULL DEFAULT '0L',
    rbukrs      varchar(4)    NOT NULL,
    category    varchar(10)   NOT NULL,                   -- plan category = plan version (BUDG budget, RF18M forecast)
    racct       varchar(10)   NOT NULL,                   -- G/L account (CHAR 10)
    rwcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- transaction currency
    wsl         numeric(23,2) NOT NULL,
    rhcur       varchar(5)    NOT NULL DEFAULT 'USD',
    hsl         numeric(23,2) NOT NULL,
    rkcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- global (group) currency
    ksl         numeric(23,2) NOT NULL,                   -- planned OPEX in group currency
    wfsl        numeric(23,2) NOT NULL DEFAULT 0,         -- fixed amount in transaction currency
    hfsl        numeric(23,2) NOT NULL DEFAULT 0,         -- fixed amount in company code currency
    kfsl        numeric(23,2) NOT NULL DEFAULT 0,         -- fixed amount in global currency
    wprice      numeric(23,6),                            -- price in transaction currency (per RVUNIT)
    hprice      numeric(23,6),                            -- price in company code currency
    kprice      numeric(23,6),                            -- price in global currency
    rvunit      varchar(3),                               -- unit of measure for the valuation quantity
    vmsl        numeric(23,3) NOT NULL DEFAULT 0,         -- valuation quantity (planned consumption)
    vmfsl       numeric(23,3) NOT NULL DEFAULT 0,         -- fixed valuation quantity
    kokrs       varchar(4)    NOT NULL DEFAULT 'CL01',
    rcntr       varchar(10)   NOT NULL,                   -- cost center (KOSTL, CHAR 10)
    prctr       varchar(10),
    periv       varchar(2)    NOT NULL DEFAULT 'K4',
    poper       char(3)       NOT NULL,
    fiscyearper char(7)       NOT NULL,                   -- period/year YYYYPPP
    budat       date          NOT NULL,                   -- last day of the planned period
    sgtxt       varchar(50),
    usnam       varchar(12)   NOT NULL,
    PRIMARY KEY (rclnt, reqtsn, datapakid, record),
    CHECK (poper BETWEEN '001' AND '016'),
    CHECK (fiscyearper = ryear || poper),
    CHECK (vmsl = 0 OR rvunit IS NOT NULL),
    CHECK (vmfsl BETWEEN 0 AND vmsl),
    CHECK (abs(kfsl) <= abs(ksl))
);
CREATE INDEX acdocp_cost_center_idx ON sap.acdocp (rcntr, category, fiscyearper, racct);
COMMENT ON TABLE sap.acdocp IS 'Plan Data Line Items - plan per plan category (CATEGORY) exported from SAP Analytics Cloud: KSL = KPRICE x VMSL, fixed share KFSL / VMFSL';

-- FINSSKF · General Ledger: statistical key figures (current values) ────────
-- One value per key figure item and validity start (DATE_FROM). Totals values (GRTYP 2) hold the
-- quantity of the month that starts on DATE_FROM.
CREATE TABLE sap.finsskf (
    rclnt     char(3)       NOT NULL DEFAULT '100',
    stagr     varchar(6)    NOT NULL,                   -- statistical key figure: the driver of the cost center
    recid     varchar(22)   NOT NULL,                   -- statistical key figure item
    date_from date          NOT NULL,                   -- valid from
    grtyp     char(1)       NOT NULL DEFAULT '2',       -- key figure category: 1 fixed value, 2 totals value
    msl       numeric(23,3) NOT NULL,                   -- statistical key figure quantity
    runit     varchar(3)    NOT NULL,                   -- quantity unit: M meter, TO tonne, M3, WMT wet metric tonne
    timestamp numeric(15,0) NOT NULL,                   -- UTC time stamp YYYYMMDDhhmmss
    rbukrs    varchar(4)    NOT NULL,
    rrcty     char(1)       NOT NULL,                   -- record type: 0 actual, 1 plan
    category  varchar(10)   NOT NULL DEFAULT '',        -- plan category (plan values only)
    rcntr     varchar(10)   NOT NULL,                   -- cost center (KOSTL, CHAR 10)
    prctr     varchar(10),
    kokrs     varchar(4)    NOT NULL DEFAULT 'CL01',
    logsys    varchar(10),                              -- origin: DISPATCH / PIMS / PORTMS (actual), SAC (plan)
    PRIMARY KEY (rclnt, stagr, recid, date_from),
    CHECK (rrcty IN ('0', '1')),
    CHECK ((rrcty = '1') = (category <> '')),
    CHECK (grtyp IN ('1', '2')),
    CHECK (msl >= 0)
);
CREATE INDEX finsskf_cost_center_idx ON sap.finsskf (rcntr, rrcty, category, date_from);
COMMENT ON TABLE sap.finsskf IS 'Statistical key figures per cost center: the physical driver of the specific consumption and unit OPEX';

-- Number range for simulator documents (the seed uses 4900010xxx / 5000010xxx / 0100010xxx / 0200010xxx).
CREATE SEQUENCE sap.acdoca_number_seq START 4900020001;

-- Posts one balanced journal entry to a cost center (and its profit center) with its quantity, as S/4
-- does for a goods issue (WA: Dr cost element on the cost center / Cr 0013100000 inventory, the quantity
-- leaves stock), a service entry (WE: Cr 0021100000 GR/IR), payroll (SA: Cr 0024100000 payroll payable)
-- or depreciation (AF: Cr 0016900000 accumulated depreciation). USD = WSL = HSL = KSL.
CREATE FUNCTION sap.post_cost_center_document(p_belnr varchar, p_budat date, p_blart varchar, p_racct varchar,
                                              p_rcntr varchar, p_prctr varchar, p_amount numeric,
                                              p_quantity numeric, p_unit varchar, p_sgtxt varchar,
                                              p_usnam varchar, p_matnr varchar DEFAULT NULL)
RETURNS varchar
LANGUAGE plpgsql AS $$
DECLARE
    v_gjahr  char(4) := to_char(p_budat, 'YYYY');
    v_poper  char(3) := to_char(p_budat, '"0"MM');
    v_offset varchar(10) := CASE p_blart WHEN 'WA' THEN '0013100000' WHEN 'WE' THEN '0021100000'
                                         WHEN 'AF' THEN '0016900000' ELSE '0024100000' END;
BEGIN
    INSERT INTO sap.acdoca (rbukrs, gjahr, belnr, docln, poper, fiscyearper, budat, blart, racct, koart, drcrk,
                            wsl, hsl, ksl, runit, msl, rcntr, prctr, matnr, sgtxt, usnam)
    VALUES ('CL01', v_gjahr, p_belnr, '000001', v_poper, v_gjahr || v_poper, p_budat, p_blart, p_racct, 'S', 'S',
            p_amount, p_amount, p_amount, p_unit, coalesce(p_quantity, 0), p_rcntr, p_prctr, p_matnr, p_sgtxt,
            p_usnam),
           ('CL01', v_gjahr, p_belnr, '000002', v_poper, v_gjahr || v_poper, p_budat, p_blart, v_offset,
            CASE p_blart WHEN 'WA' THEN 'M' WHEN 'AF' THEN 'A' ELSE 'S' END, 'H',
            -p_amount, -p_amount, -p_amount,
            CASE p_blart WHEN 'WA' THEN p_unit END, CASE p_blart WHEN 'WA' THEN -coalesce(p_quantity, 0) ELSE 0 END,
            NULL, p_prctr, p_matnr, p_sgtxt, p_usnam);
    RETURN p_belnr;
END $$;

-- Real-time activity for CDC demos: diesel goods issues (WA) of the haul fleet (MIN_TRAN) posted
-- into the open period at the actual diesel price of that period, so the timeline moves live.
--   SELECT * FROM sap.simulate_activity(5);
CREATE FUNCTION sap.simulate_activity(p_events int DEFAULT 5)
RETURNS TABLE (belnr varchar, budat date, racct varchar, rcntr varchar, msl numeric, runit varchar, ksl numeric,
               sgtxt varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    c_rcntr CONSTANT varchar := 'MIN_TRAN';
    c_racct CONSTANT varchar := 'DIESEL';
    v_budat date;
    v_price numeric;
    v_litres numeric;
    v_belnr varchar(10);
BEGIN
    SELECT max(a.budat) INTO v_budat FROM sap.acdoca a WHERE a.rcntr = c_rcntr;
    SELECT sum(a.ksl) / nullif(sum(a.msl), 0) INTO v_price
      FROM sap.acdoca a
     WHERE a.rcntr = c_rcntr AND a.racct = c_racct AND a.fiscyearper = to_char(v_budat, 'YYYY"0"MM');
    FOR i IN 1..p_events LOOP
        v_belnr := nextval('sap.acdoca_number_seq')::text;
        v_litres := round((2000 + random() * 6000)::numeric);
        PERFORM sap.post_cost_center_document(v_belnr, v_budat, 'WA', c_racct, c_rcntr, 'CL01MINA',
                                              round(v_litres * v_price, 2), v_litres, 'L',
                                              'Despacho diésel CAEX (simulador)', 'SIMULATOR', 'SKU-CL-DSL-B5');
        RETURN QUERY
            SELECT a.belnr, a.budat, a.racct, a.rcntr, a.msl, a.runit, a.ksl, a.sgtxt
              FROM sap.acdoca a
             WHERE a.belnr = v_belnr AND a.rcntr IS NOT NULL;
    END LOOP;
END $$;
