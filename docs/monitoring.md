# Monitoramento, Observabilidade e Logs

Este guia documenta **tudo** que foi implementado para dar visibilidade à
aplicação SCSI em produção: o que sobe, por que sobe, como as peças conversam,
os fluxos de uso e como operar no dia a dia.

A stack de monitoramento é **opcional e totalmente separada** da aplicação. Ela
roda em uma stack Swarm própria (`monitoring`), pode ser publicada **depois** do
deploy do sistema e **não interfere** no que já está no ar.

---

## 1. Visão geral

Observabilidade se apoia em três pilares. A stack cobre os três:

| Pilar | Pergunta que responde | Ferramenta |
|-------|-----------------------|------------|
| **Métricas** | Quanto? Quão rápido? Com que frequência? | Prometheus + exporters |
| **Logs** | O que aconteceu, em que ordem, com que contexto? | Loki + Promtail |
| **Visualização** | Como eu vejo tudo isso junto? | Grafana |

### Componentes

| Serviço | Imagem | Função | Modo no Swarm |
|---------|--------|--------|---------------|
| **Prometheus** | `prom/prometheus` | Coleta e armazena métricas (TSDB) | 1 réplica (manager) |
| **Grafana** | `grafana/grafana` | Dashboards e visualização (via Traefik) | 1 réplica (manager) |
| **Loki** | `grafana/loki` | Banco de logs (agregação) | 1 réplica (manager) |
| **Promtail** | `grafana/promtail` | Lê os logs dos containers e envia ao Loki | global (1 por nó) |
| **node-exporter** | `prom/node-exporter` | Métricas do host (CPU, RAM, disco, rede) | global (1 por nó) |
| **cAdvisor** | `cadvisor` | Métricas por container | global (1 por nó) |
| **grafana-mcp** | `grafana/mcp-grafana` | Servidor MCP do Grafana p/ clientes de IA (via Traefik + Basic Auth) | 1 réplica (manager) |

Do lado do Django, a biblioteca **`django-prometheus`** instrumenta o app e
expõe um endpoint `/metrics` que o Prometheus coleta.

