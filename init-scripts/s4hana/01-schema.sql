-- ═══════════════════════════════════════════════════════════════════════════
-- Nodara Rolling Forecast · SAP S/4HANA (simulated) — financial layer, purely relational
-- SAP tables kept with their original names and fields (lower case), client '100':
--   ACDOCA   Universal Journal: actual line items (past). OPEX is reported in group currency (KSL).
--   ACDOCP   Plan Data Line Items: plan exported from SAP Analytics Cloud; the plan version is the
--            plan category (CATEGORY) — ACDOCP has no RVERS field (future)
--   FINSSKF  General Ledger statistical key figures (current values): physical drivers (operating
--            hours, tonnes) as actual (RRCTY 0) and plan (RRCTY 1 + CATEGORY) values
-- Company code / controlling area CL01 (Chile). Functional and group currency USD, so WSL = HSL = KSL
-- and no translation is needed. Fiscal year variant K4: posting period POPER = calendar month.
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
    blart       varchar(2)    NOT NULL,                   -- WA goods issue, WE service entry, SA G/L posting
    racct       varchar(10)   NOT NULL,                   -- G/L account (cost element on cost center lines)
    koart       varchar(1)    NOT NULL,                   -- account type: S G/L, M material
    drcrk       char(1)       NOT NULL,                   -- S debit / H credit
    rwcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- transaction currency
    wsl         numeric(23,2) NOT NULL,                   -- amount in transaction currency (signed)
    rhcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- company code currency
    hsl         numeric(23,2) NOT NULL,                   -- amount in company code currency (signed)
    rkcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- global (group) currency
    ksl         numeric(23,2) NOT NULL,                   -- amount in group currency (signed): OPEX source
    kokrs       varchar(4)    NOT NULL DEFAULT 'CL01',    -- controlling area
    rcntr       varchar(20),                              -- cost center (SAP KOSTL is CHAR 10, see TECH_DEBT)
    prctr       varchar(10),                              -- profit center
    matnr       varchar(40),                              -- material
    sgtxt       varchar(50),                              -- item text
    usnam       varchar(12)   NOT NULL,
    PRIMARY KEY (rclnt, rldnr, rbukrs, gjahr, belnr, docln),
    CHECK (drcrk IN ('S', 'H')),
    CHECK (poper BETWEEN '001' AND '016'),
    CHECK (fiscyearper = gjahr || poper)
);
CREATE INDEX acdoca_cost_center_idx ON sap.acdoca (rcntr, fiscyearper);
COMMENT ON TABLE sap.acdoca IS 'Universal Journal (actuals) - balanced per BELNR; cost center lines carry the OPEX in KSL';

-- ACDOCP · Plan Data Line Items (SAC export) ─────────────────────────────────
-- Loaded per request like an inbound table (REQTSN / DATAPAKID / RECORD). Cost center planning has
-- no offsetting line: plan data is not balanced.
CREATE TABLE sap.acdocp (
    rclnt       char(3)       NOT NULL DEFAULT '100',
    reqtsn      varchar(23)   NOT NULL,                   -- request transaction sequence number (one per export)
    datapakid   varchar(6)    NOT NULL,                   -- data packet number
    record      integer       NOT NULL,                   -- data record number
    ryear       char(4)       NOT NULL,                   -- general ledger fiscal year
    rldnr       varchar(2)    NOT NULL DEFAULT '0L',
    rbukrs      varchar(4)    NOT NULL,
    category    varchar(10)   NOT NULL,                   -- plan category = plan version (RF18M: rolling forecast 18M)
    racct       varchar(10)   NOT NULL,
    rwcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- transaction currency
    wsl         numeric(23,2) NOT NULL,
    rhcur       varchar(5)    NOT NULL DEFAULT 'USD',
    hsl         numeric(23,2) NOT NULL,
    rkcur       varchar(5)    NOT NULL DEFAULT 'USD',     -- global (group) currency
    ksl         numeric(23,2) NOT NULL,                   -- planned OPEX in group currency
    kokrs       varchar(4)    NOT NULL DEFAULT 'CL01',
    rcntr       varchar(20)   NOT NULL,
    prctr       varchar(10),
    periv       varchar(2)    NOT NULL DEFAULT 'K4',
    poper       char(3)       NOT NULL,
    fiscyearper char(7)       NOT NULL,                   -- period/year YYYYPPP
    budat       date          NOT NULL,                   -- last day of the planned period
    sgtxt       varchar(50),
    usnam       varchar(12)   NOT NULL,
    PRIMARY KEY (rclnt, reqtsn, datapakid, record),
    CHECK (poper BETWEEN '001' AND '016'),
    CHECK (fiscyearper = ryear || poper)
);
CREATE INDEX acdocp_cost_center_idx ON sap.acdocp (rcntr, category, fiscyearper);
COMMENT ON TABLE sap.acdocp IS 'Plan Data Line Items - plan per plan category (CATEGORY) exported from SAP Analytics Cloud';

