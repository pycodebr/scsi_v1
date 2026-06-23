# Prompt — Implementar stack de Monitoramento, Observabilidade e Logs

> **Como usar:** abra o repositório-alvo no seu agente de IA (Claude Code,
> Cursor, etc.) e cole o conteúdo a partir de `<prompt>` até `</prompt>`. O
> prompt é **agnóstico de projeto**: ele descobre os nomes reais (stack, serviço
> do app, domínio, porta) lendo os arquivos existentes. Os trechos de código são
> **implementações de referência** — o agente deve adaptá-los aos nomes reais do
> repositório, não copiá-los cegamente.
>
> Stack-alvo esperada: **Django + gunicorn + Docker Swarm + Traefik (TLS
> Let's Encrypt) + registry (GHCR)**, configuração via `.env`.

---

<prompt>

<role>
Você é um(a) engenheiro(a) Django sênior especialista em DevOps e
observabilidade: Docker Swarm, Traefik, Prometheus, Grafana, Loki, Promtail,
node-exporter e cAdvisor. Você implementa mudanças de produção com disciplina:
instrumentação com degradação graciosa, stacks isoladas, service discovery por
DNS e zero downtime no que já está no ar. Você escreve scripts de shell
didáticos e idempotentes, e documenta com diagramas.
</role>

<context>
O repositório-alvo é uma aplicação web JÁ EM PRODUÇÃO, com esta stack:
- Django servido por gunicorn (porta tipicamente 8000), com health em `/health/`.
- Docker Swarm como orquestrador; existe um `docker-stack.yml` na raiz.
- Traefik como reverse proxy, TLS via Let's Encrypt (DNS-01), com a rede overlay
  externa `traefik_public`.
- Imagens publicadas em um registry (ex.: GHCR).
- Configuração lida de um `.env` na raiz (via `django-environ` ou equivalente).
- Scripts em `scripts/`: um `setup_deploy.sh` (guia didático de deploy, passo a
  passo) e um `deploy.sh` (build/push/redeploy).
- Não há, ainda, monitoramento/observabilidade.
</context>

<objective>
Adicionar uma stack COMPLETA de monitoramento, observabilidade e logs e
instrumentar o Django. Ao final, o operador deve conseguir:
- ver métricas de aplicação (latência, throughput, erros) e de infra (CPU, RAM,
  disco, containers) em dashboards do Grafana;
- pesquisar logs de todos os containers em um lugar só (Loki);
- receber alertas quando algo sair do esperado.
Tudo isso SEM tocar no deploy da aplicação e em uma stack Swarm SEPARADA.
</objective>

<hard_constraints>
Regras MANDATÓRIAS. Violá-las invalida a entrega.
1. NÃO interferir no deploy de produção existente. A instrumentação do Django
   DEVE ser GUARDADA por import (`try/except ImportError`): sem a lib, é no-op e
   o app sobe normalmente.
2. A stack DEVE ser um ÚNICO arquivo na raiz: `monitoring-stack.yml`, publicado
   como stack Swarm SEPARADA chamada `monitoring`.
3. O `monitoring-stack.yml` DEVE ser GENÉRICO (template). Todo valor específico
   do projeto (domínio do Grafana, credenciais, retenção, caminho dos configs)
   DEVE vir do `.env`, interpolado pelo `docker stack deploy`. PROIBIDO hardcode
   de credenciais.
4. Deploys do app e da monitoria DEVEM ser independentes: um NÃO PODE exigir
   redeploy do outro.
5. O endpoint `/metrics` NÃO DEVE ser exposto pelo Traefik. O Prometheus coleta
   internamente, via DNS do Swarm (`tasks.<stack>_<app>:<porta>`).
6. NÃO modifique o `docker-stack.yml` da aplicação. Métricas do Traefik, se
   desejadas, ficam como bloco COMENTADO no `prometheus.yml` (opt-in).
7. Preserve estilo, idioma das mensagens e helpers dos scripts existentes.
8. Em scripts, NUNCA use `source .env` nem `export $(cat .env)`. Faça parsing
   linha a linha (valores podem conter `$ & * espaços`).
</hard_constraints>

<discovery_first>
ANTES de escrever qualquer arquivo, INSPECIONE o repositório e extraia os nomes
REAIS. Rode/leia, por exemplo:

```bash
# nome da stack e do serviço do app, porta, rede do Traefik
grep -nE "stack deploy|STACK_NAME|traefik_public|server.port|:8000" docker-stack.yml scripts/*.sh
# como o settings lê o .env, e blocos relevantes
grep -nE "environ|decouple|INSTALLED_APPS|MIDDLEWARE|DATABASES|LOGGING" -r <pacote_django>/settings*.py
# estilo dos scripts (helpers, cores, parser de .env, tratamento de erro)
sed -n '1,120p' scripts/setup_deploy.sh
# docs e índice/nav (mkdocs?)
ls docs/ 2>/dev/null; sed -n '1,80p' mkdocs.yml 2>/dev/null
```

Defina e ANOTE estas variáveis de descoberta (usadas no restante da entrega):
- `STACK` = nome da stack do app (ex.: `myproject`)
- `APP_SERVICE` = serviço web (geralmente `app`) → alvo `tasks.${STACK}_app`
- `APP_PORT` = porta do gunicorn (geralmente `8000`)
- `DJANGO_PKG` = pacote com `settings.py`/`urls.py` (ex.: `core`)
- `NAMESPACE` = nome curto do projeto (usado só para nomear arquivos/dashboards,
  ex.: `<NAMESPACE>-overview.json` — NÃO é prefixo de métrica; o django-prometheus
  publica `django_http_...` sem prefixo)
NUNCA presuma esses nomes — confirme no código.
</discovery_first>

<reference_architecture>
Como as peças conversam (entregue isto também no doc, em Mermaid):

- Duas redes overlay:
  - `traefik_public` (JÁ existe): o Traefik publica o Grafana E o Prometheus
    alcança o `/metrics` do app por aqui (ambos estão nesta rede).
  - `monitoring` (criada pelos scripts): rede privada onde Prometheus, Grafana,
    Loki, Promtail, node-exporter e cAdvisor se falam.
- Métricas (pull): Prometheus faz scrape de `tasks.${STACK}_app:${APP_PORT}/metrics`
  a cada 30s e grava no TSDB (retenção do `.env`). Grafana consulta o Prometheus
  via PromQL.
- Logs (push): Promtail (1 por nó) lê o stdout dos containers via socket do
  Docker, adiciona labels (`stack`, `service`, `container`) e dá push no Loki.
  Grafana consulta o Loki via LogQL.
- Service discovery por DNS: `tasks.<serviço>` resolve para TODAS as réplicas
  (registros A). Ao escalar o app, o Prometheus coleta todas automaticamente.
</reference_architecture>

<deliverables>
Produza EXATAMENTE os itens abaixo. Os blocos de código são REFERÊNCIA — adapte
aos nomes reais (`${STACK}`, `${APP_PORT}`, `${DJANGO_PKG}`, `${NAMESPACE}`).

### 1. Instrumentação do Django

**`${DJANGO_PKG}/settings.py`** — adicione ao FINAL do arquivo:

```python
# ── Observabilidade / Métricas — django-prometheus (stack OPCIONAL) ──
# Só ATIVA se a lib estiver instalada. Sem ela vira no-op: o app sobe igual e
# adicionar a monitoria NÃO interfere no deploy de produção (degradação graciosa).
try:
    import django_prometheus  # noqa: F401
    PROMETHEUS_ENABLED = True
except ImportError:
    PROMETHEUS_ENABLED = False

if PROMETHEUS_ENABLED:
    # IMPORTANTE: o django-prometheus NÃO prefixa as métricas com namespace — elas
    # saem como `django_http_...` (sem prefixo). Não configure um namespace e use
    # `django_http_...` direto nas queries/dashboards/alertas.
    # O Prometheus coleta /metrics pela rede interna do Swarm, conectando direto no IP
    # do container (ex.: 10.0.1.18) — logo o header Host é esse IP, fora do ALLOWED_HOSTS,
    # causando DisallowedHost (400) e deixando os painéis em "no data". Como /metrics não
    # é público (não passa pelo Traefik), o MetricsHostMiddleware (ver ${DJANGO_PKG}/middleware.py)
    # reescreve o Host só dessa rota. PRIMEIRO middleware, antes do SecurityMiddleware.
    if '${DJANGO_PKG}.middleware.MetricsHostMiddleware' not in MIDDLEWARE:
        MIDDLEWARE = ['${DJANGO_PKG}.middleware.MetricsHostMiddleware'] + MIDDLEWARE
    # ATENÇÃO (2º gotcha, além do Host): se a app roda atrás de proxy TLS com
    # SECURE_SSL_REDIRECT=True, o /metrics (scrape em HTTP na porta interna) leva
    # 301 -> https://.../metrics e o Prometheus falha na 443 dentro do container
    # ("connection refused" / alvo DOWN). Isente o /metrics do redirect JUNTO da
    # rota de healthcheck, no bloco de segurança (if not DEBUG):
    #     SECURE_REDIRECT_EXEMPT = [r'^health/$', r'^metrics$']
    if 'django_prometheus' not in INSTALLED_APPS:
        INSTALLED_APPS = INSTALLED_APPS + ['django_prometheus']
    # Before = PRIMEIRO middleware; After = ÚLTIMO. Medem o tempo TOTAL da request.
    if 'django_prometheus.middleware.PrometheusBeforeMiddleware' not in MIDDLEWARE:
        MIDDLEWARE = (
            ['django_prometheus.middleware.PrometheusBeforeMiddleware']
            + MIDDLEWARE
            + ['django_prometheus.middleware.PrometheusAfterMiddleware']
        )
    # Engine do banco -> versão instrumentada (mesma semântica + métricas de query).
    _PROMETHEUS_DB_ENGINE_MAP = {
        'django.db.backends.postgresql': 'django_prometheus.db.backends.postgresql',
        'django.db.backends.postgresql_psycopg2': 'django_prometheus.db.backends.postgresql',
        'django.db.backends.sqlite3': 'django_prometheus.db.backends.sqlite3',
        'django.db.backends.mysql': 'django_prometheus.db.backends.mysql',
    }
    for _db_config in DATABASES.values():
        _engine = _db_config.get('ENGINE', '')
        _db_config['ENGINE'] = _PROMETHEUS_DB_ENGINE_MAP.get(_engine, _engine)
```

**`${DJANGO_PKG}/middleware.py`** — crie (referenciado no bloco acima):

```python
class MetricsHostMiddleware:
    """Libera o scrape do /metrics sem afrouxar o ALLOWED_HOSTS das rotas públicas.

    O Prometheus coleta /metrics conectando direto no IP do container, então o header
    Host é esse IP (dinâmico, fora do ALLOWED_HOSTS) -> Django responde 400 DisallowedHost
    e nunca expõe as métricas. Como /metrics não é público (não passa pelo Traefik),
    reescrevemos o Host APENAS dessa rota para um valor permitido. PRIMEIRO middleware.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.path == '/metrics':
            request.META['HTTP_HOST'] = 'localhost'
        return self.get_response(request)
```

**`${DJANGO_PKG}/urls.py`** — importe `settings` e adicione ao final:

```python
from django.conf import settings
# ... urlpatterns existente ...
# /metrics só quando a instrumentação está ativa. Coletado pela rede interna do
# Swarm; NÃO roteado pelo Traefik (não fica público).
if getattr(settings, 'PROMETHEUS_ENABLED', False):
    urlpatterns += [path('', include('django_prometheus.urls'))]
```

**`requirements.txt`** — adicione (para Django 6+, use o fork `django-commons`,
pois o release do PyPI ainda não cobre; em Django ≤5, `django-prometheus==2.3.1`
do PyPI serve):

```
django-prometheus @ git+https://github.com/django-commons/django-prometheus.git@77a983e676ab85d2419ae4612852bf08837526e2
prometheus-client==0.24.1
```

### 2. `monitoring-stack.yml` (raiz) — stack genérica

Requisitos: redes externas `monitoring` e `traefik_public`; Grafana publicado via
labels do Traefik usando `${GRAFANA_DOMAIN}`; credenciais e retenção do `.env`;
`prometheus`/`grafana`/`loki` em 1 réplica no manager; `promtail`/`node-exporter`/
`cadvisor` em modo `global`. Referência (adapte imagens/limites):

```yaml
version: "3.9"

services:
  prometheus:
    image: prom/prometheus:v3.1.0
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-15d}"
      - "--web.enable-lifecycle"
    volumes:
      - prometheus_data:/prometheus
      - ${MONITORING_CONFIG_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${MONITORING_CONFIG_DIR}/prometheus/alert_rules.yml:/etc/prometheus/alert_rules.yml:ro
    networks: [monitoring, traefik_public]
    deploy:
      mode: replicated
      replicas: 1
      placement: { constraints: ["node.role == manager"] }
      resources: { limits: { cpus: "0.5", memory: 512M } }

  grafana:
    image: grafana/grafana:11.4.0
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_ADMIN_USER:-admin}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
      - GF_SERVER_ROOT_URL=https://${GRAFANA_DOMAIN}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_ANALYTICS_REPORTING_ENABLED=false
    volumes:
      - grafana_data:/var/lib/grafana
      - ${MONITORING_CONFIG_DIR}/grafana/provisioning:/etc/grafana/provisioning:ro
      - ${MONITORING_CONFIG_DIR}/grafana/dashboards:/var/lib/grafana/dashboards:ro
    networks: [monitoring, traefik_public]
    deploy:
      mode: replicated
      replicas: 1
      placement: { constraints: ["node.role == manager"] }
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.grafana.rule=Host(`${GRAFANA_DOMAIN}`)"
        - "traefik.http.routers.grafana.entrypoints=websecure"
        - "traefik.http.routers.grafana.tls=true"
        - "traefik.http.routers.grafana.tls.certresolver=letsencrypt"
        - "traefik.http.services.grafana.loadbalancer.server.port=3000"
      resources: { limits: { cpus: "0.3", memory: 256M } }

  loki:
    image: grafana/loki:3.3.2
    command: ["-config.file=/etc/loki/loki-config.yml", "-config.expand-env=true"]
    environment:
      - LOKI_RETENTION=${LOKI_RETENTION:-360h}
    volumes:
      - loki_data:/loki
      - ${MONITORING_CONFIG_DIR}/loki/loki-config.yml:/etc/loki/loki-config.yml:ro
    networks: [monitoring]
    deploy:
      mode: replicated
      replicas: 1
      placement: { constraints: ["node.role == manager"] }
      resources: { limits: { cpus: "0.3", memory: 256M } }

  promtail:
    image: grafana/promtail:3.3.2
    command: -config.file=/etc/promtail/promtail-config.yml
    volumes:
      - /var/log:/var/log:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${MONITORING_CONFIG_DIR}/promtail/promtail-config.yml:/etc/promtail/promtail-config.yml:ro
    networks: [monitoring]
    deploy: { mode: global, resources: { limits: { cpus: "0.15", memory: 128M } } }

  node-exporter:
    image: prom/node-exporter:v1.8.2
    command:
      - "--path.rootfs=/host"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)"
    volumes: [ "/:/host:ro,rslave" ]
    networks: [monitoring]
    deploy: { mode: global, resources: { limits: { cpus: "0.15", memory: 64M } } }

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    command: ["--docker_only=true", "--housekeeping_interval=30s"]
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    networks: [monitoring]
    deploy: { mode: global, resources: { limits: { cpus: "0.15", memory: 128M } } }

volumes: { prometheus_data: {}, grafana_data: {}, loki_data: {} }

networks:
  monitoring: { external: true }
  traefik_public: { external: true }
```

> ATENÇÃO ao `$$` em `node-exporter` (escape de `$` no stack deploy) e ao
> `-config.expand-env=true` no Loki (permite `${LOKI_RETENTION}` no config).

### 3. Configs em `monitoring/`

Estrutura final esperada:

```
monitoring/
├── prometheus/
│   ├── prometheus.yml
│   └── alert_rules.yml
├── loki/loki-config.yml
├── promtail/promtail-config.yml
└── grafana/
    ├── provisioning/
    │   ├── datasources/datasources.yml
    │   └── dashboards/dashboards.yml
    └── dashboards/<NAMESPACE>-overview.json
```

**`monitoring/prometheus/prometheus.yml`** (o ÚNICO valor de projeto é o alvo do
app — comente que é o único a trocar ao reusar):

```yaml
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels: { project: "${STACK}" }
rule_files: ["alert_rules.yml"]
scrape_configs:
  - job_name: "prometheus"
    static_configs: [ { targets: ["localhost:9090"] } ]
  - job_name: "node-exporter"
    dns_sd_configs: [ { names: ["tasks.node-exporter"], type: A, port: 9100 } ]
  - job_name: "cadvisor"
    dns_sd_configs: [ { names: ["tasks.cadvisor"], type: A, port: 8080 } ]
  - job_name: "django"
    metrics_path: "/metrics"
    dns_sd_configs: [ { names: ["tasks.${STACK}_app"], type: A, port: ${APP_PORT} } ]
  # Traefik (OPT-IN): exige ligar métricas no docker-stack.yml do app (mexe na
  # produção), por isso fica comentado:
  # - job_name: "traefik"
  #   static_configs: [ { targets: ["${STACK}_traefik:8080"] } ]
```

**`monitoring/prometheus/alert_rules.yml`** — NÃO rode envsubst aqui (`$labels`
é template do Prometheus):

```yaml
groups:
  - name: infra
    rules:
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels: { severity: critical }
        annotations: { summary: "Serviço {{ $labels.job }} fora do ar" }
      - alert: HighMemoryUsage
        expr: (container_memory_usage_bytes / container_spec_memory_limit_bytes) > 0.85
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "Container {{ $labels.name }} >85% de memória" }
      - alert: HighCPUUsage
        expr: rate(container_cpu_usage_seconds_total[5m]) > 0.8
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "Container {{ $labels.name }} >80% CPU" }
      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.15
        for: 5m
        labels: { severity: critical }
        annotations: { summary: "Disco com <15% livre" }
  - name: app
    rules:
      - alert: HighDjango5xxRate
        expr: |
          sum(rate(django_http_responses_total_by_status_total{status=~"5.."}[5m]))
          / sum(rate(django_http_responses_total_by_status_total[5m])) > 0.05
        for: 5m
        labels: { severity: critical }
        annotations: { summary: "Erros 5xx do Django acima de 5%" }
      - alert: HighDjangoLatencyP95
        expr: |
          histogram_quantile(0.95,
            sum(rate(django_http_requests_latency_seconds_by_view_method_bucket[5m])) by (le)) > 2
        for: 5m
        labels: { severity: warning }
        annotations: { summary: "Latência P95 do Django acima de 2s" }
```

**`monitoring/loki/loki-config.yml`** (single-binary, retenção via env):

```yaml
auth_enabled: false
server: { http_listen_port: 3100, grpc_listen_port: 9096, log_level: warn }
common:
  path_prefix: /loki
  storage: { filesystem: { chunks_directory: /loki/chunks, rules_directory: /loki/rules } }
  replication_factor: 1
  ring: { kvstore: { store: inmemory } }
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index: { prefix: index_, period: 24h }
limits_config:
  retention_period: ${LOKI_RETENTION}
  reject_old_samples: true
  reject_old_samples_max_age: 168h
compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
  compaction_interval: 10m
analytics: { reporting_enabled: false }
```

**`monitoring/promtail/promtail-config.yml`**:

```yaml
server: { http_listen_port: 9080, grpc_listen_port: 0 }
positions: { filename: /tmp/positions.yaml }
clients: [ { url: http://loki:3100/loki/api/v1/push } ]
scrape_configs:
  - job_name: docker
    docker_sd_configs: [ { host: unix:///var/run/docker.sock, refresh_interval: 5s } ]
    relabel_configs:
      - { source_labels: ['__meta_docker_container_name'], regex: '/(.*)', target_label: 'container' }
      - { source_labels: ['__meta_docker_container_log_stream'], target_label: 'logstream' }
      - { source_labels: ['__meta_docker_container_label_com_docker_swarm_service_name'], target_label: 'service' }
      - { source_labels: ['__meta_docker_container_label_com_docker_stack_namespace'], target_label: 'stack' }
```

**`monitoring/grafana/provisioning/datasources/datasources.yml`** (UIDs fixos para
o dashboard referenciar):

```yaml
apiVersion: 1
datasources:
  - { name: Prometheus, uid: prometheus, type: prometheus, access: proxy, url: http://prometheus:9090, isDefault: true, editable: false, jsonData: { httpMethod: POST, timeInterval: "30s" } }
  - { name: Loki, uid: loki, type: loki, access: proxy, url: http://loki:3100, editable: false }
```

**`monitoring/grafana/provisioning/dashboards/dashboards.yml`**:

```yaml
apiVersion: 1
providers:
  - name: "App Dashboards"
    orgId: 1
    folder: "${STACK}"
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options: { path: /var/lib/grafana/dashboards, foldersFromFilesStructure: false }
```

**`monitoring/grafana/dashboards/<NAMESPACE>-overview.json`** — dashboard próprio.
As métricas do Django chegam SEM prefixo (`django_http_...`), então use esses
nomes direto nas queries (sem variável de template de namespace). NÃO precisa colar
um JSON gigante: gere um dashboard com `schemaVersion: 39`, `uid` próprio,
datasources por uid (`prometheus`/`loki`) e os painéis abaixo (cada um com sua query):

| Painel | Tipo | Query |
|--------|------|-------|
| Alvos UP | stat | `count(up == 1)` |
| Taxa de erros 5xx (%) | stat | `100 * sum(rate(django_http_responses_total_by_status_total{status=~"5.."}[5m])) / clamp_min(sum(rate(django_http_responses_total_by_status_total[5m])),1)` |
| Throughput (req/s) | stat | `sum(rate(django_http_requests_total_by_method_total[5m]))` |
| Requisições por método | timeseries | `sum(rate(django_http_requests_total_by_method_total[5m])) by (method)` |
| Respostas por status | timeseries (stack) | `sum(rate(django_http_responses_total_by_status_total[5m])) by (status)` |
| Latência p50/p95/p99 | timeseries | `histogram_quantile(0.95, sum(rate(django_http_requests_latency_seconds_by_view_method_bucket[5m])) by (le))` (repita 0.50/0.99) |
| Memória por container | timeseries (bytes) | `sum(container_memory_usage_bytes{name=~".+"}) by (name)` |
| CPU por container | timeseries (percentunit) | `sum(rate(container_cpu_usage_seconds_total{name=~".+"}[5m])) by (name)` |
| Logs da aplicação | logs (datasource loki) | `{stack="${STACK}"} |= ``` |

Mantenha `"templating": { "list": [] }` — as métricas do Django não têm prefixo de
namespace, então as queries usam `django_http_...` diretamente e não há variável a
parametrizar.

### 4. Scripts em `scripts/` (MESMO estilo dos existentes)

**`scripts/setup_monitoring.sh`** — guia DIDÁTICO passo a passo. Reaproveite os
helpers do `setup_deploy.sh` (cores, `step`, `info/ok/warn`, `action_box`,
`pause_enter`, `trap ERR`, parser de `.env`). Fluxo OBRIGATÓRIO de passos:

1. Localizar a pasta do projeto (procurar `monitoring-stack.yml`).
2. Checar Docker + Swarm manager + rede `traefik_public` (se faltar, instruir a
   rodar o `setup_deploy.sh` primeiro e sair).
3. Ler o `DOMAIN` do `.env`.
4. Configurar no `.env`: `GRAFANA_DOMAIN` (default `grafana.<DOMAIN>`),
   `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD` (gerar forte se vazia).
5. Garantir defaults: `PROMETHEUS_RETENTION`, `LOKI_RETENTION`.
6. Orientar o registro DNS do subdomínio do Grafana (mostrar o IP público).
7. Criar a rede `monitoring` (idempotente).
8. Validar a presença de todos os configs; gravar `MONITORING_CONFIG_DIR` (path
   ABSOLUTO de `monitoring/`) no `.env`.
9. Explicar a ativação do `/metrics` (rodar `deploy.sh` quando puder).
10. Carregar o `.env` (parser seguro) e `docker stack deploy -c monitoring-stack.yml monitoring`.
11. Conferir os serviços (`docker service ls | grep monitoring_`).
12. Imprimir como acessar o Grafana, dashboards a importar e a query de logs.

Esqueleto de helpers (reuse os do projeto):

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ! -t 0 && -e /dev/tty ]]; then exec </dev/tty; fi
# cores + step()/info()/ok()/warn()/action_box()/pause_enter() + trap 'on_error ...' ERR
get_env_var() { grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2-; }
set_env_var() { local k="$1" v="$2" t; t="$(mktemp)"; [ -f .env ] && grep -v "^$k=" .env >"$t" || true; printf '%s=%s\n' "$k" "$v" >>"$t"; mv "$t" .env; chmod 600 .env; }
# parser seguro do .env (NÃO usar source):
load_env() { while IFS= read -r l || [ -n "$l" ]; do l="${l%$'\r'}"; case "$l" in ''|\#*) continue;; esac
  [ "${l#*=}" = "$l" ] && continue; k="${l%%=*}"; v="${l#*=}"
  case "$k" in ''|*[!A-Za-z0-9_]*) continue;; esac; export "$k=$v"; done < .env; }
