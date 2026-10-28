# CLAUDE.md — Nodara Rolling Forecast (OPEX 18 meses)

## Regla obligatoria de respuesta

Todas tus respuestas sobre tareas completadas en iteraciones futuras deben ser en ESPAÑOL, de forma BREVE, y estructuradas siempre en 4 puntos: 1. Qué se hizo. 2. Resultado Esperado. 3. Cómo Validarlo (QA). 4. Deuda Técnica (Registrar cualquier atajo, warning o refactorización pendiente).

La deuda del punto 4 se consolida en [TECH_DEBT.md](TECH_DEBT.md) (ID, impacto, propuesta y estado) en la misma iteración.

## Roles y scope

- **Arquitecto de Datos Financieros e IA** (usuario): define el alcance y aprueba los cambios. **Programador Senior** (Claude): implementa y valida.
- **Objetivo**: Rolling Forecast de OPEX a 18 meses para la Gran Minería. Trino calcula de forma determinista el OPEX
  (KSL), los impulsores físicos y el OPEX unitario sobre el lakehouse. El LLM (NVIDIA NIM en la nube u Ollama local,
  a elección del operador) **no calcula**: explica las desviaciones cruzando esas cifras con las bitácoras de pgvector
  filtradas por Año, Mes y RCNTR. Responde en ES/EN/PT dentro de una simulación **air-gapped** cuya única salida es
  un gateway con allowlist (solo NVIDIA).
- **Stack cerrado** (no agregar tecnologías sin aprobación del Arquitecto):
  PostgreSQL relacional (S/4HANA) · Debezium + Kafka · MinIO + Delta Lake + Unity Catalog OSS + Trino ·
  PostgreSQL + pgvector aislado (solo bitácoras) · FastAPI + LangChain + Ollama · Next.js + TailwindCSS (gráfico SVG
  propio, sin librerías) · NVIDIA NIM (cloud) · Langfuse v2 autoalojado · gateway de egress (squid).
- **Seed ESTRICTO: caso CAEX OPEX** (`RCNTR_MINA_CAEX`, sociedad/área de control `CL01`, moneda de grupo USD) y nada
  más. ACDOCA: 3 meses reales (2026-08 → 2026-10) con Repuestos (`0061100100`) al alza. ACDOCP: 18 meses de plan
  (2026-11 → 2028-04, `CATEGORY = RF18M`, exportación SAC) que se estabilizan. FINSSKF: caída de horas operativas
  (`HOROP`) en el mes actual (2026-10). Bitácora del Jefe de Mantenimiento de 2026-10 (inyectores Komatsu por diésel
  contaminado). Todo dato nuevo debe pertenecer a un caso aprobado.

## Mapa del sistema

| Servicio | Red(es) | Host | Notas |
|---|---|---|---|
| `s4hana-db` | net, edge | `S4_DB_PORT` | `wal_level=logical`; esquema `sap` con **3 tablas**: `ACDOCA`, `ACDOCP`, `FINSSKF`; init en `init-scripts/s4hana` |
| `kafka` | net | — | KRaft, un nodo; un tópico `s4hana.sap.<tabla>` por tabla publicada |
| `debezium` / `debezium-init` | net, edge / net | 8083 | conector `cdc/connectors/s4hana-cdc.json` (PUT idempotente) |
| `minio` / `minio-init` | net, edge / net | 9000, 9001 | buckets `lakehouse` (Delta) y `raw-docs` (originales versionados con metadatos Rcntr/Gjahr/Monat) |
| `unity-catalog` | net, edge | 8081 | tablas `nodara.bronze.*` + volumen `nodara.raw.docs_<origen>` (H2 en volumen) |
| `trino` | net, edge | 8080 | catálogos `lakehouse` (Delta: `bronze.*` + vistas `silver.*`) y `s4hana` (PostgreSQL, rol `trino_ro`) |
| `delta-sink` | net | — | Kafka → Delta bronze; registra en Trino y UC y crea la vista silver (PK de la key Debezium) |
| `vector-db` | kb, edge | 5433 | esquema `kb`; `chunks.gjahr/monat/rcntr` NOT NULL (Año/Mes/RCNTR); `documents.source_uri` → raw layer |
| `ollama` | net | — | contingencia local + embeddings; sin egress; modelos solo vía `make models` (perfil `bootstrap`) |
| `egress-proxy` | net, egress | — | squid: default deny, solo CONNECT 443 a `egress/allowlist.txt` (solo NVIDIA) |
| `langfuse` / `langfuse-db` | net, obs, edge / obs | 3001 | Langfuse v2 autoalojado; proyecto `nodara-rollingf`, keys y admin headless desde `.env` |
| `backend` | net, kb | — | no publicado; `GET /api/v1/opex/cost-centers`, `GET /api/v1/opex/timeline?rcntr=`, `POST /api/v1/ask {question, language: ES\|EN\|PT, engine: nim\|ollama, rcntr, period?}` |
| `frontend` | net, edge | 3000 | única entrada; proxy `/api/*` → backend; selector de centro de costo, gráfico real + plan, KPIs, chat IA; UI ES/EN/PT |
| `ui-test` | edge | — | perfil `qa`: Playwright contra el frontend (`make ui-test`) |

