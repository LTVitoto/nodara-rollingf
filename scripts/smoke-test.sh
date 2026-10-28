#!/usr/bin/env bash
# E2E QA of the Nodara GenAI Financial Twin (OPEX C1 rolling forecast). Exit code 0 only if every check passes.
#   make smoke    → re-seeds silently first (make fresh), then: infrastructure; the SAP financial model with its
#                   P x Q fields (ACDOCA MSL/RUNIT, ACDOCP VMSL/RVUNIT/KPRICE/KFSL); the 12 cost centers of the
#                   OPEX C1 value chain (IDs within SAP CHAR 10) and the 4 approved anomalies; CDC → Delta bronze →
#                   silver → gold (published by trino-init before the backend, which runs no DDL; vw_opex_c1_pxq
#                   grouped by RCNTR x RACCT, no division by zero; in-memory cache); price / efficiency / volume /
#                   spending effects Trino = PostgreSQL line by line; raw layer + lineage; pgvector metadata
#                   (Año / Mes / RCNTR); the AI naming the originating RACCT and its P / Q effect in ES / EN / PT
#                   (NIM) plus the local Ollama contingency; Langfuse traces; real-time CDC; egress and air-gap
#   ./scripts/smoke-test.sh alone runs on the current data (diagnostics only: the simulator posts to ACDOCA).
#   SMOKE_RAG=0 make smoke skips the LLM calls; they also skip until `make models` was run.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; source .env; set +a; fi

DC="docker compose"
CATEGORY=RF18M
BUDGET=BUDG
PERIOD=2026-10                    # current month: the latest actual period
CENTERS=(MIN_PERF MIN_TRON MIN_CARG MIN_TRAN CON_MOLI CON_FLOT CON_RELA
         LIX_RIEG LIX_SX LIX_EW PTO_FILT PTO_EMBA)
# The 4 approved anomalies of 2026-10 and the bitácora that covers each cost center (RCNTR scope): the SAG mill stop
# also explains the downstream tailings and filtering (domino effect).
ANOMALIES=(MIN_PERF CON_FLOT CON_MOLI PTO_EMBA)
declare -A LOG=([MIN_PERF]=BIT-PERF-2026-10 [CON_FLOT]=BIT-FLOT-2026-10 [CON_MOLI]=BIT-MOLI-2026-10
                [PTO_EMBA]=BIT-EMBA-2026-10 [CON_RELA]=BIT-MOLI-2026-10 [PTO_FILT]=BIT-MOLI-2026-10)
