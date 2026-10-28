-- CDC contract for Debezium (pgoutput): full row images, explicit publication
-- (no autocreate → the CDC user needs no ownership), least-privilege grants.
-- Capturing a new table = add it here AND to cdc/connectors/s4hana-cdc.json (table.include.list).
ALTER TABLE sap.acdoca  REPLICA IDENTITY FULL;
ALTER TABLE sap.acdocp  REPLICA IDENTITY FULL;
ALTER TABLE sap.finsskf REPLICA IDENTITY FULL;

CREATE PUBLICATION nodara_s4_pub FOR TABLE sap.acdoca, sap.acdocp, sap.finsskf;

GRANT USAGE ON SCHEMA sap TO debezium, trino_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA sap TO debezium, trino_ro;
