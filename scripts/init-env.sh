#!/usr/bin/env bash
# Creates .env from .env.example or, when .env already exists, appends only the keys it is
# missing. Secrets get random values; existing values are never modified. NVIDIA_API_KEY is
# never generated: paste your own key into .env.
set -euo pipefail
cd "$(dirname "$0")/.."

random_hex() { od -An -N"${1:-20}" -tx1 /dev/urandom | tr -d ' \n'; }
value_for() {  # $1 key, $2 template value
  case $1 in
    LANGFUSE_PUBLIC_KEY) echo "pk-lf-$(random_hex 16)" ;;
    LANGFUSE_SECRET_KEY) echo "sk-lf-$(random_hex 16)" ;;
    *_PASSWORD | *_SECRET_KEY | *_SECRET | *_SALT) random_hex 20 ;;
    *) echo "$2" ;;
  esac
}

if [[ ! -f .env ]]; then
  : > .env
  chmod 600 .env
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
      echo "${BASH_REMATCH[1]}=$(value_for "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"
    else
      echo "$line"
    fi
  done < .env.example >> .env
  echo "[env] .env creado con secretos aleatorios (chmod 600)."
  exit 0
fi

added=()
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line =~ ^([A-Z0-9_]+)=(.*)$ ]] || continue
  key=${BASH_REMATCH[1]}
  grep -q "^${key}=" .env && continue
  (( ${#added[@]} )) || printf '\n# Agregado por make env (%s)\n' "$(date +%F)" >> .env
  echo "${key}=$(value_for "$key" "${BASH_REMATCH[2]}")" >> .env
  added+=("$key")
done < .env.example
if (( ${#added[@]} )); then
  echo "[env] .env actualizado: ${added[*]}"
else
  echo "[env] .env al día — no se modifica."
fi
