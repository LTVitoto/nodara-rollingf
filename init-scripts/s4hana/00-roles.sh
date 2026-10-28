#!/bin/bash
# Technical roles with least privilege (passwords injected from .env, never hardcoded):
#   debezium → logical replication for CDC (pgoutput)
#   trino_ro → read-only live federation from Trino
# Source-safe: the postgres entrypoint may source this file instead of executing it.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
     -v debezium_pw="$S4_DEBEZIUM_PASSWORD" -v trino_pw="$S4_TRINO_PASSWORD" <<-'EOSQL'
	CREATE ROLE debezium WITH LOGIN REPLICATION PASSWORD :'debezium_pw';
	CREATE ROLE trino_ro WITH LOGIN PASSWORD :'trino_pw';
	COMMENT ON ROLE debezium IS 'CDC capture (Debezium pgoutput) - replication + SELECT on sap.*';
	COMMENT ON ROLE trino_ro IS 'Read-only federation from Trino - SELECT on sap.*';
EOSQL