-- FINSSKF · General Ledger: statistical key figures (current values) ────────
-- One value per key figure item and validity start (DATE_FROM). Totals values (GRTYP 2) hold the
-- quantity of the month that starts on DATE_FROM.
CREATE TABLE sap.finsskf (
    rclnt     char(3)       NOT NULL DEFAULT '100',
    stagr     varchar(6)    NOT NULL,                   -- statistical key figure: HOROP hours, TONMOV tonnes
    recid     varchar(22)   NOT NULL,                   -- statistical key figure item
    date_from date          NOT NULL,                   -- valid from
    grtyp     char(1)       NOT NULL DEFAULT '2',       -- key figure category: 1 fixed value, 2 totals value
    msl       numeric(23,3) NOT NULL,                   -- statistical key figure quantity
    runit     varchar(3)    NOT NULL,                   -- quantity unit: H hour, TO tonne
    timestamp numeric(15,0) NOT NULL,                   -- UTC time stamp YYYYMMDDhhmmss
    rbukrs    varchar(4)    NOT NULL,
    rrcty     char(1)       NOT NULL,                   -- record type: 0 actual, 1 plan
    category  varchar(10)   NOT NULL DEFAULT '',        -- plan category (plan values only)
    rcntr     varchar(20)   NOT NULL,
    prctr     varchar(10),
    kokrs     varchar(4)    NOT NULL DEFAULT 'CL01',
    logsys    varchar(10),                              -- logical system of origin: DISPATCH (actual), SAC (plan)
    PRIMARY KEY (rclnt, stagr, recid, date_from),
    CHECK (rrcty IN ('0', '1')),
    CHECK ((rrcty = '1') = (category <> '')),
    CHECK (grtyp IN ('1', '2')),
    CHECK (msl >= 0)
);
CREATE INDEX finsskf_cost_center_idx ON sap.finsskf (rcntr, rrcty, category, date_from);
COMMENT ON TABLE sap.finsskf IS 'Statistical key figures per cost center: operating hours (H) and tonnes hauled (TO)';

-- Number range for simulator documents (the seed uses 49000100xx / 50000100xx / 01000100xx).
CREATE SEQUENCE sap.acdoca_number_seq START 4900020001;

-- Posts one balanced journal entry to a cost center, as S/4 does for a goods issue (WA:
-- Dr cost element on the cost center / Cr 0013100000 inventory), a service entry (WE: Cr 0021100000
-- GR/IR) or a G/L posting (SA: Cr 0024100000 payroll payable). Amounts in USD = WSL = HSL = KSL.
CREATE FUNCTION sap.post_cost_center_document(p_belnr varchar, p_budat date, p_blart varchar, p_racct varchar,
                                              p_rcntr varchar, p_amount numeric, p_sgtxt varchar,
                                              p_usnam varchar, p_matnr varchar DEFAULT NULL)
RETURNS varchar
LANGUAGE plpgsql AS $$
DECLARE
    v_gjahr  char(4) := to_char(p_budat, 'YYYY');
    v_poper  char(3) := to_char(p_budat, '"0"MM');
    v_offset varchar(10) := CASE p_blart WHEN 'WA' THEN '0013100000' WHEN 'WE' THEN '0021100000' ELSE '0024100000' END;
BEGIN
    INSERT INTO sap.acdoca (rbukrs, gjahr, belnr, docln, poper, fiscyearper, budat, blart, racct, koart, drcrk,
                            wsl, hsl, ksl, rcntr, prctr, matnr, sgtxt, usnam)
    VALUES ('CL01', v_gjahr, p_belnr, '000001', v_poper, v_gjahr || v_poper, p_budat, p_blart, p_racct, 'S', 'S',
            p_amount, p_amount, p_amount, p_rcntr, 'CL01MINA', p_matnr, p_sgtxt, p_usnam),
           ('CL01', v_gjahr, p_belnr, '000002', v_poper, v_gjahr || v_poper, p_budat, p_blart, v_offset,
            CASE p_blart WHEN 'WA' THEN 'M' ELSE 'S' END, 'H',
            -p_amount, -p_amount, -p_amount, NULL, 'CL01MINA', p_matnr, p_sgtxt, p_usnam);
    RETURN p_belnr;
END $$;

-- Real-time activity for CDC demos: spare-part goods issues (WA) of the CAEX fleet posted into the
-- open period (the latest actual period of the cost center), so the timeline moves live.
--   SELECT * FROM sap.simulate_activity(5);
CREATE FUNCTION sap.simulate_activity(p_events int DEFAULT 5)
RETURNS TABLE (belnr varchar, budat date, racct varchar, rcntr varchar, ksl numeric, sgtxt varchar)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    c_rcntr CONSTANT varchar := 'RCNTR_MINA_CAEX';
    v_budat date;
    v_belnr varchar(10);
BEGIN
    SELECT max(a.budat) INTO v_budat FROM sap.acdoca a WHERE a.rcntr = c_rcntr;
    FOR i IN 1..p_events LOOP
        v_belnr := nextval('sap.acdoca_number_seq')::text;
        PERFORM sap.post_cost_center_document(v_belnr, v_budat, 'WA', '0061100100', c_rcntr,
                                              round((2000 + random() * 6000)::numeric, 2),
                                              'Consumo repuestos CAEX (simulador)', 'SIMULATOR');
        RETURN QUERY
            SELECT a.belnr, a.budat, a.racct, a.rcntr, a.ksl, a.sgtxt
              FROM sap.acdoca a
             WHERE a.belnr = v_belnr AND a.rcntr IS NOT NULL;
    END LOOP;
END $$;