O **servidor MCP do Grafana** (`grafana-mcp`) é a peça mais recente: expõe as
ferramentas do Grafana (dashboards, datasources, consultas a Prometheus/Loki,
alertas, incidentes…) por **MCP** para clientes de IA (Claude, Cursor, VS Code).
Detalhes na [seção 12](#12-servidor-mcp-do-grafana).

---

## 2. Arquitetura

```mermaid
flowchart TB
    subgraph internet[Internet]
        user[Operador / Navegador]
    end

    subgraph swarm[VPS — Docker Swarm]
        direction TB
        traefik[Traefik<br/>proxy + TLS]

        subgraph appstack[stack: scsi_v1]
            app[Django app<br/>gunicorn :8000<br/>/metrics]
            db[(PostgreSQL)]
            worker[Celery worker/beat]
            redis[(Redis)]
            rabbit[(RabbitMQ)]
        end

        subgraph monstack[stack: monitoring]
            prom[Prometheus :9090]
            graf[Grafana :3000]
            mcp[grafana-mcp :8000<br/>/mcp]
            loki[Loki :3100]
            promtail[Promtail]
            node[node-exporter :9100]
            cadvisor[cAdvisor :8080]
        end
    end

    aiclient[Cliente de IA<br/>Claude / Cursor / VS Code]

    user -->|https://scsi.digital| traefik --> app
    user -->|https://grafana.scsi.digital| traefik --> graf
    aiclient -->|https://mcp.scsi.digital/mcp<br/>Basic Auth| traefik --> mcp
    mcp -->|service account token| graf

    prom -->|scrape /metrics| app
    prom -->|scrape| node
    prom -->|scrape| cadvisor
    promtail -->|push logs| loki
    promtail -.lê logs dos containers.-> app

    graf -->|consulta métricas| prom
    graf -->|consulta logs| loki

    classDef mon fill:#1f6feb22,stroke:#1f6feb;
    classDef app fill:#2da44e22,stroke:#2da44e;
    class prom,graf,mcp,loki,promtail,node,cadvisor mon;
    class app,db,worker,redis,rabbit app;
```

### Redes (overlay)

```mermaid
flowchart LR
    subgraph traefik_public[rede: traefik_public]
        T[Traefik]
        A[scsi_v1_app]
        G[monitoring_grafana]
        P[monitoring_prometheus]
    end
    subgraph monitoring[rede: monitoring]
        P2[prometheus]
        G2[grafana]
        L[loki]
        PT[promtail]
        N[node-exporter]
        C[cadvisor]
    end
    P -. coleta tasks.scsi_v1_app:8000 .-> A
    T --> G
```

Duas redes overlay conectam tudo:

- **`traefik_public`** (já existe, criada no deploy do app): permite que o
  Traefik publique o Grafana **e** que o Prometheus alcance o `/metrics` do app
  (ambos estão nessa rede). É o ponto de contato controlado entre as duas stacks.
- **`monitoring`** (criada pelos scripts de monitoria): rede privada onde
  Prometheus, Grafana, Loki, Promtail, node-exporter e cAdvisor conversam.

!!! note "Por que o `/metrics` não fica exposto na internet"
    O endpoint `/metrics` do Django **não** é roteado pelo Traefik. O Prometheus
    o acessa **internamente** pela rede `traefik_public` via DNS do Swarm
    (`tasks.scsi_v1_app:8000`). De fora, `https://scsi.digital/metrics` não é
    publicado por nenhuma regra do Traefik.

---

## 3. Como as métricas chegam ao Grafana (fluxo de métricas)

```mermaid
sequenceDiagram
    participant App as Django (/metrics)
    participant Prom as Prometheus
    participant Graf as Grafana
    participant Op as Operador

    loop a cada 30s
        Prom->>App: GET /metrics (rede interna)
        App-->>Prom: contadores, histogramas, gauges
        Prom->>Prom: grava no TSDB (retenção 15d)
    end
    Op->>Graf: abre dashboard
    Graf->>Prom: PromQL (ex.: rate(...5m))
    Prom-->>Graf: séries temporais
    Graf-->>Op: gráficos
```

**Descoberta de alvos (service discovery).** O Prometheus usa DNS interno do
Swarm. `tasks.<serviço>` resolve para os IPs de **todas** as réplicas daquele
serviço (registros A). Assim, ao escalar o app para N réplicas, o Prometheus
passa a coletar as N automaticamente — sem editar config.

Configurado em `monitoring/prometheus/prometheus.yml`:

```yaml
- job_name: "django"
  metrics_path: "/metrics"
  dns_sd_configs:
    - names: ["tasks.scsi_v1_app"]
      type: A
      port: 8000
```

O que o `django-prometheus` entrega de graça: histograma de latência por
view/método, contadores de requests por status/método, métricas de queries e
conexões do banco, cache, migrations e modelos. Os nomes **não** têm prefixo de
namespace — o `django-prometheus` publica as métricas como `django_http_...`,
ex.: `django_http_requests_latency_seconds_by_view_method_bucket`.

---

## 4. Como os logs chegam ao Grafana (fluxo de logs)

```mermaid
sequenceDiagram
    participant C as Containers (stdout/stderr)
    participant PT as Promtail (1 por nó)
    participant L as Loki
    participant Graf as Grafana

    C-->>PT: arquivos de log do Docker
    PT->>PT: adiciona labels (stack, service, container)
    PT->>L: push /loki/api/v1/push
    Graf->>L: LogQL (ex.: {stack="scsi_v1"})
    L-->>Graf: linhas de log
```

O Promtail descobre os containers pelo socket do Docker e lê o que cada um
escreve em **stdout/stderr** (o jeito idiomático em containers — o Django já
loga no console). Ele enriquece cada linha com labels úteis e envia ao Loki:

- `stack` — ex.: `scsi_v1`, `monitoring`
- `service` — ex.: `scsi_v1_app`, `scsi_v1_celery_worker`
- `container`, `logstream` (stdout/stderr)

No Grafana (Explore → Loki) você filtra, por exemplo:

```logql
{stack="scsi_v1", service="scsi_v1_app"} |= "ERROR"
```

!!! tip "Nenhuma mudança de código para logar"
    Como o Promtail coleta o **stdout** dos containers, qualquer `print`/`logger`
    que já vai para o console é capturado automaticamente. O `LOGGING` do
    `core/settings.py` já usa `StreamHandler` (console) — logo, está pronto.

---

## 5. O que foi implementado (passo a passo)

### 5.1 Instrumentação do Django (`core/settings.py`)

Bloco **guardado por import** no fim do arquivo: a instrumentação só liga se a
lib `django_prometheus` estiver instalada. Sem ela, vira um *no-op* — o app sobe
normalmente. **É isso que garante que adicionar monitoria não quebra o deploy
existente.**

```python
try:
    import django_prometheus  # noqa: F401
    PROMETHEUS_ENABLED = True
except ImportError:
    PROMETHEUS_ENABLED = False

if PROMETHEUS_ENABLED:
    INSTALLED_APPS += ['django_prometheus']
    MIDDLEWARE = (['...PrometheusBeforeMiddleware'] + MIDDLEWARE + ['...PrometheusAfterMiddleware'])
    # engine do banco trocada pela versão instrumentada
```

- `PrometheusBeforeMiddleware` precisa ser o **primeiro** e `PrometheusAfter…`
  o **último** — assim medem o tempo total da request, incluindo os demais
  middlewares.
- A **engine do banco** é trocada pela versão instrumentada do django-prometheus
  (mesma semântica, com métricas de query).

### 5.2 Endpoint `/metrics` (`core/urls.py`)

```python
if getattr(settings, 'PROMETHEUS_ENABLED', False):
    urlpatterns += [path('', include('django_prometheus.urls'))]
```

Só registra a rota quando a instrumentação está ativa.

### 5.3 Dependências (`requirements.txt`)

```
django-prometheus @ git+https://github.com/django-commons/django-prometheus.git@77a983e676ab85d2419ae4612852bf08837526e2
prometheus-client==0.24.1
```

Usamos o fork `django-commons` por compatibilidade com **Django 6** (o release
do PyPI ainda não cobre).

### 5.4 Arquivos da stack de monitoria

```
monitoring-stack.yml                      # a stack (genérica, lê variáveis do .env)
monitoring/
├── prometheus/
│   ├── prometheus.yml                     # alvos de scrape (1 valor do projeto)
│   └── alert_rules.yml                    # alertas (infra + app)
├── loki/
│   └── loki-config.yml                    # Loki single-binary + retenção
├── promtail/
│   └── promtail-config.yml                # descoberta de containers + labels
└── grafana/
    ├── provisioning/
    │   ├── datasources/datasources.yml    # Prometheus + Loki conectados
    │   └── dashboards/dashboards.yml      # auto-import de dashboards
    └── dashboards/
        └── scsi-overview.json             # dashboard pronto (app + infra + logs)
```

### 5.5 Scripts

| Script | Papel | Equivalente do app |
|--------|-------|--------------------|
| `scripts/setup_monitoring.sh` | Guia **passo a passo** para subir a monitoria (1ª vez) | `setup_deploy.sh` |
| `scripts/deploy_monitoring.sh` | `git pull` + refaz o deploy da monitoria (reconcile / `--clean`) | `deploy.sh` |

### 5.6 Variáveis no `.env`

```bash
GRAFANA_DOMAIN=grafana.scsi.digital
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=troque-esta-senha-do-grafana
PROMETHEUS_RETENTION=15d
LOKI_RETENTION=360h

# Servidor MCP do Grafana (serviço grafana-mcp) — ver seção 12
MCP_DOMAIN=mcp.scsi.digital
GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_...        # token de um Service Account do Grafana
MCP_BASICAUTH_USERS=admin:$2y$05$...          # htpasswd bcrypt, "$" SIMPLES (ver 12.2)

MONITORING_CONFIG_DIR=        # preenchido automaticamente pelos scripts
```

Tudo que é específico do projeto vive no `.env` e é interpolado pelo
`docker stack deploy` — o `monitoring-stack.yml` permanece um **template
genérico**, reaproveitável em outros projetos da mesma stack.

---

## 6. Fluxo de deploy (ordem das operações)

```mermaid
flowchart TD
    A[setup_deploy.sh<br/>publica a aplicação] --> B{App no ar?}
    B -- sim --> C[setup_monitoring.sh<br/>1ª vez, guiado]
    C --> C1[lê o .env e o DOMAIN]
    C1 --> C2[configura Grafana<br/>domínio + senha]
    C2 --> C3[cria a rede 'monitoring']
    C3 --> C4[docker stack deploy monitoring]
    C4 --> D[Grafana no ar<br/>datasources + dashboard prontos]
    D --> E[deploy.sh do app<br/>ativa /metrics no Django]
    E --> F[alvo 'django' fica UP no Prometheus]
    F --> G[deploy_monitoring.sh<br/>para futuras mudanças na monitoria]
```

!!! warning "Independência dos deploys"
    Os deploys são **separados de propósito**: você atualiza a monitoria sem
    redeployar o app (e vice-versa). Mudou só um dashboard? `deploy_monitoring.sh`.
    Mudou só o app? `deploy.sh`. Nenhum obriga o outro.

### Ativação do `/metrics` em produção

Se o sistema já estava no ar **antes** desta atualização, o endpoint `/metrics`
passa a existir no **próximo deploy do app** (`deploy.sh`), que reconstrói a
imagem já com o `django-prometheus`. Até lá, o alvo `django` aparece como
**DOWN** no Prometheus — o que é esperado e **não afeta** o funcionamento do site.

---

## 7. Como usar (operação)

### Subir pela primeira vez

```bash
# na VPS, como usuário deploy, dentro da pasta do projeto
bash scripts/setup_monitoring.sh
```

O script é didático: confere pré-requisitos, configura o Grafana, orienta o DNS,
cria a rede, valida os configs e sobe a stack — pausando e explicando cada etapa.

### Redeploy da monitoria

```bash
bash scripts/deploy_monitoring.sh            # git pull + reconcile + rollout
bash scripts/deploy_monitoring.sh --clean    # remove e recria do zero (dados preservados)
SKIP_GIT_PULL=1 bash scripts/deploy_monitoring.sh   # pula o git pull (usa os arquivos atuais)
```

!!! tip "O `deploy_monitoring.sh` agora dá `git pull` antes do deploy"
    Garante que o `monitoring-stack.yml` e os configs da VPS estão na última versão
    antes de reconciliar a stack (ex.: ao adicionar um serviço novo como o
    `grafana-mcp`). É `--ff-only` e **não aborta** se falhar — apenas avisa e segue.

### Acessar

- **Grafana:** `https://grafana.scsi.digital` (usuário/senha do `.env`).
- Dashboard **“SCSI — Visão Geral”** já vem na pasta *SCSI*.
- **Explore → Prometheus →** `up` lista os alvos (cada um deve valer `1`).
- **Explore → Loki →** `{stack="scsi_v1"}` mostra os logs do sistema.

### Dashboards extras (Grafana → Dashboards → Import → ID)

| ID | Dashboard | Funciona direto? |
|----|-----------|------------------|
| `1860` | Node Exporter Full (host) | ✅ sim (usa métricas `node_*`) |
| `14282` | Cadvisor exporter (containers) | ✅ sim (usa métricas `container_*`) |
| `21154` | Docker overview (cAdvisor + node) | ✅ sim |
| `9528` / `17658` | Django (django-prometheus) | ✅ sim (usa métricas `django_http_*`) |

!!! note "Nome das métricas do Django (sem prefixo de namespace)"
    O `django-prometheus` publica as métricas do Django **sem prefixo de
    namespace** — elas chegam ao Prometheus como `django_http_...` (ex.:
    `django_http_requests_latency_seconds_by_view_method_bucket`). É por isso que
    o dashboard **"SCSI — Visão Geral"** já incluso e os dashboards de Django da
    comunidade (9528, 17658) usam exatamente esses nomes, sem necessidade de
    ajustar prefixo. Os dashboards de **infra** (1860, 14282) usam nomes padrão
    de exporters (`node_*`, `container_*`).

---

## 8. Alertas

Definidos em `monitoring/prometheus/alert_rules.yml`. Aparecem na aba **Alerts**
do Prometheus. Para **notificações ativas** (e-mail/Slack/Telegram), pluge um
Alertmanager (não incluso nesta stack enxuta).

| Alerta | Disparo | Severidade |
|--------|---------|------------|
| `ServiceDown` | um alvo some por >1min | critical |
| `HighMemoryUsage` | container >85% da memória por 5min | warning |
| `HighCPUUsage` | container >80% CPU por 5min | warning |
| `DiskSpaceLow` | raiz com <15% livre | critical |
| `HighDjango5xxRate` | >5% das respostas em 5xx por 5min | critical |
| `HighDjangoLatencyP95` | P95 de latência >2s por 5min | warning |

### SLIs / SLOs sugeridos

| SLI | Medida (PromQL) | SLO |
|-----|------------------|-----|
| Latência P95 | `histogram_quantile(0.95, rate(django_http_requests_latency_seconds_by_view_method_bucket[5m]))` | < 2s |
| Disponibilidade | `1 - (5xx / total)` | > 99,5% |
| Erros 5xx | `rate(...status=~"5..")/rate(...total)` | < 0,5% |

---

## 9. Casos de uso

- **“O site está lento.”** Grafana → *Latência p50/p95/p99*. Se o P95 subiu,
  cruze com *CPU/Memória por container* e com os logs (`{stack="scsi_v1"}`).
- **“Deu erro pra um usuário.”** Explore → Loki →
  `{service="scsi_v1_app"} |= "ERROR"` no intervalo do incidente.
- **“O servidor vai encher o disco?”** Alerta `DiskSpaceLow` + dashboard
  Node Exporter (1860).
- **“Esse deploy piorou algo?”** Compare o período antes/depois no dashboard de
  *Requisições por método* e *Respostas por status*.
- **“Celery está engasgando?”** Logs do `scsi_v1_celery_worker` no Loki +
  CPU/Memória do container no cAdvisor.

---

## 10. Justificativas de projeto

- **Stack separada (`monitoring`)** em vez de adicionar serviços ao
  `docker-stack.yml`: isola ciclos de vida, evita redeploy cruzado e garante que
  a monitoria **não interfere** na produção.
- **Loki em vez de ELK:** muito mais leve (indexa só labels, não o conteúdo),
  ideal para 1 VPS; integra nativamente com Grafana.
- **Promtail por stdout dos containers:** zero acoplamento ao código; segue o
  padrão 12-factor (logs como streams de eventos).
- **`django-prometheus` com guarda de import:** instrumentação rica *de graça*,
  com degradação graciosa — segurança para produção.
- **Template genérico + `.env`:** o `monitoring-stack.yml` serve a outros
  projetos da mesma stack; só o alvo de scrape em `prometheus.yml` é específico.
- **Provisionamento do Grafana:** datasources e dashboard sobem prontos — menos
  cliques, menos erro humano, reprodutível.

---

## 11. Solução de problemas

| Sintoma | Causa provável | Ação |
|---------|----------------|------|
| Grafana não abre | DNS do subdomínio ainda não propagou; TLS validando | aguarde 1-2 min; confira o registro A |
| Alvo `django` DOWN | app ainda sem `/metrics` | rode `bash scripts/deploy.sh` |
| `/metrics` retorna **400** + `DisallowedHost` no log (e painéis do app em "no data") | Prometheus faz scrape conectando no **IP interno** do container, então o header `Host` é esse IP — fora do `ALLOWED_HOSTS` | já tratado pelo `core/middleware.py::MetricsHostMiddleware` (ligado no bloco `if PROMETHEUS_ENABLED:`), que reescreve o `Host` só da rota `/metrics`. Garanta que a imagem foi rebuildada (`bash scripts/deploy.sh`). **Não** adicione o IP no `.env` — é dinâmico (muda por réplica/rede/redeploy) |
| Alvo `django` **DOWN** com `Get "https://localhost/metrics": ... connect: connection refused` (e painéis do app em "no data") | `SECURE_SSL_REDIRECT=True` responde **301** redirecionando o scrape (HTTP, porta 8000) para `https://…/metrics`; o Prometheus segue o redirect e bate na porta 443 (inexistente dentro do container) | isente o `/metrics` do redirect, junto do `/health/`: `SECURE_REDIRECT_EXEMPT = [r'^health/$', r'^metrics$']` em `core/settings.py` (bloco `if not DEBUG:`). Rebuilde a imagem (`bash scripts/deploy.sh`). Complementa o `MetricsHostMiddleware`: um mata o **400 DisallowedHost**, o outro o **301 redirect** |
| Sem logs no Loki | Promtail sem acesso ao socket do Docker | confira `docker service logs monitoring_promtail` |
| `monitoring-stack.yml` falha no deploy | `MONITORING_CONFIG_DIR` vazio | rode pelos scripts (eles preenchem) |
| Painéis do app vazios ao importar dashboard da comunidade | queries com prefixo errado (ex.: `scsi_django_http_...`) | as métricas do Django **não** têm prefixo: use `django_http_...` direto nas queries |

Comandos úteis:

```bash
docker service ls | grep monitoring_
docker service logs -f monitoring_prometheus
docker service logs -f monitoring_loki
```

---

## 12. Servidor MCP do Grafana

O serviço **`grafana-mcp`** roda a imagem oficial
[`grafana/mcp-grafana`](https://github.com/grafana/mcp-grafana) e expõe, via
**MCP (Model Context Protocol)**, as ferramentas do Grafana para clientes de IA:
buscar e ler dashboards, consultar datasources, rodar PromQL no Prometheus e
LogQL no Loki, inspecionar alertas/incidentes, gerenciar datasources, etc.

Assim, em vez de abrir o Grafana no navegador, você conversa com a observabilidade
em linguagem natural ("qual a latência p95 da última hora?", "tem algum alerta
disparado?", "mostre os logs de erro do `scsi_v1_app`") direto do Claude, Cursor
ou VS Code.

### 12.1 Como está publicado

```mermaid
flowchart LR
    cli[Cliente de IA<br/>Claude / Cursor / VS Code]
    traefik[Traefik<br/>TLS + Basic Auth]
    mcp[grafana-mcp<br/>:8000 /mcp]
    graf[Grafana :3000]

    cli -->|"https://mcp.${DOMAIN}/mcp<br/>(Authorization: Basic ...)"| traefik
    traefik -->|Basic Auth OK| mcp
    mcp -->|"GRAFANA_SERVICE_ACCOUNT_TOKEN"| graf
```

| Item | Valor |
|------|-------|
| Imagem | `grafana/mcp-grafana:0.17.0` (versão fixada; tag do Docker Hub **sem** `v`) |
| Transporte | **streamable-http** (`-t streamable-http`), porta `8000`, endpoint `/mcp` |
| Rede interna | alcança o Grafana em `http://grafana:3000` pela rede `monitoring` |
| Publicação | Traefik (TLS Let's Encrypt) em `https://${MCP_DOMAIN}/mcp` |
| Autenticação na borda | **Basic Auth** do Traefik (`MCP_BASICAUTH_USERS`) |
| Autenticação no Grafana | `GRAFANA_SERVICE_ACCOUNT_TOKEN` (fica **no servidor**, nunca vai ao cliente) |

!!! warning "Por que Basic Auth na frente é obrigatório"
    O `mcp-grafana` **não tem login próprio**: quem alcança o endpoint opera o
    Grafana com o `GRAFANA_SERVICE_ACCOUNT_TOKEN`. Por isso ele é publicado
    **somente** atrás do Traefik com TLS **e** middleware de Basic Auth. Sem o
    Basic Auth, o endpoint ficaria aberto na internet.

São **duas camadas de credencial** com papéis distintos:

- **Service Account Token** (`GRAFANA_SERVICE_ACCOUNT_TOKEN`): é com ele que o MCP
  *fala com o Grafana*. Fica no container (env), **server-side** — o cliente nunca
  o envia.
- **Basic Auth** (`MCP_BASICAUTH_USERS`): é com ele que o *cliente alcança o
  endpoint* através do Traefik. É o que vai no header `Authorization: Basic ...`.

### 12.2 Pré-requisitos (uma vez)

**1. Criar o Service Account e o token no Grafana**

No Grafana: **Administration → Users and access → Service accounts → Add service
account** → defina o papel (ex.: `Viewer` para só consultar, `Editor` se for
criar/editar dashboards) → **Add service account token** → copie o token
(`glsa_...`) e coloque em `GRAFANA_SERVICE_ACCOUNT_TOKEN` no `.env`.

```bash
GRAFANA_SERVICE_ACCOUNT_TOKEN=glsa_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**2. Gerar as credenciais do Basic Auth (htpasswd, bcrypt)**

```bash
htpasswd -nbB mcpuser 'uma-senha-forte'
# saída: mcpuser:$2y$05$abcdef...
```

Coloque em `MCP_BASICAUTH_USERS` **exatamente como saiu, com `$` simples**:

```bash
MCP_BASICAUTH_USERS=mcpuser:$2y$05$abcdef...
```

!!! warning "Aqui o `$` NÃO é dobrado"
    Diferente do `$` escrito **direto** na stack (ex.: a regex do `node-exporter`,
    que usa `$$`), aqui o hash chega pela **interpolação de variável**
    (`${MCP_BASICAUTH_USERS}`). Os scripts exportam o `.env` e o `docker stack
    deploy` injeta o valor **verbatim** — então dobrar para `$$` faria o Traefik
    receber `$$` literal e o login falharia. Use o hash com **um `$`**.

> Vários usuários: separe por vírgula. Sem o `htpasswd`? Instale com
> `apt-get install -y apache2-utils`.

**3. Apontar o DNS** de `mcp.${DOMAIN}` (registro A/CNAME) para o IP da VPS e
definir `MCP_DOMAIN=mcp.scsi.digital` no `.env`.

Depois, suba/atualize a monitoria normalmente: `bash scripts/deploy_monitoring.sh`.

### 12.3 Conexão do cliente

O cliente conecta no endpoint **streamable-http** `https://${MCP_DOMAIN}/mcp`
enviando o header de **Basic Auth** do Traefik. O valor é
`Basic <base64("usuario:senha")>` (a **senha em texto puro**, não o hash):

```bash
# gere o valor do header uma vez:
printf 'mcpuser:uma-senha-forte' | base64
# -> bWNwdXNlcjp1bWEtc2VuaGEtZm9ydGU=
```

!!! danger "NÃO use o hash bcrypt no header do cliente"
    Erro comum: copiar `usuario:$2y$05$...` (o hash do `MCP_BASICAUTH_USERS`) para o
    header → resulta em **401**. O hash é só do **servidor**. O cliente envia a
    **senha em texto puro** em `base64("usuario:senha")`. Bcrypt é de mão única:
    não dá para derivar a senha do hash — guarde a senha quando gerá-la.

**Claude Code (CLI)**

```bash
claude mcp add --transport http grafana https://mcp.scsi.digital/mcp \
  --header "Authorization: Basic bWNwdXNlcjp1bWEtc2VuaGEtZm9ydGU="
```

**Claude Desktop / Cursor** (`~/.cursor/mcp.json` ou config de MCP do app)

```json
{
  "mcpServers": {
    "grafana": {
      "url": "https://mcp.scsi.digital/mcp",
      "headers": {
        "Authorization": "Basic bWNwdXNlcjp1bWEtc2VuaGEtZm9ydGU="
      }
    }
  }
}
```

**VS Code** (`.vscode/mcp.json` ou *Settings → MCP*)

```json
{
  "servers": {
    "grafana": {
      "type": "http",
      "url": "https://mcp.scsi.digital/mcp",
      "headers": {
        "Authorization": "Basic bWNwdXNlcjp1bWEtc2VuaGEtZm9ydGU="
      }
    }
  }
}
```

!!! note "O token do Grafana NÃO vai no cliente"
    Na nossa publicação remota, o `GRAFANA_SERVICE_ACCOUNT_TOKEN` já está
    configurado **no container** (server-side). O cliente só precisa do Basic Auth
    do Traefik. Isso mantém o token fora das máquinas dos clientes.

### 12.4 Alternativa local (stdio, sem expor nada)

Para uso pessoal pontual — sem publicar o serviço — dá para rodar o MCP
**localmente em stdio**, passando o token direto (modelo da
[doc oficial](https://grafana.com/docs/grafana-cloud/machine-learning/mcp/set-up/client-configuration-examples/)).
Aqui o `GRAFANA_SERVICE_ACCOUNT_TOKEN` vai **no cliente**, pois o MCP roda na sua
máquina:

```json
{
  "mcpServers": {
    "grafana": {
      "command": "docker",
      "args": [
        "run", "--rm", "-i",
        "-e", "GRAFANA_URL=https://grafana.scsi.digital",
        "-e", "GRAFANA_SERVICE_ACCOUNT_TOKEN",
        "grafana/mcp-grafana:0.17.0", "-t", "stdio"
      ],
      "env": {
        "GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa_xxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

> Use **ou** o serviço remoto (`grafana-mcp` na stack, recomendado p/ time) **ou**
> o stdio local (pontual). Não precisa dos dois.

### 12.5 Solução de problemas (MCP)

| Sintoma | Causa provável | Ação |
|---------|----------------|------|
| Task do `grafana-mcp` em `Rejected` com **`No such image: grafana/mcp-grafana:vX.Y.Z`** | tag com prefixo `v` — a imagem no **Docker Hub** usa tag **sem `v`** (o `v` é só o nome da *release* no GitHub) | use `grafana/mcp-grafana:0.17.0` (sem `v`). Confira tags válidas: `https://hub.docker.com/v2/repositories/grafana/mcp-grafana/tags/` |
| Rollout avisa **"serviço grafana-mcp ainda não existe"** / serviço não é criado | a VPS está com o `monitoring-stack.yml` **defasado** (sem o bloco do serviço) | rode `git pull` na VPS e o deploy de novo — o `deploy_monitoring.sh` já faz `git pull --ff-only` automaticamente |
| Cliente recebe **401** | header `Authorization` montado com o **hash bcrypt** em vez da senha | o header é `Basic <base64("usuario:SENHA_EM_TEXTO_PURO")>` — **não** use o `$2y$...` (esse é o hash do servidor, em `MCP_BASICAUTH_USERS`). Gere: `printf 'usuario:senha' \| base64` |
| Cliente recebe **404** e cert = **`TRAEFIK DEFAULT CERT`** | Traefik sem router para o Host → serviço não publicado / `MCP_DOMAIN` vazio no deploy | confirme `grafana-mcp` em `1/1`, `MCP_DOMAIN` no `.env` e redeploy; aguarde o Let's Encrypt emitir o cert |
| `grafana-mcp` sobe mas as ferramentas falham | `GRAFANA_SERVICE_ACCOUNT_TOKEN` inválido/sem permissão | gere novo token com papel adequado; veja `docker service logs monitoring_grafana-mcp` |
| Router do MCP some no Traefik | `MCP_DOMAIN` vazio (`Host()` inválido) | preencha `MCP_DOMAIN` no `.env` e redeploy |
| Basic Auth não valida | hash com `$` **dobrado** (`$$`) por engano | use o hash do `htpasswd` com `$` **simples** — aqui o valor vem por interpolação e é injetado verbatim (não dobre) |
| Endpoint não responde | DNS do `mcp.${DOMAIN}` não propagou / TLS validando | aguarde 1-2 min; confira o registro A |
