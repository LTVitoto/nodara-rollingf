#!/usr/bin/env bash
# E2E QA of the Nodara Rolling Forecast stack. Exit code 0 only if every check passes.
#   make smoke    → re-seeds silently first (make fresh), then: infrastructure, the financial data model
#                   (ACDOCA / ACDOCP / FINSSKF with their documented SAP fields, plan categories BUDG + RF18M),
#                   the 5 approved cases of the C1 value chain, CDC → Delta bronze → silver, deterministic unit
#                   OPEX and deviation vs budget (Trino = PostgreSQL), raw layer + lineage, pgvector metadata
#                   (Año / Mes / RCNTR), the AI on the NIM engine in ES / EN / PT (CAEX) and on the port unit
#                   OPEX, the local Ollama contingency, Langfuse traces, real-time CDC, egress gateway, air-gap
#   ./scripts/smoke-test.sh alone runs on the current data (diagnostics only: the simulator posts to ACDOCA).
#   SMOKE_RAG=0 make smoke skips the LLM calls; they also skip until `make models` was run.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then set -a; source .env; set +a; fi

DC="docker compose"
RCNTR=RCNTR_MINA_CAEX
PORT=RCNTR_PUERTO_EMB
CATEGORY=RF18M
BUDGET=BUDG
# Value chain of the C1 OPEX: cost center → driver of its unit OPEX (FINSSKF STAGR) and its bitácora of 2026-10.
CENTERS=(RCNTR_MINA_CAEX RCNTR_MINA_TRUCK RCNTR_LIXIV_SXEW RCNTR_CONCEN_FLOT RCNTR_PUERTO_EMB)
declare -A DRIVER=([RCNTR_MINA_CAEX]=HOROP [RCNTR_MINA_TRUCK]=TONMOV [RCNTR_LIXIV_SXEW]=TONAPI
                   [RCNTR_CONCEN_FLOT]=TONPRO [RCNTR_PUERTO_EMB]=TONEMB)
declare -A LOG=([RCNTR_MINA_CAEX]=BIT-MANT-CAEX-2026-10 [RCNTR_MINA_TRUCK]=BIT-OPER-MINA-2026-10
                [RCNTR_LIXIV_SXEW]=BIT-MANT-SXEW-2026-10 [RCNTR_CONCEN_FLOT]=BIT-OPER-FLOT-2026-10
                [RCNTR_PUERTO_EMB]=BIT-OPER-PUERTO-2026-10)
# Approved cases, 2026-10 vs BUDG: account with the largest overrun, total OPEX and drivers (% computed in PostgreSQL).
declare -A CASE=([RCNTR_MINA_CAEX]="0061100100=67.8|OPEX=15.3|HOROP=-13.4,TONMOV=-13.4"
                 [RCNTR_MINA_TRUCK]="0061100200=16.7|OPEX=7.0|TONMOV=-15.0"
                 [RCNTR_LIXIV_SXEW]="0061100100=141.9|OPEX=11.2|TONAPI=-14.0"
                 [RCNTR_CONCEN_FLOT]="0061100400=42.4|OPEX=5.9|TONPRO=-0.9"
                 [RCNTR_PUERTO_EMB]="0063100100=0.3|OPEX=-0.3|TONEMB=-18.5")
declare -A STORY=([RCNTR_MINA_CAEX]="repuestos sobre presupuesto (inyectores Komatsu) y caída de horas operativas"
                  [RCNTR_MINA_TRUCK]="combustible sobre presupuesto (motobombas de achique) y extracción -15 %"
                  [RCNTR_LIXIV_SXEW]="repuestos sobre presupuesto (bomba de ácido) y caída de toneladas apiladas"
                  [RCNTR_CONCEN_FLOT]="reactivos sobre presupuesto (xantato 15 g/t) con la molienda en presupuesto"
                  [RCNTR_PUERTO_EMB]="costos fijos en presupuesto y caída de toneladas embarcadas (marejadas)")
