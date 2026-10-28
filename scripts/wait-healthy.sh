#!/usr/bin/env bash
# Waits until every long-running service is healthy and every one-shot init job exited 0.
# (`docker compose up --wait` reports successfully finished init jobs as failures.)
set -uo pipefail
cd "$(dirname "$0")/.."

deadline=$(( $(date +%s) + ${WAIT_TIMEOUT:-600} ))
while :; do
  report=$(docker compose ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}')
  failed=$(awk -F'|' '$2 == "exited" && $4 != 0 {printf "%s ", $1}' <<<"$report")
  waiting=$(awk -F'|' '$2 != "exited" && $3 != "healthy" {printf "%s ", $1}' <<<"$report")
  if [[ -n $failed ]]; then
    echo "[wait] jobs/servicios con error: $failed(ver: make logs s=<servicio>)"
    exit 1
  fi
  if [[ -z $waiting ]]; then
    echo "[wait] stack listo: $(grep -c . <<<"$report") contenedores healthy o completados"
    exit 0
  fi
  if (( $(date +%s) > deadline )); then
    echo "[wait] timeout esperando: $waiting"
    exit 1
  fi
  sleep 5
done