PASS=0 FAIL=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
ko()   { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33m•\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
report() { while IFS='|' read -r verdict message; do [[ $verdict == OK ]] && ok "$message" || ko "$message"; done; }
# </dev/null: `compose exec` must never swallow the stdin of the surrounding read loops.
s4()   { $DC exec -T s4hana-db psql -U "$S4_DB_ADMIN_USER" -d s4hana -tAc "$1" </dev/null 2>/dev/null; }
kb()   { $DC exec -T vector-db psql -U "$VECTOR_DB_USER" -d knowledge -tAc "$1" </dev/null 2>/dev/null; }
sql()  { $DC exec -T trino trino --output-format TSV --execute "$1" </dev/null 2>/dev/null; }
api()  { curl -fsS --max-time "${2:-60}" "http://127.0.0.1:${FRONTEND_PORT:-3000}/api/$1"; }
s3()   { curl -fsS --aws-sigv4 "aws:amz:us-east-1:s3" --user "$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD" \
              "http://127.0.0.1:${MINIO_API_PORT:-9000}/$1"; }
s3head() { curl -fsSI --aws-sigv4 "aws:amz:us-east-1:s3" --user "$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD" \
              "http://127.0.0.1:${MINIO_API_PORT:-9000}/$1"; }
sha()  { sha256sum | cut -d' ' -f1; }
json() { python3 -c "import json, sys; data = json.load(sys.stdin); print($1)" 2>/dev/null; }  # $1: expression over `data`
egress_blocked() {  # $1 service: tries to open a TCP connection to the Internet from inside it
  $DC exec -T "$1" sh -c 'timeout 5 bash -c "exec 3<>/dev/tcp/1.1.1.1/443" 2>/dev/null ||
    timeout 5 python -c "import socket; socket.create_connection((\"1.1.1.1\", 443), 4)" 2>/dev/null' \
    </dev/null >/dev/null 2>&1
  [[ $? -ne 0 ]]
}
egress_probe() {  # $1 URL fetched from the backend through the egress gateway (HTTPS_PROXY) → HTTP status or refusal
  $DC exec -T backend python -c '
import sys, httpx
try:
    print(httpx.get(sys.argv[1], timeout=15).status_code)
except httpx.ProxyError as exc:
    print("denegado por el gateway:", exc)
except Exception as exc:
    print("sin ruta:", type(exc).__name__)' "$1" </dev/null 2>/dev/null
}
trace_check() {  # $1 trace id, $2 model: the trace reaches Langfuse with the operator as user_id, the generation and 2 spans
  local trace="" generations=0 spans=0 user=${TRACE_USER_ID:-gerente_finanzas@nodara.com}
  for _ in $(seq 1 15); do  # the SDK ships events in the background
    trace=$(curl -fsS -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
      "http://127.0.0.1:${LANGFUSE_PORT:-3001}/api/public/traces/$1" 2>/dev/null)
    generations=$(grep -o '"type":"GENERATION"' <<<"$trace" | wc -l)
    spans=$(grep -o '"type":"SPAN"' <<<"$trace" | wc -l)
    [[ $trace == *"\"name\":\"answer · $2\""* && $spans -ge 2 ]] && break
    sleep 2
  done
  if [[ $trace == *"\"userId\":\"$user\""* && $trace == *"\"name\":\"answer · $2\""* && $spans -ge 2 ]]; then
    ok "Langfuse: traza ${1:0:8}… userId=$user · $generations generación(es) ($2) + $spans spans (Trino, pgvector)"
  else
    ko "Langfuse: traza '$1' incompleta (userId $user, $generations generaciones, $spans spans): ${trace:0:160}"
  fi
}
# The AI must name the originating account (RACCT) and its effect, as computed by Trino, and cite the filtered log.
# $1 engine, $2 language, $3 question, $4 RCNTR, $5 token of the origin (RACCT or STAGR), $6 effect label of that
# language, $7 "first" = both must be in the first line (format of the NIM prompt) | "any" = anywhere (local engine
# or a cause only the log gives); the first source must cover the asked cost center (Alcance of the bitácora)
rag_check() {
  local engine=$1 language=$2 question=$3 rcntr=$4 token=$5 label=$6 where=$7 response start tenths took verdict
  start=$(date +%s%N)
  response=$(curl -fsS --max-time 600 -X POST -H 'content-type: application/json' \
    -d "{\"question\":\"$question\",\"language\":\"$language\",\"engine\":\"$engine\",\"rcntr\":\"$rcntr\"}" \
    "http://127.0.0.1:${FRONTEND_PORT:-3000}/api/ask" 2>/dev/null)
  tenths=$(( ($(date +%s%N) - start) / 100000000 ))
  took="$((tenths / 10)).$((tenths % 10)) s"
  [[ $engine == nim && $tenths -gt 150 ]] && took+=" (sobre el objetivo de 15 s)"
  verdict=$(TOKEN="$token" LABEL="$label" WHERE="$where" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
answer = data["answer"].replace("*", "")
first = next((line for line in answer.splitlines() if line.strip()), "")
scope = first if os.environ["WHERE"] == "first" else answer
origin = data["analysis"]["origins"][0] if data["analysis"]["origins"] else None
cited = os.environ["TOKEN"] in scope and os.environ["LABEL"] in scope
print("|".join([data["model_used"], data["language_check"]["detected"] or "-", data["period"],
    "%s:%s" % (origin["racct"], origin["effect"]) if origin else "-",
    data["sources"][0]["doc_id"] if data["sources"] else "-",
    json.dumps(data["sources"][0]["metadata"], ensure_ascii=False, sort_keys=True) if data["sources"] else "-",
    str(bool(data["sources"]) and data["rcntr"] in data["sources"][0]["metadata"].get("Alcance", [])),
    "%d/%d" % (data["figures_check"]["grounded"], data["figures_check"]["checked"]),
    ",".join(data["figures_check"]["ungrounded"]), data["trace_id"] or "-", str(cited), first.strip()[:110]]))' \
    <<<"$response" 2>/dev/null)
  IFS='|' read -r model detected period origin doc meta covered figures ungrounded trace cited first <<<"$verdict"
  if [[ $model == "$engine/"* && $detected == "${language,,}" && $period == "$PERIOD" && $cited == True &&
        $doc == "${LOG[$rcntr]}" && $covered == True && $meta == *'"Año": 2026'*'"Mes": 10'* ]]; then
    ok "IA $language · $model en $took → $rcntr: «${first}» (Trino: ${origin}) · bitácora $doc $meta ·" \
       "respuesta en '$detected' · cifras ancladas a Trino $figures${ungrounded:+ (no ancladas: $ungrounded)}"
    trace_check "$trace" "$model"
  else
    ko "IA $language/$engine $rcntr → modelo='${model:-ninguno}' idioma='$detected' período='$period' origen='$origin'" \
       "cita '$token' + '$label'=$cited bitácora='$doc' $meta primera línea «$first» ${response:0:160}"
  fi
}
# Reference P x Q decomposition of the current month in PostgreSQL (same flexible budget as the Trino gold view):
# rcntr|racct|ruom|actual|budget|price|efficiency|volume|spending|sc_actual|sc_budget|price_actual|price_budget
PXQ_PG="
WITH a AS (SELECT rcntr, racct, max(runit) AS ruom, sum(ksl) AS ksl, sum(msl) AS msl FROM sap.acdoca
            WHERE rcntr IS NOT NULL AND fiscyearper = '${PERIOD/-/0}' GROUP BY 1, 2),
     b AS (SELECT rcntr, racct, max(rvunit) AS ruom, sum(ksl) AS ksl, sum(vmsl) AS msl, sum(kfsl) AS fksl, sum(vmfsl) AS fmsl
             FROM sap.acdocp WHERE category = '$BUDGET' AND fiscyearper = '${PERIOD/-/0}' GROUP BY 1, 2),
     d AS (SELECT r.rcntr, r.msl AS da, p.msl AS db FROM sap.finsskf r
             JOIN sap.finsskf p ON p.rcntr = r.rcntr AND p.stagr = r.stagr AND p.date_from = r.date_from
                               AND p.category = '$BUDGET'
            WHERE r.rrcty = '0' AND r.date_from = '$PERIOD-01'),
     j AS (SELECT coalesce(a.rcntr, b.rcntr) AS rcntr, coalesce(a.racct, b.racct) AS racct, coalesce(a.ruom, b.ruom) AS ruom,
                  coalesce(a.ksl, 0) AS ak, coalesce(a.msl, 0) AS aq, coalesce(b.ksl, 0) AS bk, coalesce(b.msl, 0) AS bq,
                  coalesce(b.fksl, 0) AS fk, coalesce(b.fmsl, 0) AS fq
             FROM a FULL JOIN b ON b.rcntr = a.rcntr AND b.racct = a.racct),
     x AS (SELECT j.*, d.da, d.db, j.ruom IS NOT NULL AND j.bq > 0 AS physical,
                  coalesce(d.da / nullif(d.db, 0), 1) AS act, j.bk / nullif(j.bq, 0) AS pb
             FROM j LEFT JOIN d USING (rcntr)),
     y AS (SELECT x.*, x.fq + (x.bq - x.fq) * x.act AS flex_q,
                  CASE WHEN x.physical THEN x.pb * (x.fq + (x.bq - x.fq) * x.act) ELSE x.fk + (x.bk - x.fk) * x.act END AS flex_k
             FROM x)
SELECT concat_ws('|', rcntr, racct, coalesce(ruom, '-'), round(ak, 2), round(bk, 2),
       coalesce(round(CASE WHEN physical THEN ak - pb * aq END, 2)::text, '-'),
       coalesce(round(CASE WHEN physical THEN pb * (aq - flex_q) END, 2)::text, '-'), round(flex_k - bk, 2),
       coalesce(round(CASE WHEN NOT physical THEN ak - flex_k END, 2)::text, '-'),
       coalesce((CASE WHEN ruom IS NOT NULL THEN aq / nullif(da, 0) END)::text, '-'),
       coalesce((CASE WHEN ruom IS NOT NULL THEN bq / nullif(db, 0) END)::text, '-'),
       coalesce((CASE WHEN ruom IS NOT NULL THEN ak / nullif(aq, 0) END)::text, '-'),
       coalesce((CASE WHEN ruom IS NOT NULL THEN bk / nullif(bq, 0) END)::text, '-'))
  FROM y ORDER BY rcntr, racct"
PXQ_TRINO="
SELECT concat_ws('|', rcntr, racct, coalesce(ruom, '-'), format('%.2f', actual_ksl), format('%.2f', budget_ksl),
       if(price_effect IS NULL, '-', format('%.2f', price_effect)),
       if(efficiency_effect IS NULL, '-', format('%.2f', efficiency_effect)), format('%.2f', volume_effect),
       if(spending_effect IS NULL, '-', format('%.2f', spending_effect)),  -- format('%.2f', NULL) prints "nu"
       coalesce(CAST(actual_sc AS varchar), '-'), coalesce(CAST(budget_sc AS varchar), '-'),
       coalesce(CAST(actual_price AS varchar), '-'), coalesce(CAST(budget_price AS varchar), '-'))
  FROM lakehouse.gold.vw_opex_c1_pxq_variance WHERE period = '$PERIOD' ORDER BY rcntr, racct"

step "1 · Contenedores y salud"
for svc in s4hana-db kafka debezium minio unity-catalog trino delta-sink vector-db ollama egress-proxy langfuse-db \
           langfuse backend frontend; do
  health=$($DC ps --format '{{.Health}}' "$svc" 2>/dev/null)
  [[ $health == healthy ]] && ok "$svc healthy" || ko "$svc → ${health:-no está corriendo}"
done
for job in minio-init debezium-init trino-init; do
  code=$(docker inspect -f '{{.State.ExitCode}}' "rollingf-$job" 2>/dev/null)
  [[ $code == 0 ]] && ok "$job completado (exit 0)" || ko "$job exit=${code:-n/a}"
done

step "2 · Modelo financiero SAP (S/4HANA simulado: ACDOCA · ACDOCP · FINSSKF) con P x Q"
tables=$(s4 "SELECT string_agg(table_name, ',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema = 'sap'")
counts=$(s4 "SELECT string_agg(relname || '=' || n_live_tup, ' ' ORDER BY relname) FROM pg_stat_user_tables WHERE schemaname = 'sap'")
[[ $tables == acdoca,acdocp,finsskf ]] && ok "esquema sap = exactamente ACDOCA, ACDOCP y FINSSKF ($counts)" || ko "tablas SAP: '$tables'"
pk() { s4 "SELECT string_agg(a.attname, ',' ORDER BY array_position(i.indkey::int2[], a.attnum)) FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) WHERE i.indrelid = '$1'::regclass AND i.indisprimary"; }
pk_acdocp=$(pk sap.acdocp)
pk_finsskf=$(pk sap.finsskf)
invented=$(s4 "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'sap' AND column_name IN ('rvers', 'ruom')")
[[ $pk_acdocp == rclnt,reqtsn,datapakid,record && $pk_finsskf == rclnt,stagr,recid,date_from && $invented == 0 ]] \
  && ok "campos documentados: ACDOCP ($pk_acdocp; versión = CATEGORY) · FINSSKF ($pk_finsskf) · sin RVERS ni RUOM inventados" \
  || ko "claves ACDOCP='$pk_acdocp' FINSSKF='$pk_finsskf' columnas inventadas=$invented"
lengths=$(s4 "SELECT string_agg(DISTINCT character_maximum_length::text, ',') FROM information_schema.columns
                WHERE table_schema = 'sap' AND column_name IN ('rcntr', 'racct')")
longest=$(s4 "SELECT max(length(id)) FROM (SELECT rcntr AS id FROM sap.acdoca UNION ALL SELECT racct FROM sap.acdoca
                UNION ALL SELECT rcntr FROM sap.acdocp UNION ALL SELECT racct FROM sap.acdocp UNION ALL SELECT rcntr FROM sap.finsskf) x")
prefixed=$(s4 "SELECT count(*) FROM (SELECT rcntr, racct FROM sap.acdoca UNION ALL SELECT rcntr, racct FROM sap.acdocp
                UNION ALL SELECT rcntr, NULL FROM sap.finsskf) x WHERE rcntr LIKE 'RCNTR%' OR racct LIKE 'RACCT%'")
kb_length=$(kb "SELECT character_maximum_length FROM information_schema.columns WHERE table_schema = 'kb' AND column_name = 'rcntr'")
[[ $lengths == 10 && $longest -le 10 && $prefixed == 0 && $kb_length == 10 ]] \
  && ok "IDs SAP en CHAR 10: RCNTR y RACCT varchar(10) en ACDOCA, ACDOCP, FINSSKF y pgvector; máximo $longest caracteres, sin prefijos RCNTR_/RACCT_" \
  || ko "largos SAP: columnas '$lengths' (pgvector '$kb_length'), máximo '$longest', IDs con prefijo '$prefixed'"
pxq_fields=$(s4 "SELECT string_agg(table_name || '.' || column_name, ',' ORDER BY table_name, column_name) FROM information_schema.columns
                  WHERE table_schema = 'sap' AND table_name IN ('acdoca', 'acdocp')
                    AND column_name IN ('ksl', 'msl', 'runit', 'racct', 'vmsl', 'vmfsl', 'rvunit', 'kprice', 'kfsl')")
[[ $pxq_fields == acdoca.ksl,acdoca.msl,acdoca.racct,acdoca.runit,acdocp.kfsl,acdocp.kprice,acdocp.ksl,acdocp.racct,acdocp.rvunit,acdocp.vmfsl,acdocp.vmsl ]] \
  && ok "P x Q en campos SAP reales: ACDOCA KSL + MSL/RUNIT; ACDOCP KSL + VMSL/RVUNIT + KPRICE + parte fija KFSL/VMFSL" \
  || ko "campos P x Q: '$pxq_fields'"
[[ $(s4 "SELECT count(*) FROM (SELECT belnr FROM sap.acdoca GROUP BY belnr HAVING sum(wsl) <> 0 OR sum(hsl) <> 0 OR sum(ksl) <> 0) x") == 0 ]] \
  && ok "ACDOCA cuadrado por documento (Σ WSL = Σ HSL = Σ KSL = 0)" || ko "ACDOCA descuadrado"
[[ $(s4 "SELECT count(*) FROM (SELECT rkcur FROM sap.acdoca UNION ALL SELECT rkcur FROM sap.acdocp) x WHERE rkcur <> 'USD'") == 0 ]] \
  && ok "OPEX en moneda de grupo KSL (RKCUR = USD en ACDOCA y ACDOCP)" || ko "moneda de grupo distinta de USD"
plan=$(s4 "SELECT (SELECT string_agg(DISTINCT category, ',' ORDER BY category) FROM sap.acdocp) || '|' ||
                  (SELECT max(abs(ksl - round(kprice * vmsl, 2))) FROM sap.acdocp WHERE kprice IS NOT NULL) || '|' ||
                  (SELECT count(*) FROM sap.acdocp WHERE kfsl > ksl OR vmfsl > vmsl)")
[[ $plan == "$BUDGET,$CATEGORY|0.00|0" ]] \
  && ok "ACDOCP $BUDGET + $CATEGORY con KSL = KPRICE x VMSL exacto en todas las líneas físicas y parte fija ≤ total" \
  || ko "plan P x Q: '$plan'"
published=$(s4 "SELECT count(*) FROM pg_publication_tables WHERE pubname = 'nodara_s4_pub'")
[[ $published == 3 ]] && ok "publicación CDC nodara_s4_pub cubre las 3 tablas financieras" || ko "publicación CDC: $published tablas"

step "3 · Cadena de valor OPEX C1 (12 centros de costo, seed de producción) y anomalías aprobadas"
centers_s4=$(s4 "SELECT string_agg(DISTINCT rcntr, ' ' ORDER BY rcntr) FROM sap.acdoca WHERE rcntr IS NOT NULL")
[[ $centers_s4 == "$(printf '%s\n' "${CENTERS[@]}" | sort | xargs)" ]] \
  && ok "ACDOCA: exactamente los 12 centros de costo de la cadena (mina, concentradora, lixiviación, puerto)" \
  || ko "centros de costo en ACDOCA: '$centers_s4'"
shape=$(s4 "SELECT string_agg(rcntr || ':' || shape, ' ' ORDER BY rcntr) FROM (
              SELECT a.rcntr,
                     (SELECT count(DISTINCT fiscyearper) || '/' || min(fiscyearper) || '-' || max(fiscyearper) FROM sap.acdoca x WHERE x.rcntr = a.rcntr)
                     || '|' || (SELECT count(DISTINCT fiscyearper) FROM sap.acdocp p WHERE p.rcntr = a.rcntr AND p.category = '$BUDGET')
                     || '|' || (SELECT count(DISTINCT fiscyearper) || '/' || min(fiscyearper) || '-' || max(fiscyearper) FROM sap.acdocp p
                                 WHERE p.rcntr = a.rcntr AND p.category = '$CATEGORY')
                     || '|' || (SELECT count(DISTINCT stagr) || '/' || count(*) FROM sap.finsskf f WHERE f.rcntr = a.rcntr)
                     || '|' || (CASE WHEN (SELECT count(DISTINCT racct) FROM sap.acdoca x WHERE x.rcntr = a.rcntr) BETWEEN 4 AND 5
                                     THEN 'ok' ELSE 'cuentas' END) AS shape
                FROM (SELECT DISTINCT rcntr FROM sap.acdoca WHERE rcntr IS NOT NULL) a) s")
expected_shape=$(printf '%s:6/2026005-2026010|6|18/2026011-2028004|1/30|ok ' "${CENTERS[@]}" | xargs -n1 | sort | xargs)
[[ $shape == "$expected_shape" ]] \
  && ok "cada centro: 6 meses reales (ACDOCA) + 6 de $BUDGET + 18 de $CATEGORY (2026-11 → 2028-04), 4-5 cuentas RACCT y 1 impulsor FINSSKF (30 valores)" \
  || ko "forma del seed: '${shape:0:220}'"
units=$(s4 "SELECT (SELECT count(*) FROM (SELECT rcntr, racct, fiscyearper FROM sap.acdoca WHERE rcntr IS NOT NULL GROUP BY 1, 2, 3
                                           HAVING count(DISTINCT coalesce(runit, '-')) > 1) x) || '|' ||
                   (SELECT count(*) FROM (SELECT category, rcntr, racct, fiscyearper FROM sap.acdocp GROUP BY 1, 2, 3, 4
                                           HAVING count(DISTINCT coalesce(rvunit, '-')) > 1) y) || '|' ||
                   (SELECT count(DISTINCT runit) FROM sap.acdoca WHERE rcntr IS NOT NULL)")
[[ ${units%|*} == "0|0" ]] \
  && ok "una sola unidad por centro, cuenta y mes (${units##*|} unidades: KG, L, PC, HR, KWH, M3, TO): nunca se suman litros con piezas" \
  || ko "cuentas con más de una unidad (real|plan): '$units'"
weekly=$(s4 "SELECT count(*) || '|' || count(*) FILTER (WHERE docs = 4) FROM (
               SELECT rcntr, racct, fiscyearper, count(DISTINCT belnr) AS docs FROM sap.acdoca
                WHERE rcntr IS NOT NULL AND blart = 'WA' AND usnam <> 'SIMULATOR' GROUP BY 1, 2, 3) x")
[[ ${weekly%|*} -gt 0 && ${weekly%|*} == "${weekly#*|}" ]] \
  && ok "consumos de bodega (WA) contabilizados semanalmente: 4 documentos por insumo y mes (${weekly%|*} grupos)" \
  || ko "salidas de bodega semanales: '$weekly'"
legacy=$(( $(s4 "SELECT count(*) FROM sap.acdoca WHERE rcntr LIKE 'RCNTR_MINA_%' OR rcntr IN ('RCNTR_LIXIV_SXEW', 'RCNTR_CONCEN_FLOT', 'RCNTR_PUERTO_EMB')") + \
           $(s4 "SELECT count(*) FROM sap.acdoca WHERE rbukrs <> 'CL01'") + \
           $(kb "SELECT count(*) FROM kb.documents WHERE doc_id LIKE 'BIT-MANT-%' OR doc_id LIKE 'BIT-OPER-%' OR doc_id LIKE 'AU-%'") ))
[[ $legacy -eq 0 ]] && ok "cero rastros del PoC (centros RCNTR_MINA_*/LIXIV/CONCEN/PUERTO, bitácoras y manuales anteriores)" || ko "$legacy rastros del PoC"
s4 "$PXQ_PG" | python3 -c '
import sys
rows = [line.split("|") for line in sys.stdin.read().split() if line]
num = lambda v: None if v == "-" else float(v)
lines = {}
for r in rows:
    lines.setdefault(r[0], {})[r[1]] = {"actual": num(r[3]), "budget": num(r[4]), "price": num(r[5]), "efficiency": num(r[6]),
                                       "volume": num(r[7]), "spending": num(r[8]), "sc_a": num(r[9]), "sc_b": num(r[10])}
def origin(rcntr):
    effects = [(v, racct, e) for racct, line in lines[rcntr].items() for e in ("price", "efficiency", "volume", "spending")
               if (v := line[e]) is not None and v > 0]
    return max(effects) if effects else None
def case(rcntr, ok, message):
    print(("OK" if ok else "KO") + "|caso " + rcntr + ": " + message)
o = origin("MIN_PERF"); steel, diesel = lines["MIN_PERF"]["ACEROS"], lines["MIN_PERF"]["DIESEL"]
case("MIN_PERF", o and o[1:] == ("ACEROS", "efficiency") and round(o[0]) == 363009 and steel["price"] == 0
     and abs(diesel["sc_a"] / diesel["sc_b"] - 1) < 0.01,
     "origen ACEROS · eficiencia (Q) +%s USD (precio 0; consumo %.7f vs %.7f PC/m); diésel en línea (%.3f vs %.3f L/m)"
     % (round(o[0]) if o else "-", steel["sc_a"], steel["sc_b"], diesel["sc_a"], diesel["sc_b"]))
o = origin("CON_FLOT"); xan = lines["CON_FLOT"]["REACTIVOS"]
case("CON_FLOT", o and o[1:] == ("REACTIVOS", "price") and round(o[0]) == 58108 and abs(xan["efficiency"]) < 0.1 * xan["price"],
     "origen REACTIVOS · precio (P) +%s USD (eficiencia %s USD: dosificación en estándar)" % (round(o[0]) if o else "-", round(xan["efficiency"])))
o = origin("CON_MOLI"); labor = lines["CON_MOLI"]["LABOR"]
case("CON_MOLI", o and o[1:] == ("LABOR", "efficiency") and round(o[0]) == 85722 and labor["price"] > 0,
     "origen LABOR · eficiencia (Q) +%s USD por horas extra, más precio (P) +%s USD por recargo" % (round(o[0]) if o else "-", round(labor["price"])))
port = lines["PTO_EMBA"]
case("PTO_EMBA", origin("PTO_EMBA") is None and port["LABOR"]["actual"] == port["LABOR"]["budget"]
     and port["MANTEN"]["actual"] == port["MANTEN"]["budget"] and port["LABOR"]["sc_a"] is None,
     "impulsor en 0: LABOR y MANTEN fijos (real = presupuesto), consumo específico no calculable, sin efecto desfavorable")
' | report

step "4 · CDC (Debezium → Kafka)"
status=$(curl -fsS "http://127.0.0.1:${DEBEZIUM_PORT:-8083}/connectors/s4hana-cdc/status" 2>/dev/null)
[[ $(grep -o '"state":"RUNNING"' <<<"$status" | wc -l) -ge 2 ]] && ok "conector s4hana-cdc RUNNING (connector + task)" || ko "conector s4hana-cdc: ${status:-sin respuesta}"
topics=$($DC exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list </dev/null 2>/dev/null | grep '^s4hana\.sap\.' | tr '\n' ' ')
[[ $topics == "s4hana.sap.acdoca s4hana.sap.acdocp s4hana.sap.finsskf " ]] && ok "tópicos CDC: $topics" || ko "tópicos CDC: '$topics'"

step "5 · Lakehouse (Trino: S/4 en vivo + Delta bronze + silver + gold P x Q; Unity Catalog)"
for table in acdoca acdocp finsskf; do
  IFS=$'\t' read -r source live bronze silver < <(sql "SELECT $(s4 "SELECT count(*) FROM sap.$table"),
      (SELECT count(*) FROM s4hana.sap.$table), (SELECT count(*) FROM lakehouse.bronze.$table), (SELECT count(*) FROM lakehouse.silver.$table)")
  [[ $live == "$source" && ${bronze:-0} -ge $source && $silver == "$source" ]] \
    && ok "Trino ve $table: origen $source = s4hana.sap $live = silver $silver (bronze: $bronze eventos CDC)" \
    || ko "$table: origen '$source' vivo '$live' bronze '$bronze' silver '$silver'"
done
uc=$(curl -fsS "http://127.0.0.1:${UNITY_CATALOG_PORT:-8081}/api/2.1/unity-catalog/tables?catalog_name=nodara&schema_name=bronze" 2>/dev/null |
     grep -o '"name":"[a-z0-9_]*","catalog_name"' | cut -d'"' -f4 | sort | tr '\n' ' ')
[[ $uc == "acdoca acdocp finsskf " ]] && ok "Unity Catalog nodara.bronze (EXTERNAL DELTA): $uc" || ko "Unity Catalog bronze: '$uc'"
gold=$(sql "SELECT table_name FROM lakehouse.information_schema.views WHERE table_schema = 'gold' ORDER BY 1" | xargs)
backend_start=$(docker inspect -f '{{.State.StartedAt}}' rollingf-backend 2>/dev/null)
gold_done=$(docker inspect -f '{{.State.FinishedAt}}' rollingf-trino-init 2>/dev/null)
[[ $gold == "vw_opex_c1_pxq vw_opex_c1_pxq_variance" && -n $gold_done && $gold_done < $backend_start ]] \
  && ok "capa gold lakehouse.gold.{$gold} publicada por trino-init (lakehouse/trino/gold) antes de que arranque el backend" \
  || ko "vistas gold: '$gold' (trino-init terminó $gold_done, backend arrancó $backend_start)"
if grep -rqiE "CREATE( OR REPLACE)? (VIEW|SCHEMA|TABLE)" backend/app; then
  ko "el backend contiene DDL de Trino: $(grep -rliE 'CREATE( OR REPLACE)? (VIEW|SCHEMA|TABLE)' backend/app | xargs)"
else
  ok "el backend no ejecuta DDL: solo lee las vistas gold (sin CREATE VIEW en backend/app)"
fi
IFS=$'\t' read -r rows groups mixed < <(sql "SELECT count(*), count(DISTINCT (version, period, rcntr, racct)),
    (SELECT count(*) FROM (SELECT version, period, rcntr, racct FROM lakehouse.gold.vw_opex_c1_pxq GROUP BY 1, 2, 3, 4
                            HAVING count(DISTINCT coalesce(ruom, '-')) > 1) x)
  FROM lakehouse.gold.vw_opex_c1_pxq")
[[ -n $rows && $rows == "$groups" && $mixed == 0 ]] \
  && ok "vw_opex_c1_pxq agrupa por versión, mes, RCNTR y RACCT: $rows filas = $groups grupos, 0 grupos con unidades mezcladas" \
  || ko "vw_opex_c1_pxq: $rows filas, $groups grupos, $mixed grupos con unidades mezcladas"
totals_trino=$(sql "SELECT version || '=' || format('%.2f', sum(ksl)) FROM lakehouse.gold.vw_opex_c1_pxq GROUP BY version ORDER BY version" | xargs)
totals_pg=$(s4 "SELECT string_agg(v || '=' || k, ' ' ORDER BY v) FROM (
                  SELECT 'ACTUAL' AS v, sum(ksl)::numeric(20,2)::text AS k FROM sap.acdoca WHERE rcntr IS NOT NULL
                  UNION ALL SELECT category, sum(ksl)::numeric(20,2)::text FROM sap.acdocp GROUP BY category) x")
[[ $totals_trino == "$totals_pg" ]] && ok "gold = S/4 por versión (KSL): $totals_trino" || ko "totales gold '$totals_trino' vs S/4 '$totals_pg'"
IFS=$'\t' read -r zero zero_sc lines_var < <(sql "SELECT count(*) FILTER (WHERE driver_qty = 0),
    count(*) FILTER (WHERE driver_qty = 0 AND (specific_consumption IS NOT NULL OR cost_per_driver_unit IS NOT NULL)),
    (SELECT count(*) + count(efficiency_effect) * 0 + count(actual_sc) * 0 FROM lakehouse.gold.vw_opex_c1_pxq_variance)
  FROM lakehouse.gold.vw_opex_c1_pxq")
[[ ${zero:-0} -gt 0 && $zero_sc == 0 && ${lines_var:-0} -gt 0 ]] \
  && ok "sin división por cero: $zero líneas con impulsor FINSSKF = 0 (puerto 2026-10) dan consumo específico y costo unitario NULL; las $lines_var líneas de la varianza se calculan sin error" \
  || ko "división por cero: impulsor 0 en '$zero' líneas, '$zero_sc' con ratio calculado, varianza '$lines_var'"

step "6 · P x Q determinista (Trino gold = PostgreSQL, sin IA)"
pg_lines=$(s4 "$PXQ_PG")
trino_lines=$(sql "$PXQ_TRINO")
PG_LINES="$pg_lines" TRINO_LINES="$trino_lines" PERIOD="$PERIOD" python3 -c '
import os
def parse(text):
    return {tuple(f[:2]): f for f in (line.split("|") for line in text.split() if line)}
pg, tr = parse(os.environ["PG_LINES"]), parse(os.environ["TRINO_LINES"])
bad = []
for key in sorted(set(pg) | set(tr)):
    a, b = pg.get(key), tr.get(key)
    if not a or not b:
        bad.append("/".join(key)); continue
    if a[2] != b[2]:
        bad.append("/".join(key) + ":unidad")
    for i, (x, y) in enumerate(zip(a[3:], b[3:]), 3):
        if x == "-" or y == "-":
            if x != y: bad.append("/".join(key) + ":%d" % i)
        elif i <= 8 and abs(float(x) - float(y)) > 0.02:
            bad.append("/".join(key) + ":%d" % i)
        elif i > 8 and abs(float(x) - float(y)) > 1e-9 * max(1, abs(float(x))):
            bad.append("/".join(key) + ":%d" % i)
centers = len({k[0] for k in pg})
if pg and not bad:
    print("OK|%d líneas RCNTR x RACCT de %d centros en %s: costo, efectos precio / eficiencia / volumen / gasto, consumo específico y precio unitario idénticos en Trino y PostgreSQL" % (len(pg), centers, os.environ.get("PERIOD", "")))
else:
    print("KO|P x Q Trino vs PostgreSQL: %d líneas PG, %d Trino, diferencias: %s" % (len(pg), len(tr), ", ".join(bad[:8])))
' | report
series_ok=()
for rc in "${CENTERS[@]}"; do
  pg_series=$(s4 "WITH cutoff AS (SELECT max(fiscyearper) AS p FROM sap.acdoca WHERE rcntr = '$rc'),
                       o AS (SELECT fiscyearper AS p, sum(ksl) AS opex FROM sap.acdoca WHERE rcntr = '$rc' GROUP BY 1
                             UNION ALL
                             SELECT a.fiscyearper, sum(a.ksl) FROM sap.acdocp a, cutoff c
                              WHERE a.rcntr = '$rc' AND a.category = '$CATEGORY' AND a.fiscyearper > c.p GROUP BY 1),
                       q AS (SELECT to_char(date_from, 'YYYY\"0\"MM') AS p, sum(msl) AS qty FROM sap.finsskf
                              WHERE rcntr = '$rc' AND (rrcty = '0' OR category = '$CATEGORY') GROUP BY 1)
                  SELECT string_agg(o.p || '=' || coalesce(round(o.opex / nullif(q.qty, 0), 6)::text, 'n/d'), ' ' ORDER BY o.p)
                    FROM o JOIN q USING (p)")
  trino_series=$(api "opex/timeline?rcntr=$rc" | json "' '.join(m['period'].replace('-', '0') + '=' +
                   ('n/d' if m['unit_cost'] is None else format(m['unit_cost'], '.6f')) for m in data['periods'])")
  [[ -n $pg_series && $pg_series == "$trino_series" ]] || { ko "$rc OPEX unitario Trino='${trino_series:0:90}' PostgreSQL='${pg_series:0:90}'"; continue; }
  series_ok+=("$rc")
done
[[ ${#series_ok[@]} -eq ${#CENTERS[@]} ]] \
  && ok "OPEX unitario de 24 meses (6 reales + 18 $CATEGORY) idéntico en Trino y PostgreSQL para los ${#series_ok[@]} centros (puerto 2026-10: n/d, impulsor 0)"
summary=$(api "opex/timeline?rcntr=MIN_PERF" | json "(lambda s: '|'.join(map(str, [s['period'], round(s['unit_cost']['actual'], 2),
                 round(s['unit_cost']['budget'], 2), s['unit_cost']['delta_pct'], s['opex']['variance_pct'], s['driver']['delta_pct'],
                 s['origins'][0]['racct'], s['origins'][0]['effect'], round(s['origins'][0]['amount'])])))(data['summary'])")
[[ $summary == "$PERIOD|18.37|15.64|17.4|14.7|-2.4|ACEROS|efficiency|363009" ]] \
  && ok "MIN_PERF $PERIOD (Trino): OPEX +14,7 % vs $BUDGET, metros -2,4 %, 18,37 vs 15,64 USD/m (+17,4 %); origen ACEROS · eficiencia (Q) +USD 363.009" \
  || ko "resumen MIN_PERF: '$summary'"
first_call=$(mktemp) second_call=$(mktemp)
cold=$(curl -fsS -o "$first_call" -w '%{time_total}' "http://127.0.0.1:${FRONTEND_PORT:-3000}/api/opex/matrix" 2>/dev/null)
warm=$(curl -fsS -o "$second_call" -w '%{time_total}' "http://127.0.0.1:${FRONTEND_PORT:-3000}/api/opex/matrix" 2>/dev/null)
cache=$(api status | json "'%(entries)s|%(hits)s|%(misses)s|%(data_version)s' % data['lakehouse_cache']")
IFS='|' read -r entries hits misses version <<<"$cache"
if cmp -s "$first_call" "$second_call" && [[ ${hits:-0} -gt 0 ]] && awk -v w="$warm" 'BEGIN { exit !(w < 0.5) }'; then
  ok "caché en memoria del backend (versión Delta de bronze $version): matriz C1 en ${warm}s desde caché (antes ${cold}s), mismo resultado; $entries consultas en caché, $hits aciertos / $misses cálculos"
else
  ko "caché del backend: matriz ${cold}s → ${warm}s, entradas '$entries' aciertos '$hits' fallos '$misses'"
fi
rm -f "$first_call" "$second_call"

step "7 · Raw layer (MinIO raw-docs + Unity Catalog) y linaje"
local_files=$(find knowledge/raw-docs -type f | wc -l)
remote_keys=$(s3 "raw-docs?list-type=2" 2>/dev/null | grep -o '<Key>[^<]*</Key>' | wc -l)
[[ $local_files -gt 0 && $remote_keys -eq $local_files ]] \
  && ok "bucket raw-docs con $remote_keys original(es) (= archivos en knowledge/raw-docs)" || ko "raw-docs: $remote_keys objetos vs $local_files archivos locales"
[[ $(s3 "raw-docs?versioning" 2>/dev/null) == *"<Status>Enabled</Status>"* ]] \
  && ok "versionado habilitado (historial inmutable de originales)" || ko "versionado deshabilitado en raw-docs"
mismatch=0
while IFS= read -r file; do
  [[ $(s3 "raw-docs/${file#knowledge/raw-docs/}" 2>/dev/null | sha) == $(sha < "$file") ]] || mismatch=$((mismatch + 1))
done < <(find knowledge/raw-docs -type f)
[[ $mismatch -eq 0 ]] && ok "integridad SHA-256: objetos en MinIO idénticos al repositorio" || ko "$mismatch objetos difieren del repositorio"
tagged=0
while IFS= read -r file; do
  rcntr=$(sed -n 's/^rcntr: //p' "$file" | tr 'A-Z' 'a-z')
  headers=$(s3head "raw-docs/${file#knowledge/raw-docs/}" 2>/dev/null | tr -d '\r' | tr 'A-Z' 'a-z')
  [[ $headers == *"x-amz-meta-rcntr: $rcntr"* && $headers == *"x-amz-meta-gjahr: 2026"* && $headers == *"x-amz-meta-monat: 10"* ]] \
    && tagged=$((tagged + 1))
done < <(find knowledge/raw-docs -type f)
[[ $tagged -eq $local_files ]] && ok "metadatos SAP en los $tagged objetos raw (Rcntr, Gjahr, Monat del front matter)" \
  || ko "objetos raw con metadatos SAP: $tagged de $local_files"
volumes=$(curl -fsS "http://127.0.0.1:${UNITY_CATALOG_PORT:-8081}/api/2.1/unity-catalog/volumes?catalog_name=nodara&schema_name=raw" 2>/dev/null)
missing=""
for source in $(find knowledge/raw-docs -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort); do
  [[ $volumes == *"\"full_name\":\"nodara.raw.docs_$source\""* ]] || missing+=" $source"
done
[[ -z $missing ]] && ok "Unity Catalog: un volumen EXTERNAL por origen (nodara.raw.docs_$(find knowledge/raw-docs -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | paste -sd '|'))" \
  || ko "volúmenes raw sin registrar:$missing"
orphans=0 ungrounded=0
while IFS='|' read -r doc uri; do
  raw=$(s3 "${uri#s3://}" 2>/dev/null) || { orphans=$((orphans + 1)); continue; }
  while IFS= read -r content; do
    [[ $raw == *"$content"* ]] || ungrounded=$((ungrounded + 1))
  done < <(kb "SELECT content FROM kb.chunks WHERE doc_id = '$doc'")
done < <(kb "SELECT doc_id, source_uri FROM kb.documents")
[[ $orphans -eq 0 && $ungrounded -eq 0 ]] \
  && ok "linaje índice ⊆ raw: $(kb 'SELECT count(*) FROM kb.chunks') fragmento(s) de pgvector presentes literalmente en su original (source_uri)" \
  || ko "linaje roto: $orphans source_uri sin objeto, $ungrounded fragmentos sin respaldo en raw"

step "8 · Base de conocimiento (pgvector aislado, metadatos Año / Mes / RCNTR obligatorios)"
chunks=$(kb "SELECT count(*) FROM kb.chunks")
coords=$(kb "SELECT count(DISTINCT (gjahr, monat, rcntr)) FROM kb.chunks")
[[ ${chunks:-0} -gt 0 && $coords == "${#ANOMALIES[@]}" ]] \
  && ok "pgvector $(kb "SELECT extversion FROM pg_extension WHERE extname = 'vector'"): $(kb 'SELECT count(*) FROM kb.documents') bitácoras de justificación, $chunks fragmentos, $(kb 'SELECT count(embedding) FROM kb.chunks') indexados · $coords coordenadas Año/Mes/RCNTR" \
  || ko "kb.chunks: $chunks fragmentos, $coords coordenadas Año/Mes/RCNTR"
routed=""
for rc in "${!LOG[@]}"; do
  [[ $(kb "SELECT string_agg(DISTINCT doc_id, ',') FROM kb.chunks WHERE rcntr_scope @> ARRAY['$rc']::varchar[] AND gjahr = 2026 AND monat = 10") == "${LOG[$rc]}" ]] \
    || routed+=" $rc"
done
[[ -z $routed && -z $(kb "SELECT doc_id FROM kb.chunks WHERE rcntr_scope @> ARRAY['MIN_TRAN']::varchar[] LIMIT 1") ]] \
  && ok "filtro Año 2026 · Mes 10 · RCNTR (alcance) → la bitácora de cada anomalía; la del molino SAG cubre también CON_RELA y PTO_FILT (efecto dominó); un centro sin anomalía no recibe textos" \
  || ko "filtro por metadatos sin su bitácora:$routed"
if $DC exec -T vector-db psql -U "$VECTOR_DB_USER" -d knowledge -v ON_ERROR_STOP=1 -c \
     "BEGIN; INSERT INTO kb.chunks (doc_id, chunk_no, section, content) VALUES ('BIT-PERF-2026-10', 99, 'x', 'x'); ROLLBACK;" \
     </dev/null >/dev/null 2>&1; then
  ko "pgvector aceptó un vector sin Año/Mes/RCNTR"
else
  ok "pgvector rechaza un vector sin Año/Mes/RCNTR (NOT NULL + CHECK)"
fi
scope=$(kb "SELECT array_to_string(rcntr_scope, ',') FROM kb.chunks WHERE doc_id = 'BIT-MOLI-2026-10' LIMIT 1")
if $DC exec -T vector-db psql -U "$VECTOR_DB_USER" -d knowledge -v ON_ERROR_STOP=1 -c \
     "BEGIN; INSERT INTO kb.chunks (doc_id, chunk_no, section, content, gjahr, monat, rcntr, rcntr_scope)
      VALUES ('BIT-PERF-2026-10', 99, 'x', 'x', 2026, 10, 'MIN_PERF', ARRAY['CON_FLOT']); ROLLBACK;" </dev/null >/dev/null 2>&1; then
  ko "pgvector aceptó un alcance que no incluye el RCNTR de la bitácora"
elif [[ $scope == CON_MOLI,CON_RELA,PTO_FILT ]]; then
  ok "alcance RCNTR de BIT-MOLI-2026-10 = $scope (CHECK: el alcance siempre incluye el RCNTR que registra la bitácora)"
else
  ko "alcance de BIT-MOLI-2026-10: '$scope'"
fi
[[ $(kb "SELECT count(*) FROM kb.chunks WHERE rcntr = 'MIN_PERF' AND gjahr = 2026 AND monat = 9") == 0 ]] \
  && ok "filtro por metadatos: ninguna bitácora de MIN_PERF en 2026-09 (la IA no recibe textos de otro mes)" || ko "filtro por metadatos inconsistente"
docker network inspect rollingf-kb -f '{{range .Containers}}{{.Name}} {{end}}' | grep -qv 'trino\|kafka\|debezium' \
  && ok "segmento rollingf-kb exclusivo: $(docker network inspect rollingf-kb -f '{{range .Containers}}{{.Name}} {{end}}')" || ko "rollingf-kb compartido con servicios ajenos"

step "9 · Gerente de Finanzas → frontend → backend → IA (cuenta y efecto de origen, motor NIM / Ollama, Langfuse)"
home=$(curl -fsS "http://127.0.0.1:${FRONTEND_PORT:-3000}/" 2>/dev/null)
[[ -n $home ]] && ok "frontend HTTP 200 en 127.0.0.1:${FRONTEND_PORT:-3000}" || ko "frontend sin respuesta"
[[ $home == *'aria-label="Español"'* && $home == *'aria-label="English"'* && $home == *'aria-label="Português"'* &&
   $home == *'NVIDIA NIM (Cloud)'* && $home == *'Ollama (Local)'* && $home == *'data-testid="cost-center-select"'* &&
   $home == *'data-testid="matrix"'* ]] \
  && ok "selectores de idioma (ES/EN/PT), motor (NIM / Ollama), centro de costo y matriz P x Q desplegados (comportamiento: make ui-test)" \
  || ko "falta un selector o la matriz P x Q en el frontend"
centers=$(api "opex/cost-centers" | json "' '.join(c['rcntr'] + ':' + c['area'] for c in data['cost_centers'])")
[[ $centers == "MIN_PERF:MINA MIN_TRON:MINA MIN_CARG:MINA MIN_TRAN:MINA CON_MOLI:CONCENTRADORA CON_FLOT:CONCENTRADORA CON_RELA:CONCENTRADORA LIX_RIEG:LIXIVIACION LIX_SX:LIXIVIACION LIX_EW:LIXIVIACION PTO_FILT:PUERTO PTO_EMBA:PUERTO" ]] \
  && ok "selector desde el lakehouse: 12 centros en orden de la cadena de valor y agrupados por área" || ko "centros de costo: '$centers'"
matrix=$(api "opex/matrix" | json "' '.join('%s=%s' % (c['rcntr'], (c['origin'] or {}).get('racct', '-') + ':' + (c['origin'] or {}).get('effect', '-'))
                                        for a in data['areas'] for c in a['cost_centers'] if c['rcntr'] in ('MIN_PERF', 'CON_FLOT', 'CON_MOLI', 'PTO_EMBA'))")
[[ $matrix == "MIN_PERF=ACEROS:efficiency CON_MOLI=LABOR:efficiency CON_FLOT=REACTIVOS:price PTO_EMBA=-:-" ]] \
  && ok "API /opex/matrix: origen de cada anomalía calculado por Trino ($matrix)" || ko "matriz: '$matrix'"
status_json=$(api status 2>/dev/null)
[[ $status_json == *'"s4hana_live":{"ok":true'* ]] && ok "backend vía proxy /api/status (S/4 en vivo OK)" || ko "backend /api/status: ${status_json:0:200}"
[[ $status_json == *'"observability":{"ok":true'* ]] && ok "Langfuse v2 autenticado con las API keys de .env" || ko "Langfuse sin autenticar"
nim=0 ollama=0
[[ $status_json == *'"chat_ready":true'* ]] && ollama=1
if [[ $status_json == *'"configured":true'* ]]; then
  [[ $status_json == *'"reachable":true'*'"listed":true'* ]] \
    && { nim=1; ok "NVIDIA NIM alcanzable vía egress-proxy: modelo ${NIM_MODEL:-openai/gpt-oss-20b} habilitado para la cuenta"; } \
    || ko "NVIDIA NIM configurado pero inalcanzable o modelo no habilitado: $(grep -o '"nim":{[^}]*}' <<<"$status_json")"
else
  skip "NVIDIA NIM sin configurar (NVIDIA_API_KEY vacío): las preguntas corren sobre Ollama local"
fi
if [[ ${SMOKE_RAG:-1} == 0 ]]; then
  skip "IA E2E omitida (SMOKE_RAG=0)"
elif [[ $status_json == *'"embed_ready":true'* ]] && (( nim || ollama )); then
  engine=$( (( nim )) && echo nim || echo ollama )
  ask_es="¿Qué cuenta (RACCT) originó la desviación del mes y fue efecto precio o eficiencia?"
  rag_check $engine ES "$ask_es" MIN_PERF ACEROS "Eficiencia (Q)" first
  rag_check $engine ES "$ask_es" CON_FLOT REACTIVOS "Precio (P)" first
  rag_check $engine EN "Which account (RACCT) caused the deviation of the month, and was it a price or an efficiency effect?" \
    CON_MOLI LABOR "Efficiency (Q)" first
  rag_check $engine PT "Qual conta (RACCT) originou o desvio do mês e foi efeito preço ou eficiência?" \
    PTO_EMBA TONEMB "Volume" first
  # Domino effect: tailings get the SAG mill log (its RCNTR scope) and the AI explains the lower throughput.
  rag_check $engine ES "¿Por qué bajó el tratamiento de Relaves este mes y cómo afectó su OPEX unitario?" \
    CON_RELA SAG "molino" any
  if (( nim && ollama )); then  # local contingency engine (no data leaves the enclave)
    rag_check ollama ES "$ask_es" MIN_PERF ACEROS "Eficiencia" any
  fi
else
  skip "IA E2E omitida: modelos aún no importados (make models && make embed)"
fi

step "10 · Tiempo real E2E: S/4 → Debezium → Kafka → Delta (bronze → silver → gold) → Trino → API"
before=$(api "opex/timeline?rcntr=MIN_TRAN" | json "data['summary']['opex']['actual']")
belnr=$(s4 "SELECT belnr FROM sap.simulate_activity(1) LIMIT 1")
if [[ -z $belnr ]]; then
  ko "simulador S/4 no contabilizó documento"
else
  start=$(date +%s)
  found=0
  for _ in $(seq 1 45); do
    found=$(sql "SELECT count(*) FROM lakehouse.silver.acdoca WHERE belnr = '$belnr'")
    [[ ${found:-0} -ge 2 ]] && break
    sleep 2
  done
  after=$(api "opex/timeline?rcntr=MIN_TRAN" | json "data['summary']['opex']['actual']")
  if [[ ${found:-0} -ge 2 && -n $after && $after != "$before" ]]; then
    lag=$(sql "SELECT max(date_diff('millisecond', _source_ts, _ingested_at)) FROM lakehouse.bronze.acdoca WHERE belnr = '$belnr'")
    ok "documento $belnr (despacho de diésel CAEX, L x USD/L) en silver en $(( $(date +%s) - start ))s (latencia CDC ${lag} ms); OPEX de MIN_TRAN vía gold: $before → $after"
  else
    ko "documento $belnr: $found líneas en silver; OPEX del mes '$before' → '$after'"
  fi
fi

step "11 · Air-gap y salida controlada (egress-proxy)"
[[ $(docker network inspect rollingf-net -f '{{.Internal}}') == true ]] && ok "red rollingf-net internal=true" || ko "rollingf-net no es internal"
for svc in ollama backend delta-sink kafka; do
  egress_blocked "$svc" && ok "$svc sin salida directa a Internet" || ko "$svc TIENE salida directa a Internet"
done
egress_net=$(docker network inspect rollingf-egress -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null)
[[ $egress_net == "rollingf-egress-proxy " ]] && ok "red rollingf-egress exclusiva del gateway" || ko "rollingf-egress compartida: '$egress_net'"
result=$(egress_probe https://integrate.api.nvidia.com/v1/models)
[[ $result =~ ^[0-9]+$ ]] && ok "allowlist: backend → gateway → integrate.api.nvidia.com (HTTP $result)" || ko "allowlist: NVIDIA → ${result:-sin respuesta}"
for url in https://api.fxratesapi.com/latest https://pypi.org/simple/ https://example.com/ http://example.com/; do
  result=$(egress_probe "$url")
  [[ $result == denegado* || $result == "sin ruta"* ]] && ok "fuera de la allowlist: ${url} → $result" || ko "${url} accesible desde el backend (${result:-?})"
done

printf '\n\033[1mResultado: %d OK, %d fallos\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