PASS=0 FAIL=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
ko()   { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33m•\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
# </dev/null: `compose exec` must never swallow the stdin of the surrounding read loops.
s4()   { $DC exec -T s4hana-db psql -U "$S4_DB_ADMIN_USER" -d s4hana -tAc "$1" </dev/null 2>/dev/null; }
kb()   { $DC exec -T vector-db psql -U "$VECTOR_DB_USER" -d knowledge -tAc "$1" </dev/null 2>/dev/null; }
sql()  { $DC exec -T trino trino --output-format TSV --execute "$1" </dev/null 2>/dev/null; }
api()  { curl -fsS --max-time "${2:-30}" "http://127.0.0.1:${FRONTEND_PORT:-3000}/api/$1"; }
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
rag_check() {  # $1 engine, $2 language, $3 question, $4 RCNTR, $5 unit OPEX (Trino), $6 cause word the answer must cite
  local engine=$1 language=$2 question=$3 rcntr=$4 expected_unit=$5 cause=${6:-} response start tenths took verdict
  start=$(date +%s%N)
  response=$(curl -fsS --max-time 600 -X POST -H 'content-type: application/json' \
    -d "{\"question\":\"$question\",\"language\":\"$language\",\"engine\":\"$engine\",\"rcntr\":\"$rcntr\"}" \
    "http://127.0.0.1:${FRONTEND_PORT:-3000}/api/ask" 2>/dev/null)
  tenths=$(( ($(date +%s%N) - start) / 100000000 ))
  took="$((tenths / 10)).$((tenths % 10)) s"
  [[ $engine == nim && $tenths -gt 150 ]] && took+=" (sobre el objetivo de 15 s)"
  verdict=$(json "(lambda u: '|'.join([data['model_used'], data['language_check']['detected'] or '-', data['period'],
    str(u['current']), 'USD/' + u['symbol'], '%+.1f' % u['delta_budget_pct'],
    data['sources'][0]['doc_id'] if data['sources'] else '-',
    json.dumps(data['sources'][0]['metadata'], ensure_ascii=False, sort_keys=True) if data['sources'] else '-',
    '%d/%d' % (data['figures_check']['grounded'], data['figures_check']['checked']),
    ','.join(data['figures_check']['ungrounded']), data['trace_id'] or '-',
    str('$cause' in data['answer'].lower()) if '$cause' else '-']))(
    next(u for u in data['analysis']['unit_costs'] if u['stagr'] == data['analysis']['driver']))" <<<"$response")
  IFS='|' read -r model detected period unit symbol vs_budget doc meta figures ungrounded trace cited <<<"$verdict"
  if [[ $model == "$engine/"* && $detected == "${language,,}" && $period == 2026-10 && $unit == "$expected_unit" &&
        $doc == "${LOG[$rcntr]}" && $meta == "{\"Año\": 2026, \"Mes\": 10, \"RCNTR\": \"$rcntr\"}" && $cited != False ]]; then
    ok "IA $language · $model en $took → $rcntr $period: OPEX unitario $unit $symbol ($vs_budget % vs $BUDGET, Trino) ·" \
       "bitácora $doc $meta${cause:+ · causa «$cause…» citada} · respuesta en '$detected' ·" \
       "cifras ancladas a Trino $figures${ungrounded:+ (no ancladas: $ungrounded)}"
    trace_check "$trace" "$model"
  else
    ko "IA $language/$engine $rcntr → modelo='${model:-ninguno}' idioma='$detected' período='$period' unitario='$unit'" \
       "bitácora='$doc' $meta causa '$cause'=$cited ${response:0:200}"
  fi
}

step "1 · Contenedores y salud"
for svc in s4hana-db kafka debezium minio unity-catalog trino delta-sink vector-db ollama egress-proxy langfuse-db \
           langfuse backend frontend; do
  health=$($DC ps --format '{{.Health}}' "$svc" 2>/dev/null)
  [[ $health == healthy ]] && ok "$svc healthy" || ko "$svc → ${health:-no está corriendo}"
done
for job in minio-init debezium-init; do
  code=$(docker inspect -f '{{.State.ExitCode}}' "rollingf-$job" 2>/dev/null)
  [[ $code == 0 ]] && ok "$job completado (exit 0)" || ko "$job exit=${code:-n/a}"
done

