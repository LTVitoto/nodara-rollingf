#!/usr/bin/env bash
# One-shot job (service trino-init): publishes the gold layer of the lakehouse in Trino before the backend
# starts. Waits until delta-sink has created the silver views of the CDC tables (a fresh stack needs the
# Debezium snapshot first), then applies every /gold/*.sql file in order (idempotent CREATE OR REPLACE).
set -euo pipefail

SERVER=${TRINO_SERVER:-http://trino:8080}
TIMEOUT_S=${GOLD_WAIT_TIMEOUT_S:-600}
trino_cli() { trino --server "$SERVER" --user lakehouse-init "$@"; }

deadline=$(( $(date +%s) + TIMEOUT_S ))
until [[ $(trino_cli --output-format TSV --execute \
  "SELECT count(*) FROM lakehouse.information_schema.tables
    WHERE table_schema = 'silver' AND table_name IN ('acdoca', 'acdocp', 'finsskf')" 2>/dev/null) == 3 ]]; do
  if (( $(date +%s) > deadline )); then
    echo "[trino-init] the silver views did not appear within ${TIMEOUT_S}s (delta-sink / Debezium?)" >&2
    exit 1
  fi
  echo "[trino-init] waiting for the silver views of ACDOCA, ACDOCP and FINSSKF…"
  sleep 5
done

for file in /gold/*.sql; do
  trino_cli --file "$file" >/dev/null
  echo "[trino-init] applied $(basename "$file")"
done
echo "[trino-init] gold views: $(trino_cli --output-format TSV --execute \
  "SELECT array_join(array_agg(table_name ORDER BY table_name), ', ') FROM lakehouse.information_schema.views
    WHERE table_schema = 'gold'")"
