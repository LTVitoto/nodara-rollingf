# CLAUDE.md — Nodara GenAI Financial Twin (Rolling Forecast OPEX C1, 18 meses)

## Regla obligatoria de respuesta

Todas tus respuestas sobre tareas completadas en iteraciones futuras deben ser en ESPAÑOL, de forma BREVE, y estructuradas siempre en 4 puntos: 1. Qué se hizo. 2. Resultado Esperado. 3. Cómo Validarlo (QA). 4. Deuda Técnica (Registrar cualquier atajo, warning o refactorización pendiente).

La deuda del punto 4 se consolida en [TECH_DEBT.md](TECH_DEBT.md) (ID, impacto, propuesta y estado) en la misma iteración.

## Roles y scope

- **Arquitecto de Datos Financieros e IA** (usuario): define el alcance y aprueba los cambios. **Programador Senior** (Claude): implementa y valida.
- **Objetivo** (producción, "GenAI Financial Twin"): Rolling Forecast de OPEX C1 a 18 meses para la cadena de valor
  de la Gran Minería (mina, concentradora, lixiviación y puerto) con detalle **precio × cantidad (P × Q) por cuenta de
  mayor (RACCT)**. Trino calcula de forma determinista sobre el lakehouse:
  - el costo (KSL), la cantidad (MSL/RUOM) y el precio de cada línea centro × cuenta;
  - el consumo específico contra el impulsor FINSSKF;
  - la desviación real − presupuesto (`BUDG`) descompuesta en efectos precio (P), eficiencia (Q), volumen y gasto;
  - el OPEX unitario y el plan.

  El LLM (NVIDIA NIM en la nube u Ollama local, a elección del operador) **no calcula**: nombra la cuenta y el
  efecto que originan la desviación (ranking de Trino) y lo explica con las bitácoras de pgvector filtradas por Año,
  Mes y RCNTR. Responde en ES/EN/PT dentro de una simulación **air-gapped** cuya única salida es
  un gateway con allowlist (solo NVIDIA).
- **Stack cerrado** (no agregar tecnologías sin aprobación del Arquitecto):
  PostgreSQL relacional (S/4HANA) · Debezium + Kafka · MinIO + Delta Lake + Unity Catalog OSS + Trino ·
  PostgreSQL + pgvector aislado (solo bitácoras) · FastAPI + LangChain + Ollama · Next.js + TailwindCSS (gráfico SVG
  propio, sin librerías) · NVIDIA NIM (cloud) · Langfuse v2 autoalojado · gateway de egress (squid).
- **Seed de producción, ESTRICTO** (sociedad/área de control `CL01`, moneda de grupo USD) y nada más:
  - **12 centros de costo**: `RCNTR_MIN_PERF`, `RCNTR_MIN_TRON`, `RCNTR_MIN_CARG`, `RCNTR_MIN_TRAN` (mina);
    `RCNTR_CON_MOLI`, `RCNTR_CON_FLOT`, `RCNTR_CON_RELA` (concentradora); `RCNTR_LIX_RIEG`, `RCNTR_LIX_SX`,
    `RCNTR_LIX_EW` (lixiviación); `RCNTR_PTO_FILT`, `RCNTR_PTO_EMBA` (puerto). Cada uno con 4–5 cuentas `RACCT_*` y
    un impulsor FINSSKF.
  - **Datos por centro**: ACDOCA con 6 meses reales (2026-05 → 2026-10), ACDOCP `BUDG` para esos 6 meses y `RF18M`
    para 18 meses (2026-11 → 2028-04). Todo coherente en P × Q.
  - **4 anomalías de 2026-10, con su bitácora de justificación**:
    - aceros de perforación por roca abrasiva: Q en `RACCT_ACEROS`;
    - tarifa del xantato: P en `RACCT_REACTIVOS`;
    - falla de revestimientos del molino SAG: horas extra en `RACCT_LABOR`;
    - buques retrasados: impulsor del puerto en 0, con `RACCT_LABOR` y `RACCT_MANTEN` fijos.

  Todo dato nuevo debe pertenecer a un caso aprobado.

## Mapa del sistema