step "2 · Modelo financiero SAP (S/4HANA simulado: ACDOCA · ACDOCP · FINSSKF)"
tables=$(s4 "SELECT string_agg(table_name, ',' ORDER BY table_name) FROM information_schema.tables WHERE table_schema = 'sap'")
counts=$(s4 "SELECT string_agg(relname || '=' || n_live_tup, ' ' ORDER BY relname) FROM pg_stat_user_tables WHERE schemaname = 'sap'")
[[ $tables == acdoca,acdocp,finsskf ]] && ok "esquema sap = exactamente ACDOCA, ACDOCP y FINSSKF ($counts)" || ko "tablas SAP: '$tables'"
pk() { s4 "SELECT string_agg(a.attname, ',' ORDER BY array_position(i.indkey::int2[], a.attnum)) FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey) WHERE i.indrelid = '$1'::regclass AND i.indisprimary"; }
pk_acdocp=$(pk sap.acdocp)
pk_finsskf=$(pk sap.finsskf)
rvers=$(s4 "SELECT count(*) FROM information_schema.columns WHERE table_schema = 'sap' AND column_name = 'rvers'")
[[ $pk_acdocp == rclnt,reqtsn,datapakid,record && $pk_finsskf == rclnt,stagr,recid,date_from && $rvers == 0 ]] \
  && ok "campos documentados: ACDOCP ($pk_acdocp; versión = CATEGORY) · FINSSKF ($pk_finsskf; RRCTY + CATEGORY)" \
  || ko "claves ACDOCP='$pk_acdocp' FINSSKF='$pk_finsskf' columnas RVERS=$rvers"
[[ $(s4 "SELECT count(*) FROM (SELECT belnr FROM sap.acdoca GROUP BY belnr HAVING sum(wsl) <> 0 OR sum(hsl) <> 0 OR sum(ksl) <> 0) x") == 0 ]] \
  && ok "ACDOCA cuadrado por documento (Σ WSL = Σ HSL = Σ KSL = 0)" || ko "ACDOCA descuadrado"
[[ $(s4 "SELECT count(*) FROM (SELECT rkcur FROM sap.acdoca UNION ALL SELECT rkcur FROM sap.acdocp) x WHERE rkcur <> 'USD'") == 0 ]] \
  && ok "OPEX en moneda de grupo KSL (RKCUR = USD en ACDOCA y ACDOCP)" || ko "moneda de grupo distinta de USD"