Proyecto compose `nodara-rollingf`: contenedores y redes `rollingf-*`, imágenes `nodara-rollingf/*`. Convive con
`nodara-br-rag` (mismos puertos: no corren a la vez).

## Convenciones

- **Idiomas**: código y comentarios en inglés; documentación en español; bitácoras originales en español; UI y
  respuestas del LLM en el idioma elegido (ES/EN/PT, por defecto ES).
- **SAP**: tablas y campos SAP originales en minúsculas (cliente `100`, esquema `sap`) según las fichas de tabla
  entregadas por el Arquitecto. `ACDOCP` no tiene `RVERS`: la versión del plan es `CATEGORY` (plan category); su clave
  es `REQTSN/DATAPAKID/RECORD`. `FINSSKF` (valores vigentes) se identifica por `STAGR/RECID/DATE_FROM`, con `RRCTY`
  (0 real, 1 plan) y `CATEGORY`. Un dato nuevo va en la tabla SAP real que lo contiene, nunca en columnas inventadas.
  ACDOCA debe quedar cuadrado por `belnr` (Σ `wsl` = Σ `hsl` = Σ `ksl` = 0). Textos de datos maestros fuera de alcance
  (SKAT, CSKT, TKA03, categorías) solo en `backend/app/masterdata.py`.
- **La IA no calcula**: toda cifra (OPEX por cuenta, horas, toneladas, USD/h, USD/t, variaciones, plan) se calcula en
  SQL de Trino (`backend/app/lakehouse.py`) sobre `lakehouse.silver.*`; Python y la UI solo formatean. Trino inlinea
  los CTE en cada referencia: leer cada tabla silver pocas veces (límite de 150 stages). El control de cifras
  (`backend/app/figures.py`) reporta todo número de la respuesta que no venga de Trino, de las bitácoras o de la pregunta.
- **Base de conocimiento**: originales en `knowledge/raw-docs/<origen>/<doc_id>.md`, con `gjahr`, `monat` y `rcntr`
  obligatorios en el front matter y una sección `##` por fragmento. `make kb-seed` regenera
  `init-scripts/vectordb/02-seed-docs.sql`, que **nunca se edita a mano**. La recuperación filtra primero por
  RCNTR + Año + Mes del período analizado y después ordena por similitud.
- **Raw layer**: `minio-init` sube los originales a `s3://raw-docs/<origen>/` solo si cambia su SHA-256 (bucket
  versionado), con metadatos `Rcntr/Gjahr/Monat`, y registra un volumen EXTERNAL de Unity Catalog por origen.
  `make smoke` verifica índice ⊆ raw.
- **Ruteo de idioma**: hay un *system prompt* por idioma en `backend/app/orchestrator.py` y el control de idioma
  re-traduce si la respuesta se desvía. Para agregar un idioma: diccionario en `frontend/app/dictionaries.ts` +
  prompts, etiquetas y mensajes en el backend.
- **i18n de la UI**: todo texto estático y todo metadato de la respuesta viven en `frontend/app/dictionaries.ts`, que
  también usa el servidor (cookie `nodara.language`). `i18n.tsx` solo contiene el contexto de React. Los diccionarios
  ES/EN están tipados contra PT, así que si falta una clave el build falla.
- **Gráficos**: forma de énfasis (cuenta que impulsa la desviación en acento, resto en gris), un solo eje por medida
  (nunca doble eje), tooltip por columna con teclado, vista de tabla. Colores validados con el validador de dataviz
  sobre la superficie `#0f172a`.
- **Motores LLM**: `engine` = `nim` (por defecto) u `ollama`. El modelo NIM se cambia solo con `NIM_MODEL`, después de
  probarlo con una llamada real (NVIDIA retira modelos y habilita otros por cuenta). Si un intento supera
  `NIM_TIMEOUT_S` o falla, la pregunta sigue en Ollama y se informa en `model_used`/`attempts`. Los embeddings siempre son locales.
- **Observabilidad**: una traza de Langfuse por pregunta (`user_id` = `TRACE_USER_ID`) con spans de Trino y pgvector.
  Toda llamada LangChain recibe `observability.callbacks(trace)`. El SDK v2 obliga a usar LangChain 0.3: no subir a
  1.x sin migrar Langfuse (TD-011).
- **Moneda**: sociedad y grupo en USD (WSL = HSL = KSL): no hay conversión ni tasas fijas. El OPEX se reporta en KSL.
- **Versiones fijadas** en imágenes y dependencias (nunca `latest`). Para actualizar, hacerlo a propósito y revalidar con `make smoke`.
- **Secretos**: solo en `.env` (gitignored, lo genera `make env`). En el compose usar `${VAR:?run make env}`; en Debezium,
  `${env:VAR}`. `NVIDIA_API_KEY` se completa a mano (vacía = solo motor local). Nunca commitear credenciales, tokens ni `.env`.
