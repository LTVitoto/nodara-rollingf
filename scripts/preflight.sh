#!/usr/bin/env bash
# Detects host port collisions before `docker compose up`: Linux/WSL sockets plus,
# under WSL with Docker Desktop, Windows sockets (Docker Desktop publishes there too).
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; source .env; set +a; fi

if [[ -n "$(docker compose ps -q 2>/dev/null)" ]]; then
  echo "[preflight] stack en ejecución — se omite el chequeo de puertos."
  exit 0
fi

declare -A PORTS=(
  [S4_DB_PORT]=${S4_DB_PORT:-5432}           [VECTOR_DB_PORT]=${VECTOR_DB_PORT:-5433}
  [FRONTEND_PORT]=${FRONTEND_PORT:-3000}     [TRINO_PORT]=${TRINO_PORT:-8080}
  [UNITY_CATALOG_PORT]=${UNITY_CATALOG_PORT:-8081} [DEBEZIUM_PORT]=${DEBEZIUM_PORT:-8083}
  [MINIO_API_PORT]=${MINIO_API_PORT:-9000}   [MINIO_CONSOLE_PORT]=${MINIO_CONSOLE_PORT:-9001}
  [LANGFUSE_PORT]=${LANGFUSE_PORT:-3001}
)

listening() { sed -E 's/.*:([0-9]+)$/\1/' | sort -u; }
linux_busy=$(ss -ltnH 2>/dev/null | awk '{print $4}' | listening)
windows_busy=""
if command -v netstat.exe >/dev/null 2>&1; then
  windows_busy=$(netstat.exe -ano -p TCP 2>/dev/null | tr -d '\r' | awk '$4 == "LISTENING" {print $2}' | listening)
fi

fail=0
duplicates=$(printf '%s\n' "${PORTS[@]}" | sort | uniq -d)
if [[ -n $duplicates ]]; then
  echo "  ✗ puerto(s) asignado(s) a más de un servicio: $duplicates"
  fail=1
fi
for var in $(printf '%s\n' "${!PORTS[@]}" | sort); do
  port=${PORTS[$var]}
  where=""
  grep -qx "$port" <<<"$linux_busy" && where="Linux/WSL"
  grep -qx "$port" <<<"$windows_busy" && where="${where:+$where + }Windows"
  if [[ -n $where ]]; then
    echo "  ✗ $var=$port ocupado en $where"
    fail=1
  else
    echo "  ✓ $var=$port libre"
  fi
done

if (( fail )); then
  echo "[preflight] colisión detectada → ajusta el puerto en .env y reintenta."
  exit 1
fi
echo "[preflight] OK — sin colisiones de puertos."