| Servicio | Red(es) | Host | Notas |
|---|---|---|---|
| `s4hana-db` | net, edge | `S4_DB_PORT` | `wal_level=logical`; esquema `sap` con **3 tablas**: `ACDOCA`, `ACDOCP`, `FINSSKF`; init en `init-scripts/s4hana` |
| `kafka` | net | — | KRaft, un nodo; un tópico `s4hana.sap.<tabla>` por tabla publicada |
| `debezium` / `debezium-init` | net, edge / net | 8083 | conector `cdc/connectors/s4hana-cdc.json` (PUT idempotente) |
| `minio` / `minio-init` | net, edge / net | 9000, 9001 | buckets `lakehouse` (Delta) y `raw-docs` (originales versionados con metadatos Rcntr/Gjahr/Monat) |
| `unity-catalog` | net, edge | 8081 | tablas `nodara.bronze.*` + volumen `nodara.raw.docs_<origen>` (H2 en volumen) |
| `trino` | net, edge | 8080 | catálogos `lakehouse` (Delta: `bronze.*` + vistas `silver.*` + vistas `gold.*` P × Q, publicadas por el backend) y `s4hana` (PostgreSQL, rol `trino_ro`) |
| `delta-sink` | net | — | Kafka → Delta bronze; registra en Trino y UC y crea la vista silver (PK de la key Debezium) |
| `vector-db` | kb, edge | 5433 | esquema `kb`; `chunks.gjahr/monat/rcntr` NOT NULL (Año/Mes/RCNTR); `documents.source_uri` → raw layer |
| `ollama` | net | — | contingencia local + embeddings; sin egress; modelos solo vía `make models` (perfil `bootstrap`) |
| `egress-proxy` | net, egress | — | squid: default deny, solo CONNECT 443 a `egress/allowlist.txt` (solo NVIDIA) |
| `langfuse` / `langfuse-db` | net, obs, edge / obs | 3001 | Langfuse v2 autoalojado; proyecto `nodara-rollingf`, keys y admin headless desde `.env` |
| `backend` | net, kb | — | no publicado; `GET /api/v1/opex/cost-centers`, `GET /api/v1/opex/timeline?rcntr=`, `GET /api/v1/opex/matrix`, `POST /api/v1/ask {question, language: ES\|EN\|PT, engine: nim\|ollama, rcntr, period?}` |
| `frontend` | net, edge | 3000 | única entrada; proxy `/api/*` → backend; selector por área, KPIs, gráfico real + presupuesto + plan, matriz P × Q expandible, chat IA; UI ES/EN/PT |
| `ui-test` | edge | — | perfil `qa`: Playwright contra el frontend (`make ui-test`) |

Proyecto compose `nodara-rollingf`: contenedores y redes `rollingf-*`, imágenes `nodara-rollingf/*`. Convive con
`nodara-br-rag` (mismos puertos: no corren a la vez).

## Convenciones

- **Idiomas**: código y comentarios en inglés; documentación en español; bitácoras originales en español; UI y
  respuestas del LLM en el idioma elegido (ES/EN/PT, por defecto ES).
- **SAP**: tablas y campos SAP originales en minúsculas (cliente `100`, esquema `sap`) según las fichas de tabla
  entregadas por el Arquitecto. `ACDOCP` no tiene `RVERS`: la versión del plan es `CATEGORY` (plan category): `BUDG`
  presupuesto base, la referencia de la desviación, y `RF18M` rolling forecast. Su clave es `REQTSN/DATAPAKID/RECORD`.
  `FINSSKF` (valores vigentes) se identifica por `STAGR/RECID/DATE_FROM`, con `RRCTY` (0 real, 1 plan) y `CATEGORY`;
  `RECID` es el MD5 de RRCTY + CATEGORY + RBUKRS + RCNTR + STAGR (un ítem por centro de costo e impulsor). Un dato nuevo
  va en la tabla SAP real que lo contiene, nunca en columnas inventadas.
  - **P × Q** con los campos de las fichas, sin `RUOM` ni `MSL`/`RUNIT` en ACDOCP:
    - ACDOCA lleva `MSL`/`RUNIT`;
    - ACDOCP lleva `VMSL`/`RVUNIT`, el precio `KPRICE` y la parte fija `KFSL`/`VMFSL`, con `KSL = KPRICE × VMSL`;
    - la vista gold los expone como `msl`/`ruom`.
  - `RACCT` usa los IDs simbólicos del Arquitecto (`RACCT_ACEROS`…, `varchar(20)`).
  - ACDOCA debe quedar cuadrado por `belnr` (Σ `wsl` = Σ `hsl` = Σ `ksl` = 0). `BLART`: WA bodega (semanal), WE
    servicio, SA nómina, AF depreciación.
  - Datos maestros fuera de alcance solo en `backend/app/masterdata.py`: textos (SKAT, CSKT, TKA03, unidades,
    categorías), área de cada centro, impulsor del OPEX unitario (`UNIT_DRIVERS`) y decimales de presentación.
- **La IA no calcula**: toda cifra se calcula en SQL de Trino (`backend/app/lakehouse.py`). Eso incluye:
  - costo, cantidad, precio y consumo específico por RCNTR × RACCT;
  - efectos P/Q/volumen/gasto y el ranking de efectos;
  - OPEX unitario y plan.

  El cálculo corre sobre las vistas gold `lakehouse.gold.vw_opex_c1_pxq` (master: una fila por versión, mes, RCNTR y
  RACCT; nunca suma unidades distintas) y `vw_opex_c1_pxq_variance` (presupuesto flexible con `KFSL`/`VMFSL`). El
  backend las publica en su primer análisis. Toda división usa `nullif` (un impulsor en 0 da NULL). Python y la UI
  solo formatean. Trino inlinea
  los CTE en cada referencia: leer cada tabla silver pocas veces (límite de 150 stages). El control de cifras
  (`backend/app/figures.py`) reporta todo número de la respuesta que no venga de Trino, de las bitácoras o de la pregunta.
