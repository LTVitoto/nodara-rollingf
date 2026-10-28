# Nodara Rolling Forecast · atajos operativos (Docker Compose v2)
SHELL := /bin/bash
-include .env
export

COMPOSE ?= docker compose
PROJECT := nodara-rollingf
FRONTEND_PORT ?= 3000
LANGFUSE_PORT ?= 3001
n ?= 5

.DEFAULT_GOAL := help
.PHONY: help env preflight config up down ps logs models embed kb-seed simulate fresh smoke demo ui-test reset-data clean
DATA_VOLUMES := s4hana-data vector-data kafka-data minio-data unity-catalog-db
RESET_LOG := .reset.log

help: ## Lista los comandos disponibles
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

env: ## Crea .env desde .env.example con secretos aleatorios (no sobrescribe)
	@./scripts/init-env.sh

preflight: ## Detecta colisiones de puertos en el host (Linux/WSL + Windows)
	@./scripts/preflight.sh

config: ## Valida la sintaxis y la interpolación del docker-compose
	@$(COMPOSE) config --quiet && echo "docker-compose válido"

up: env preflight ## Construye y levanta el stack completo (espera a que esté healthy)
	$(COMPOSE) up -d --build
	@./scripts/wait-healthy.sh

down: ## Detiene el stack (conserva los volúmenes)
	$(COMPOSE) down

ps: ## Estado y salud de los contenedores
	@$(COMPOSE) ps -a --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'

logs: ## Sigue logs (ej.: make logs s=delta-sink)
	$(COMPOSE) logs -f --tail=100 $(s)

# Única vía de entrada de modelos al enclave: uplink controlado o, con from=<volumen Docker local>,
# copia offline desde otro enclave (sneakernet), p. ej. make models from=nodara-br-rag_ollama-models
models: ## Importa LLM + embeddings vía uplink controlado (o offline: make models from=<volumen>)
ifdef from
	$(COMPOSE) --profile bootstrap run --rm --no-deps -v $(from):/import:ro --entrypoint sh ollama-bootstrap \
	  -c 'cp -a /import/. /root/.ollama/ && ls /root/.ollama/models/manifests/registry.ollama.ai/library'
else
	$(COMPOSE) --profile bootstrap run --rm ollama-bootstrap
endif

embed: ## Indexa las bitácoras en pgvector con embeddings locales
	@curl -fsS -X POST http://127.0.0.1:$(FRONTEND_PORT)/api/kb/embed && echo

kb-seed: ## Regenera el seed de pgvector desde knowledge/raw-docs (Año, Mes y RCNTR obligatorios)
	@python3 scripts/build-kb-seed.py

simulate: ## Contabiliza consumos de repuestos CAEX en S/4 para ver el CDC (ej.: make simulate n=10)
	@$(COMPOSE) exec -T s4hana-db psql -U "$(S4_DB_ADMIN_USER)" -d s4hana -c "SELECT * FROM sap.simulate_activity($(n));"

# Idempotencia: smoke y demo parten siempre del seed (el simulador y las pruebas contabilizan en ACDOCA).
# Las trazas de Langfuse y los modelos de Ollama sobreviven al reset.
fresh: ## Re-siembra en silencio (reset-data → up → embed); detalle en .reset.log
	@printf 'Re-sembrando datos desde cero (reset-data → up → embed · log: %s)… ' "$(RESET_LOG)"
	@start=$$(date +%s); \
	{ $(MAKE) --no-print-directory reset-data && $(MAKE) --no-print-directory up && \
	  { $(MAKE) --no-print-directory embed || echo "embed omitido: modelos sin importar (make models)"; }; } >$(RESET_LOG) 2>&1 \
	  && echo "listo en $$(( $$(date +%s) - start )) s" \
	  || { echo "FALLÓ"; tail -n 30 $(RESET_LOG); exit 1; }

smoke: fresh ## QA E2E sobre datos recién sembrados: salud, CDC→Delta→silver, Trino, raw, KB, IA, Langfuse y egress
	@./scripts/smoke-test.sh

demo: fresh ## Stack recién sembrado para una demo (caso CAEX en su estado inicial)
	@echo "Consola del Gerente de Finanzas: http://localhost:$(FRONTEND_PORT) · Trazas (Langfuse): http://localhost:$(LANGFUSE_PORT)"

ui-test: ## QA UI: idioma ES/EN/PT, centro de costo, gráfico real + plan, chat y motor NIM/Ollama (Playwright, perfil qa)
	$(COMPOSE) --profile qa run --rm --build --no-deps ui-test

reset-data: ## Re-siembra desde cero: borra los volúmenes de datos de ESTE proyecto (conserva modelos Ollama)
	$(COMPOSE) down --remove-orphans
	-docker volume rm $(addprefix $(PROJECT)_,$(DATA_VOLUMES))

clean: ## Detiene y BORRA todos los volúmenes, incluidos los modelos (reset total)
	$(COMPOSE) down -v --remove-orphans