- **Air-gap**: ningún servicio de runtime depende de Internet, salvo NIM, que sale solo por `egress-proxy`. Agregar un
  dominio a `egress/allowlist.txt` o conectar otro servicio a `rollingf-egress` requiere aprobación del Arquitecto. Los
  servicios de IA y streaming no se conectan a `rollingf-edge`. Un puerto nuevo implica bind `127.0.0.1`, una variable
  en `.env.example` y su entrada en `scripts/preflight.sh`.
- **CDC**: para capturar una tabla nueva, agregarla a la publicación (`03-cdc.sql`) y a `table.include.list`;
  `delta-sink` la detecta sola y crea su vista silver (necesita PK).

## Definición de Hecho (obligatoria antes de commit)

1. `make config` → compose válido.
2. `make up` → sin colisiones (preflight) y todo `healthy` (lo espera `scripts/wait-healthy.sh`).
3. `make smoke` → **0 fallos**. Primero re-siembra (`make fresh`, borra los datos). Incluye el modelo financiero, el
   caso CAEX, CDC → bronze → silver, OPEX unitario Trino = PostgreSQL, la IA en ES/EN/PT con NIM, la contingencia
   Ollama, las trazas de Langfuse, el tiempo real y el egress, si los modelos están importados.
4. Si se tocó el frontend: `make ui-test` en verde.
5. README, este archivo y `TECH_DEBT.md` actualizados.

## Comandos

`make env` · `make preflight` · `make config` · `make up` · `make ps` · `make logs s=<servicio>` · `make smoke` ·
`make demo` · `make fresh` · `make ui-test` · `make models` (o `make models from=<volumen>`, importación offline) ·
`make embed` · `make kb-seed` · `make simulate n=10` · `make reset-data` · `make down` · `make clean` (borra todos
los volúmenes, incluidos los modelos)

`./scripts/smoke-test.sh` sin reset sirve solo para diagnóstico: el simulador contabiliza repuestos en ACDOCA.

## Problemas conocidos (entorno WSL + Docker Desktop)

- Si el CLI `docker` devuelve `Input/output error`, Docker Desktop entró en *Resource Saver* (motor detenido sin
  contenedores). Solución: `"/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe" desktop restart`.
- PostgreSQL nativo de Windows ocupa 5432 en esta máquina, por eso el `.env` local usa `S4_DB_PORT=5434`.
- Este proyecto y `nodara-br-rag` publican los mismos puertos: detener uno (`docker compose stop` en su carpeta)
  antes de `make up` del otro. `reset-data` solo borra volúmenes `nodara-rollingf_*`.
- Cambiar seed o esquema exige `make reset-data`, luego `make up` y `make embed`. Los init-scripts solo corren con
  volumen vacío y Debezium no hace snapshot de tablas que se agregan a un conector existente.
- `docker compose up --wait` falla con los jobs de una sola ejecución (los da por fallidos aunque terminen en `exit 0`):
  por eso existe `scripts/wait-healthy.sh`.
- La imagen de MinIO (`pgsty/minio`) no trae `grep`/`sed`/`awk`: en sus scripts usar `case` de sh.
- Unity Catalog exige un prefijo de ruta en los volúmenes EXTERNAL (`s3://bucket/<prefijo>`).
- Idempotencia: Unity Catalog responde `400 *_ALREADY_EXISTS` y Trino `ALREADY_EXISTS` ante duplicados.
- Trino no materializa los CTE: una consulta que referencia muchas veces un CTE pesado supera el máximo de 150 stages.
- PostgreSQL concatena booleanos como `true`/`false` (`'x' || true`), no como `t`/`f`.
- Los tests contra el stack en marcha se lanzan con `compose run --no-deps` (no tocan las dependencias).
- GPU GTX 1070 Ti (Pascal, CC 6.1): Ollama usa el runner CUDA 12 (el de CUDA 13 no la soporta).
- NVIDIA NIM: `meta/llama-3.1-70b-instruct` y `meta/llama-3.3-70b-instruct` dan 410 (EOL), y muchos modelos dan
  404 *Not found for account*. Un modelo listado en `/v1/models` puede igual no responder: probarlo con una llamada real.
- gpt-oss en NIM separa los miles con espacio fino (`4 207 000`): el control de cifras lo admite.
- Langfuse 2.x (Next.js) escucha en la IP del contenedor salvo con `HOSTNAME=0.0.0.0` (sin eso, el healthcheck falla).
- `ChatNVIDIA` no tiene timeout de red: el límite `NIM_TIMEOUT_S` lo aplica `backend/app/llm.py` con un hilo por intento.
- Copiar el proyecto con el Explorador de Windows deja archivos `*:Zone.Identifier` (están en `.gitignore`).