- **Base de conocimiento**: bitácoras de justificación en `knowledge/raw-docs/<origen>/<doc_id>.md` (orígenes `mina`,
  `concentradora` y `puerto`; `doc_type` `maintenance_log` u `operations_log`; varias secciones), con `gjahr`, `monat` y `rcntr`
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
- **Gráficos**: forma de énfasis: la cuenta de origen de la desviación (primer efecto del ranking de Trino) va en
  acento si su sobrecosto vs. `BUDG` es material (≥ 5 %) y el resto en gris; sin acento si no hay cuenta de origen.
  Un solo eje por medida (nunca doble eje): OPEX o el OPEX unitario del impulsor del centro (USD/m, USD/t, USD/m³,
  USD/WMT). La matriz P × Q se despliega por centro de costo con un botón real (`aria-expanded`) y desplaza su tabla
  dentro del panel. El presupuesto se dibuja como un tick de referencia neutro con
  halo de superficie. Tooltip por columna con teclado y vista de tabla. Colores validados con el validador de dataviz
  sobre la superficie `#0f172a`. Sin scroll horizontal en móvil: un `<select>` toma el ancho de su opción más larga,
  así que va con `w-full`.
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
3. `make smoke` → **0 fallos**. Primero re-siembra (`make fresh`, borra los datos). Incluye:
   - el modelo financiero con los campos P × Q reales y los 12 centros con sus 4 anomalías;
   - CDC → bronze → silver → gold (`vw_opex_c1_pxq`: una fila por RCNTR × RACCT, sin división por cero);
   - efectos P/Q/volumen/gasto y OPEX unitario idénticos en Trino y PostgreSQL;
   - la IA nombrando la cuenta y el efecto de origen en ES/EN/PT con NIM, más la contingencia Ollama, si los modelos
     están importados;
   - las trazas de Langfuse, el tiempo real y el egress.
4. Si se tocó el frontend: `make ui-test` en verde.
5. README, este archivo y `TECH_DEBT.md` actualizados.

## Comandos

`make env` · `make preflight` · `make config` · `make up` · `make ps` · `make logs s=<servicio>` · `make smoke` ·
`make demo` · `make fresh` · `make ui-test` · `make models` (o `make models from=<volumen>`, importación offline) ·
`make embed` · `make kb-seed` · `make simulate n=10` · `make reset-data` · `make down` · `make clean` (borra todos
los volúmenes, incluidos los modelos)

`./scripts/smoke-test.sh` sin reset sirve solo para diagnóstico: el simulador contabiliza diésel en ACDOCA.

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
- NVIDIA NIM:
  - `meta/llama-3.1-70b-instruct` y `meta/llama-3.3-70b-instruct` dan 410 (EOL; 3.3 desde el 2026-08-26).
  - `meta-llama/llama-3.3-70b-instruct` es nomenclatura de Hugging Face, no un ID de NVIDIA: da 404.
  - Los 70B listados para la cuenta (Nemotron 70B, Palmyra Fin 70B), Nemotron 51B y Ultra 253B dan 404 *Not found
    for account*; Llama 3.2 90B Vision no respondió en 90 s.
  - Un modelo listado en `/v1/models` puede igual no responder: probarlo con una llamada real (se volvió a probar en
    la release de producción: sigue sin Llama 3.3 70B).
- gpt-oss en NIM separa los miles con espacio fino (`4 207 000`): el control de cifras lo admite.
- `Intl.NumberFormat("es")` no agrupa los números de 4 cifras: la UI muestra `7640 h` y el LLM recibe `7.640 h`.
- Trino: `format('%.2f', NULL)` devuelve `"nu"` (Java aplica la precisión al texto "null"), no NULL; usar
  `if(x IS NULL, …)`. Las vistas gold no existen hasta el primer análisis del backend (lo dispara cualquier llamada a
  `/api/opex/*`).
- PostgreSQL resuelve `round(integer)` como `round(double precision)`: castear a `numeric` antes de `round(x, n)`.
- Las fichas de tabla del Arquitecto son PDF escaneados (imágenes): para leerlas, renderizar las páginas a PNG
  (`pdftoppm` en un contenedor `alpine` desechable) y abrirlas como imagen.
- Langfuse 2.x (Next.js) escucha en la IP del contenedor salvo con `HOSTNAME=0.0.0.0` (sin eso, el healthcheck falla).
- `ChatNVIDIA` no tiene timeout de red: el límite `NIM_TIMEOUT_S` lo aplica `backend/app/llm.py` con un hilo por intento.
- Copiar el proyecto con el Explorador de Windows deja archivos `*:Zone.Identifier` (están en `.gitignore`).