```

**`scripts/deploy_monitoring.sh`** — equivalente ao `deploy.sh`, para a monitoria:

```bash
#!/bin/bash
set -euo pipefail
STACK_NAME="monitoring"; STACK_FILE="monitoring-stack.yml"
CLEAN=0; [ "${1:-}" = "--clean" ] && CLEAN=1
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO_DIR"
# 1) docker + swarm manager; 2) load_env (parser seguro, igual ao deploy.sh)
# 3) exigir GRAFANA_ADMIN_PASSWORD e GRAFANA_DOMAIN
export MONITORING_CONFIG_DIR="$REPO_DIR/monitoring"          # path ABSOLUTO
export PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
export LOKI_RETENTION="${LOKI_RETENTION:-360h}"
# 4) garantir rede 'monitoring'; exigir 'traefik_public'
docker network ls --format '{{.Name}}' | grep -qx monitoring || docker network create --driver overlay --attachable monitoring
[ "$CLEAN" = 1 ] && { docker stack rm "$STACK_NAME" || true; sleep 15; }   # volumes preservados
docker stack deploy -c "$STACK_FILE" "$STACK_NAME"
[ "$CLEAN" = 0 ] && for s in prometheus grafana loki promtail node-exporter cadvisor; do docker service update --force "${STACK_NAME}_${s}" >/dev/null 2>&1 || true; done
docker service ls --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" | grep -E "^NAME|^${STACK_NAME}_" || true
```

Torne ambos executáveis (`chmod +x`).

### 5. `.env.example` — nova seção "Monitoramento"

```bash
# --- Monitoramento (stack OPCIONAL: monitoring-stack.yml) ---
GRAFANA_DOMAIN=grafana.<DOMAIN>
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=troque-esta-senha-do-grafana
PROMETHEUS_RETENTION=15d
LOKI_RETENTION=360h                  # múltiplo de 24h (360h = 15 dias)
MONITORING_CONFIG_DIR=               # preenchido automaticamente pelos scripts
```

### 6. Documentação

Crie uma página em `docs/` (registre no `mkdocs.yml`/nav, se existir) cobrindo:
o que foi implementado e por quê; tabela de componentes; **diagramas Mermaid**
(arquitetura, fluxo de métricas em `sequenceDiagram`, fluxo de logs, sequência de
deploy em `flowchart`); tabela de alertas; SLIs/SLOs; casos de uso;
troubleshooting (inclua os DOIS gotchas do scrape de `/metrics`, ambos deixam os
painéis do app em "no data": (a) **400 + DisallowedHost** — scrape pelo IP interno
do container fora do `ALLOWED_HOSTS`, tratado pelo `MetricsHostMiddleware`; (b)
alvo **DOWN** com `301`/`connection refused na 443` — `SECURE_SSL_REDIRECT`
redireciona o `/metrics` (HTTP) p/ https, resolvido isentando a rota em
`SECURE_REDIRECT_EXEMPT = [r'^health/$', r'^metrics$']`); e a seção de dashboards
(item <dashboards>).
</deliverables>

<dashboards>
Explique no doc COMO funcionam os dashboards e recomende os da comunidade.

Modelo mental: o Grafana NÃO guarda dados — ele consulta o Prometheus (métricas,
PromQL) e o Loki (logs, LogQL) e desenha. Dashboard → painéis → query →
datasource → visualização. Três formas de obter um dashboard:
(1) construir na mão; (2) importar por ID de `grafana.com`; (3) provisionar como
código (JSON em disco) — esta é a usada aqui.

Importar por ID: Grafana → Dashboards → New → Import → cola o número → Load →
escolhe o datasource Prometheus → Import.

Recomendados (IDs verificados; INFRA funciona direto, pois usa nomes padrão):

| ID | Dashboard | Observação |
|----|-----------|-----------|
| 1860 | Node Exporter Full | host: CPU/RAM/disco/rede — funciona direto |
| 14282 | Cadvisor exporter | métricas por container — funciona direto |
| 21154 | Docker overview (cAdvisor 2024) | cAdvisor + node — funciona direto |
| 13496 | Docker and system monitoring | alternativa enxuta |
| 9528 / 17658 | Django (django-prometheus) | funciona direto (`django_http_*`) |

NOME das métricas do Django (explique sempre): o django-prometheus publica as
métricas SEM prefixo de namespace — elas chegam como `django_http_...`. Por isso
o dashboard próprio e os dashboards de Django da comunidade (9528, 17658) usam
esses nomes direto, sem ajuste de prefixo. Se algum painel vier VAZIO, confira se
a query não tem um prefixo indevido (ex.: `${NAMESPACE}_django_http_...`) — o
correto é `django_http_...`.
</dashboards>

<implementation_rules>
- Guarda de import é OBRIGATÓRIA (constraint 1).
- `PrometheusBeforeMiddleware` = primeiro; `PrometheusAfterMiddleware` = último.
- O serviço `prometheus` participa de `monitoring` E `traefik_public` (para
  alcançar o `/metrics` do app, que está em `traefik_public`).
- Service discovery por DNS (`tasks.<serviço>`), nunca IPs fixos.
- `MONITORING_CONFIG_DIR` SEMPRE derivado do repo (path absoluto), exportado
  antes do `docker stack deploy`.
- Limites de recursos modestos por serviço (cabe em 1 VPS).
- Não crie `.env` novo; só ANEXE a seção de monitoramento ao `.env.example` e
  grave chaves no `.env` via `set_env_var` idempotente.
</implementation_rules>

<anti_patterns>
NÃO faça: expor `/metrics` via Traefik; senha do Grafana hardcoded no stack;
mesclar a monitoria no `docker-stack.yml`; `envsubst` no `alert_rules.yml`
(corrompe `$labels`); exigir rebuild do app para subir a monitoria; usar
`source .env`/`export $(cat .env)`; assumir nomes sem confirmar no código.
</anti_patterns>

<verification>
Antes de concluir, VALIDE e relate cada item com PASS/FAIL:

```bash
# 1. Sintaxe dos scripts
bash -n scripts/setup_monitoring.sh && bash -n scripts/deploy_monitoring.sh
# 2. YAML de stack + configs
python3 -c "import yaml,glob; [list(yaml.safe_load_all(open(f))) for f in ['monitoring-stack.yml',*glob.glob('monitoring/**/*.yml',recursive=True)]]; print('yaml ok')"
# 3. JSON do dashboard
python3 -c "import json,glob; [json.load(open(f)) for f in glob.glob('monitoring/grafana/dashboards/*.json')]; print('json ok')"
# 4. PROVA de não-interferência: settings carrega SEM a lib e não muda nada
python3 -c "import os,django; os.environ['DJANGO_SETTINGS_MODULE']='${DJANGO_PKG}.settings'; os.environ.setdefault('DEBUG','True'); django.setup(); from django.conf import settings as s; assert s.PROMETHEUS_ENABLED is False; assert 'django_prometheus' not in s.INSTALLED_APPS; print('no-interference ok')"
```
</verification>

<tips>
- O alvo `django` fica DOWN no Prometheus até o app subir com a lib — isso é
  ESPERADO e não afeta o site. Ative com um `deploy.sh` do app quando puder.
- Sem logs no Loki? Veja `docker service logs monitoring_promtail` (acesso ao
  socket do Docker) e confirme o label `stack` nas linhas.
- Grafana fora do ar logo após subir? DNS propagando / TLS validando (1–2 min).
- Para notificações ativas (e-mail/Slack/Telegram), pluge um Alertmanager — a
  stack enxuta só avalia as regras (aba Alerts do Prometheus).
- Loki exige retenção em horas múltiplas de 24h (`360h` = 15 dias).
- Quer métricas de negócio? Use `prometheus_client` (`Counter`, `Histogram`,
  `Gauge`) no código e elas aparecem no mesmo `/metrics`.
</tips>

<output_format>
1. Resumo (até 5 linhas) do que foi implementado.
2. Lista de arquivos criados/alterados, com caminho.
3. Resultado das verificações (<verification>) com PASS/FAIL.
4. Instruções finais: como subir a monitoria e acessar o Grafana.
Implemente DE FATO os arquivos no repositório — não entregue só explicação.
</output_format>

</prompt>