categories=$(s4 "SELECT (SELECT string_agg(DISTINCT category, ',' ORDER BY category) FROM sap.acdocp) || '|' ||
                         (SELECT string_agg(DISTINCT category, ',' ORDER BY category) FROM sap.finsskf WHERE rrcty = '1')")
[[ $categories == "$BUDGET,$CATEGORY|$BUDGET,$CATEGORY" ]] \
  && ok "categorías de plan en ACDOCP y FINSSKF: $BUDGET (presupuesto base) + $CATEGORY (rolling forecast)" \
  || ko "categorías de plan ACDOCP|FINSSKF: '$categories'"
published=$(s4 "SELECT count(*) FROM pg_publication_tables WHERE pubname = 'nodara_s4_pub'")
[[ $published == 3 ]] && ok "publicación CDC nodara_s4_pub cubre las 3 tablas financieras" || ko "publicación CDC: $published tablas"

step "3 · Cadena de valor C1: 5 casos aprobados (seed estricto)"
centers_s4=$(s4 "SELECT string_agg(DISTINCT rcntr, ' ' ORDER BY rcntr) FROM sap.acdoca WHERE rcntr IS NOT NULL")
[[ $centers_s4 == "$(printf '%s\n' "${CENTERS[@]}" | sort | xargs)" ]] \
  && ok "ACDOCA: exactamente los 5 centros de costo aprobados ($centers_s4)" || ko "centros de costo en ACDOCA: '$centers_s4'"
for rc in "${CENTERS[@]}"; do
  shape=$(s4 "SELECT (SELECT string_agg(DISTINCT fiscyearper, ',' ORDER BY fiscyearper) FROM sap.acdoca WHERE rcntr = '$rc') || '|' ||
                     (SELECT string_agg(DISTINCT fiscyearper, ',' ORDER BY fiscyearper) FROM sap.acdocp
                       WHERE rcntr = '$rc' AND category = '$BUDGET') || '|' ||
                     (SELECT string_agg(DISTINCT to_char(date_from, 'YYYY\"0\"MM'), ',' ORDER BY to_char(date_from, 'YYYY\"0\"MM'))
                        FROM sap.finsskf WHERE rcntr = '$rc' AND category = '$BUDGET' AND stagr = '${DRIVER[$rc]}') || '|' ||
                     (SELECT count(DISTINCT fiscyearper) || ':' || min(fiscyearper) || ':' || max(fiscyearper) FROM sap.acdocp
                       WHERE rcntr = '$rc' AND category = '$CATEGORY') || '|' ||
                     (SELECT (max(opex) - min(opex)) / max(opex) <= 0.01
                        FROM (SELECT sum(ksl) AS opex FROM sap.acdocp WHERE rcntr = '$rc' AND category = '$CATEGORY'
                               GROUP BY fiscyearper ORDER BY fiscyearper DESC LIMIT 12) l)")
  [[ $shape == "2026008,2026009,2026010|2026008,2026009,2026010|2026008,2026009,2026010|18:2026011:2028004|true" ]] \
    && ok "$rc: 3 meses reales (ACDOCA) con su presupuesto $BUDGET (ACDOCP + FINSSKF ${DRIVER[$rc]}) y 18 meses $CATEGORY que convergen (±1 %)" \
    || ko "$rc: forma del seed '$shape'"
done
rising=$(s4 "SELECT string_agg(ksl::bigint::text, ' → ' ORDER BY fiscyearper) || '|' || bool_and(ksl > coalesce(prev, 0))
             FROM (SELECT fiscyearper, sum(ksl) AS ksl, lag(sum(ksl)) OVER (ORDER BY fiscyearper) AS prev
                     FROM sap.acdoca WHERE rcntr = '$RCNTR' AND racct = '0061100100' GROUP BY fiscyearper) x")
[[ ${rising#*|} == true ]] && ok "$RCNTR: Repuestos (0061100100) al alza mes a mes: USD ${rising%|*}" || ko "repuestos CAEX='$rising'"
seen=0
while read -r rc result; do
  [[ -n $rc ]] || continue
  seen=$((seen + 1))
  [[ $result == "${CASE[$rc]:-?}" ]] && ok "caso $rc: ${STORY[$rc]} (2026-10 vs $BUDGET: $result)" \
    || ko "caso $rc: '$result' (esperado '${CASE[$rc]:-sin caso aprobado}')"
done < <(s4 "WITH acc AS (
                 SELECT rcntr, racct, a.ksl AS actual, b.ksl AS budget
                   FROM (SELECT rcntr, racct, sum(ksl) AS ksl FROM sap.acdoca
                          WHERE fiscyearper = '2026010' AND rcntr IS NOT NULL GROUP BY 1, 2) a
                   JOIN (SELECT rcntr, racct, sum(ksl) AS ksl FROM sap.acdocp
                          WHERE category = '$BUDGET' AND fiscyearper = '2026010' GROUP BY 1, 2) b USING (rcntr, racct)),
               top AS (SELECT DISTINCT ON (rcntr) rcntr, racct || '=' || round((actual - budget) / budget * 100, 1) AS item
                         FROM acc ORDER BY rcntr, actual - budget DESC),
               opex AS (SELECT rcntr, 'OPEX=' || round((sum(actual) - sum(budget)) / sum(budget) * 100, 1) AS item
                          FROM acc GROUP BY 1),
               drv AS (SELECT r.rcntr, string_agg(r.stagr || '=' || round((r.msl - p.msl) / p.msl * 100, 1), ',' ORDER BY r.stagr) AS item
                         FROM sap.finsskf r
                         JOIN sap.finsskf p ON p.rcntr = r.rcntr AND p.stagr = r.stagr AND p.date_from = r.date_from
                                           AND p.category = '$BUDGET'
                        WHERE r.rrcty = '0' AND r.date_from = '2026-10-01' GROUP BY 1)
          SELECT rcntr || ' ' || top.item || '|' || opex.item || '|' || drv.item
            FROM top JOIN opex USING (rcntr) JOIN drv USING (rcntr) ORDER BY 1")
[[ $seen -eq ${#CENTERS[@]} ]] || ko "casos evaluados: $seen de ${#CENTERS[@]}"
legacy=$(( $(s4 "SELECT count(*) FROM information_schema.tables WHERE table_name IN ('but000','matdoc','ukmbp_cms_sgm','dfkkbptaxnum','qmel','aufk','resb','tcurr')") + \
           $(s4 "SELECT count(*) FROM sap.acdoca WHERE rbukrs <> 'CL01'") + \
           $(kb "SELECT count(*) FROM kb.documents WHERE doc_id LIKE 'AU-%' OR source_uri LIKE '%raw-manuals%'") + \
           $(s3 "" 2>/dev/null | grep -c '<Name>raw-manuals</Name>') ))
[[ $legacy -eq 0 ]] && ok "cero rastros del modelo anterior (tablas SAP, BR01, manuales AU en pgvector y bucket raw-manuals)" || ko "$legacy rastros del modelo anterior"

step "4 · CDC (Debezium → Kafka)"
status=$(curl -fsS "http://127.0.0.1:${DEBEZIUM_PORT:-8083}/connectors/s4hana-cdc/status" 2>/dev/null)
[[ $(grep -o '"state":"RUNNING"' <<<"$status" | wc -l) -ge 2 ]] && ok "conector s4hana-cdc RUNNING (connector + task)" || ko "conector s4hana-cdc: ${status:-sin respuesta}"
topics=$($DC exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list </dev/null 2>/dev/null | grep '^s4hana\.sap\.' | tr '\n' ' ')
[[ $topics == "s4hana.sap.acdoca s4hana.sap.acdocp s4hana.sap.finsskf " ]] && ok "tópicos CDC: $topics" || ko "tópicos CDC: '$topics'"

step "5 · Lakehouse (Trino: S/4 en vivo + Delta bronze + silver; Unity Catalog)"
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

step "6 · OPEX unitario y desviación vs presupuesto deterministas (Trino = PostgreSQL, sin IA)"
for rc in "${CENTERS[@]}"; do
  stagr=${DRIVER[$rc]}
  pg_series=$(s4 "WITH cutoff AS (SELECT max(fiscyearper) AS p FROM sap.acdoca WHERE rcntr = '$rc'),
                       o AS (SELECT fiscyearper AS p, sum(ksl) AS opex FROM sap.acdoca WHERE rcntr = '$rc' GROUP BY 1
                             UNION ALL
                             SELECT a.fiscyearper, sum(a.ksl) FROM sap.acdocp a, cutoff c
                              WHERE a.rcntr = '$rc' AND a.category = '$CATEGORY' AND a.fiscyearper > c.p GROUP BY 1),
                       q AS (SELECT to_char(date_from, 'YYYY\"0\"MM') AS p, sum(msl) AS qty, max(runit) AS runit FROM sap.finsskf
                              WHERE rcntr = '$rc' AND stagr = '$stagr' AND (rrcty = '0' OR category = '$CATEGORY') GROUP BY 1)
                  SELECT string_agg(o.p || '=' || round(o.opex / q.qty, CASE q.runit WHEN 'H' THEN 2 ELSE 4 END), ' ' ORDER BY o.p)
                    FROM o JOIN q USING (p)")
  pg_deviation=$(s4 "WITH a AS (SELECT sum(ksl) AS o FROM sap.acdoca WHERE rcntr = '$rc' AND fiscyearper = '2026010'),
                          b AS (SELECT sum(ksl) AS o FROM sap.acdocp WHERE rcntr = '$rc' AND category = '$BUDGET' AND fiscyearper = '2026010'),
                          qa AS (SELECT msl, CASE runit WHEN 'H' THEN 2 ELSE 4 END AS d FROM sap.finsskf
                                  WHERE rcntr = '$rc' AND stagr = '$stagr' AND rrcty = '0' AND date_from = '2026-10-01'),
                          qb AS (SELECT msl FROM sap.finsskf
                                  WHERE rcntr = '$rc' AND stagr = '$stagr' AND category = '$BUDGET' AND date_from = '2026-10-01'),
                          u AS (SELECT round(a.o / qa.msl, qa.d) AS ua, round(b.o / qb.msl, qa.d) AS ub FROM a, b, qa, qb)
                     SELECT round((a.o - b.o) / b.o * 100, 1) || '|' || round((qa.msl - qb.msl) / qb.msl * 100, 1) || '|' ||
                            u.ua || '|' || u.ub || '|' || round((u.ua - u.ub) / u.ub * 100, 1)
                       FROM a, b, qa, qb, u")
  timeline=$(api "opex/timeline?rcntr=$rc")
  trino_series=$(json "(lambda d: ' '.join(m['period'].replace('-', '0') + '=' + format(m['drivers']['$stagr']['unit_cost'], '.%df' % d)
                       for m in data['periods']))(next(x['decimals'] for x in data['drivers'] if x['stagr'] == '$stagr'))" <<<"$timeline")
  trino_deviation=$(json "(lambda s, u, q: '%.1f|%.1f|%.*f|%.*f|%.1f' % (s['opex']['delta_budget_pct'], q['delta_budget_pct'],
                          u['decimals'], u['current'], u['decimals'], u['budget'], u['delta_budget_pct']))(data['summary'],
                          next(x for x in data['summary']['unit_costs'] if x['stagr'] == '$stagr'),
                          next(x for x in data['summary']['drivers'] if x['stagr'] == '$stagr'))" <<<"$timeline")
  months=$(json "'%d+%d' % (sum(m['kind'] == 'actual' for m in data['periods']), sum(m['kind'] == 'plan' for m in data['periods']))" <<<"$timeline")
  IFS='|' read -r opex_pct driver_pct unit_actual unit_budget unit_pct <<<"$trino_deviation"
  [[ -n $pg_series && $pg_series == "$trino_series" && $months == 3+18 && -n $pg_deviation && $pg_deviation == "$trino_deviation" ]] \
    && ok "$rc: $months meses de OPEX unitario por $stagr idénticos en Trino y PostgreSQL · 2026-10 vs $BUDGET: OPEX $opex_pct %," \
          "$stagr $driver_pct %, unitario $unit_actual vs $unit_budget ($unit_pct %)" \
    || ko "$rc: Trino='${trino_series:0:90}' / '$trino_deviation' PostgreSQL='${pg_series:0:90}' / '$pg_deviation' meses='$months'"
done
summary=$(api "opex/timeline?rcntr=$RCNTR" | json "(lambda s, u, h: '|'.join(map(str, [s['period'], u['current'], u['delta_budget_pct'],
                 s['opex']['delta_budget_pct'], h['delta_budget_pct'], u['delta_previous_pct'], s['opex']['delta_previous_pct'],
                 h['delta_previous_pct'], s['forecast']['stable_from']])))(data['summary'], data['summary']['unit_costs'][0],
                 data['summary']['drivers'][0])")
[[ $summary == "2026-10|550.65|33.1|15.3|-13.4|29.1|12.2|-13.1|2027-03" ]] \
  && ok "$RCNTR 2026-10 (Trino): vs $BUDGET OPEX +15,3 %, horas -13,4 %, 550,65 USD/h (+33,1 %); vs mes anterior +12,2 % /" \
        "-13,1 % / +29,1 %; plan estable desde 2027-03" \
  || ko "resumen de desviación $RCNTR: '$summary'"

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
[[ $volumes == *'"full_name":"nodara.raw.docs_mantenimiento"'* && $volumes == *'"full_name":"nodara.raw.docs_operaciones"'* ]] \
  && ok "Unity Catalog volumes nodara.raw.docs_mantenimiento y docs_operaciones → s3://raw-docs/<origen>" \
  || ko "volúmenes raw no registrados en Unity Catalog"
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
[[ ${chunks:-0} -gt 0 && $coords == "${#CENTERS[@]}" ]] \
  && ok "pgvector $(kb "SELECT extversion FROM pg_extension WHERE extname = 'vector'"): $(kb 'SELECT count(*) FROM kb.documents') bitácoras, $chunks fragmento(s), $(kb 'SELECT count(embedding) FROM kb.chunks') indexado(s) · $coords coordenadas Año/Mes/RCNTR" \
  || ko "kb.chunks: $chunks fragmentos, $coords coordenadas Año/Mes/RCNTR"
routed=""
for rc in "${CENTERS[@]}"; do
  [[ $(kb "SELECT string_agg(DISTINCT doc_id, ',') FROM kb.chunks WHERE rcntr = '$rc' AND gjahr = 2026 AND monat = 10") == "${LOG[$rc]}" ]] \
    || routed+=" $rc"
done
[[ -z $routed ]] && ok "filtro Año 2026 · Mes 10 · RCNTR → exactamente la bitácora de cada centro de costo (${LOG[*]})" \
  || ko "filtro por metadatos sin su bitácora:$routed"
if $DC exec -T vector-db psql -U "$VECTOR_DB_USER" -d knowledge -v ON_ERROR_STOP=1 -c \
     "BEGIN; INSERT INTO kb.chunks (doc_id, chunk_no, section, content) VALUES ('BIT-MANT-CAEX-2026-10', 99, 'x', 'x'); ROLLBACK;" \
     </dev/null >/dev/null 2>&1; then
  ko "pgvector aceptó un vector sin Año/Mes/RCNTR"
else
  ok "pgvector rechaza un vector sin Año/Mes/RCNTR (NOT NULL + CHECK)"
fi
[[ $(kb "SELECT count(*) FROM kb.chunks WHERE rcntr = '$RCNTR' AND gjahr = 2026 AND monat = 9") == 0 ]] \
  && ok "filtro por metadatos: ninguna bitácora de $RCNTR en 2026-09 (la IA no recibe textos de otro mes)" || ko "filtro por metadatos inconsistente"
docker network inspect rollingf-kb -f '{{range .Containers}}{{.Name}} {{end}}' | grep -qv 'trino\|kafka\|debezium' \
  && ok "segmento rollingf-kb exclusivo: $(docker network inspect rollingf-kb -f '{{range .Containers}}{{.Name}} {{end}}')" || ko "rollingf-kb compartido con servicios ajenos"

step "9 · Gerente de Finanzas → frontend → backend → IA (motor NIM / Ollama, ruteo de idioma, Langfuse)"
home=$(curl -fsS "http://127.0.0.1:${FRONTEND_PORT:-3000}/" 2>/dev/null)
[[ -n $home ]] && ok "frontend HTTP 200 en 127.0.0.1:${FRONTEND_PORT:-3000}" || ko "frontend sin respuesta"
[[ $home == *'aria-label="Español"'* && $home == *'aria-label="English"'* && $home == *'aria-label="Português"'* &&
   $home == *'NVIDIA NIM (Cloud)'* && $home == *'Ollama (Local)'* && $home == *'data-testid="cost-center-select"'* ]] \
  && ok "selectores de idioma (ES/EN/PT), motor (NIM / Ollama) y centro de costo desplegados (comportamiento: make ui-test)" \
  || ko "falta un selector (idioma, motor o centro de costo) en el frontend"
centers=$(api "opex/cost-centers" | json "' '.join(c['rcntr'] + ':' + ','.join(c['categories']) + ('+$BUDGET' if c['budget'] else '')
                                             for c in data['cost_centers'])")
[[ $centers == "$(printf "%s:$CATEGORY+$BUDGET " "${CENTERS[@]}" | xargs)" ]] \
  && ok "selector de centro de costo desde el lakehouse, en orden de la cadena de valor: $centers" || ko "centros de costo: '$centers'"
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
  rag_check $engine ES "Explica la desviación de OPEX del mes actual" $RCNTR 550.65 inyector
  rag_check $engine EN "Explain the OPEX deviation of the current month" $RCNTR 550.65
  rag_check $engine PT "Explique o desvio de OPEX do mês atual" $RCNTR 550.65
  # Port: fixed costs on budget, the unit OPEX rises because the shipped tonnes fall (swells).
  rag_check $engine ES "¿Por qué subió el OPEX unitario del puerto este mes?" $PORT 5.0094 marejad
  if (( nim && ollama )); then  # local contingency engine (no data leaves the enclave)
    rag_check ollama ES "Explica la desviación de OPEX del mes actual" $RCNTR 550.65
  fi
else
  skip "IA E2E omitida: modelos aún no importados (make models && make embed)"
fi

step "10 · Tiempo real E2E: S/4 → Debezium → Kafka → Delta (bronze → silver) → Trino → API"
before=$(api "opex/timeline?rcntr=$RCNTR" | json "data['summary']['opex']['current']")
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
  after=$(api "opex/timeline?rcntr=$RCNTR" | json "data['summary']['opex']['current']")
  if [[ ${found:-0} -ge 2 && -n $after && $after != "$before" ]]; then
    lag=$(sql "SELECT max(date_diff('millisecond', _source_ts, _ingested_at)) FROM lakehouse.bronze.acdoca WHERE belnr = '$belnr'")
    ok "documento $belnr (consumo de repuestos CAEX) en silver en $(( $(date +%s) - start ))s (latencia CDC ${lag} ms); OPEX del mes vía Trino: $before → $after"
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
