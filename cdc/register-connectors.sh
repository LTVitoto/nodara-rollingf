#!/bin/sh
# Idempotently upserts every Debezium connector in /cdc/connectors/*.json
# (PUT /connectors/<name>/config) and waits until connector + tasks are RUNNING.
set -eu
CONNECT_URL="${CONNECT_URL:-http://debezium:8083}"

for file in /cdc/connectors/*.json; do
  name=$(basename "$file" .json)
  echo "[debezium-init] upsert connector '$name'"
  curl -fsS -X PUT -H 'Content-Type: application/json' \
       --data @"$file" "$CONNECT_URL/connectors/$name/config" >/dev/null

  attempt=0
  status=""
  until status=$(curl -fsS "$CONNECT_URL/connectors/$name/status" 2>/dev/null) &&
        [ "$(echo "$status" | grep -o '"state":"RUNNING"' | wc -l)" -ge 2 ]; do
    attempt=$((attempt + 1))
    if echo "$status" | grep -q '"state":"FAILED"' || [ "$attempt" -ge 30 ]; then
      echo "[debezium-init] connector '$name' is not healthy: ${status:-no status}" >&2
      exit 1
    fi
    sleep 2
  done
  echo "[debezium-init] connector '$name' RUNNING"
done
