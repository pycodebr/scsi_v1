# MCP — Servidor Administrativo (Model Context Protocol)

Este guia documenta a stack de **MCP (Model Context Protocol)** do SCSI: um
servidor que permite a **agentes de IA** (Claude, Cursor, etc.) operarem o
sistema com segurança — consultando e manipulando todas as entidades e lendo
métricas — autenticados como **administradores do Django**.

---

## 1. O que é e por que existe

O **MCP** é um protocolo aberto que padroniza como modelos de IA descobrem e
chamam **tools** (ferramentas) de um sistema. Em vez de a IA "adivinhar" APIs,
ela recebe um catálogo de tools com schema (nome, descrição, parâmetros) e as
invoca de forma estruturada.

No SCSI o MCP serve para **operação administrativa assistida por IA**: um admin
conecta seu agente ao servidor e pede coisas como *"liste as apólices vencendo
este mês"*, *"crie um cliente"*, *"qual a taxa de conversão de propostas?"*. A IA
traduz isso em chamadas de tools reais, com validação e permissão do Django.

Usamos a biblioteca **`django-mcp-server`** (a mesma do MentorIA), que expõe um
endpoint HTTP `/mcp` e descobre automaticamente os *toolsets* declarados no
projeto.

| Tecnologia | Papel |
|------------|-------|
| **django-mcp-server** | Harness MCP: endpoint `/mcp`, registro de tools, schema |
| **mcp** (SDK oficial) | Protocolo MCP (transporte streamable HTTP) |
| **djangorestframework** | `BasicAuthentication` para autenticar a requisição |
| **core/mcp.py** | `ScsiAdminMCPToolset` — todas as tools do sistema |

---

## 2. Arquitetura

```mermaid
flowchart LR
    subgraph cliente[Cliente de IA]
        llm[Agente / LLM<br/>Claude, Cursor, ...]
    end

    subgraph swarm[SCSI em produção]
        traefik[Traefik<br/>HTTPS]
        subgraph app[Django app]
            ep["/mcp<br/>(MCPServerStreamableHttpView)"]
            auth[DRF BasicAuthentication<br/>+ admin-only por tool]
            ts[ScsiAdminMCPToolset<br/>core/mcp.py]
            models[(Models / ORM<br/>todas as entidades)]
        end
    end

    llm -->|"HTTPS + Authorization: Basic"| traefik --> ep --> auth --> ts --> models
    ts -->|JSON| llm

    classDef c fill:#1f6feb22,stroke:#1f6feb;
    class ep,auth,ts c;
```

**Fluxo resumido:** o agente envia uma requisição MCP a `https://<dominio>/mcp`
com o header `Authorization: Basic …`. O `django-mcp-server` autentica via DRF
(valida e-mail+senha contra os usuários do Django) e, dentro de cada tool, o
`ScsiAdminMCPToolset` exige que o usuário seja **admin** (`is_staff` ou
`is_superuser`). As tools usam o ORM para ler/gravar e devolvem JSON.

---

## 3. Autenticação — somente admin do Django

A autenticação é **HTTP Basic**, igual ao MentorIA. Há duas camadas:

```mermaid
sequenceDiagram
    participant IA as Agente de IA
    participant MCP as /mcp (DRF)
    participant Tool as ScsiAdminMCPToolset
    IA->>MCP: Authorization: Basic base64(email:senha)
    MCP->>MCP: BasicAuthentication valida contra os usuários (EmailBackend)
    alt credenciais inválidas
        MCP-->>IA: 401 Unauthorized
    else autenticado
        MCP->>Tool: executa a tool com request.user
        Tool->>Tool: _require_admin() — exige is_staff/is_superuser
        alt não é admin
            Tool-->>IA: PermissionDenied
        else admin
            Tool-->>IA: resultado (JSON)
        end
    end
```

1. **Camada de transporte (DRF `BasicAuthentication`):** configurada em
   `DJANGO_MCP_AUTHENTICATION_CLASSES`. Rejeita requisições sem credenciais
   válidas (401). Como o projeto autentica por **e-mail** (`EmailBackend`), o
   "usuário" do Basic é o **e-mail** do admin.
2. **Camada de autorização (admin-only):** cada tool chama
   `self._require_admin()`, que levanta `PermissionDenied` se o usuário não for
   `is_staff` nem `is_superuser`. Ou seja, **um usuário comum autenticado ainda
   assim não consegue usar nenhuma tool**.

### 3.1 Como gerar o token de acesso de um admin

O "token" do Basic Auth é apenas `base64("email:senha")` do **usuário admin do
Django**. Gere-o de uma destas formas:

=== "Linux / macOS"
    ```bash
    # Substitua pelo e-mail e senha do SEU usuário admin
    echo -n 'admin@scsi.digital:SUA_SENHA' | base64
    # saída → ex.: YWRtaW5Ac2NzaS5kaWdpdGFsOlNVQV9TRU5IQQ==
    ```

=== "Python"
    ```bash
    python -c "import base64; print(base64.b64encode(b'admin@scsi.digital:SUA_SENHA').decode())"
    ```

=== "Header pronto"
    ```http
    Authorization: Basic YWRtaW5Ac2NzaS5kaWdpdGFsOlNVQV9TRU5IQQ==
    ```

!!! warning "Cuidado com o token"
    O token é **equivalente à senha** do admin (é só ela codificada, não
    criptografada). Use **sempre HTTPS**, não versione o token e prefira um
    usuário admin dedicado à automação. Para revogar o acesso, troque a senha do
    usuário (ou desative `is_staff`/`is_superuser`).

### 3.2 Criar/garantir um usuário admin

```bash
# Na VPS, dentro de um container do app:
APP=$(docker ps --filter name=scsi_v1_app -q | head -1)
docker exec -it $APP python manage.py createsuperuser
```

Qualquer usuário com `is_staff=True` **ou** `is_superuser=True` é aceito.

---

## 4. As tools disponíveis

O `ScsiAdminMCPToolset` expõe **17 tools**, divididas em três grupos.

### 4.1 Catálogo (descoberta)

| Tool | O que faz |
|------|-----------|
| `list_entities` | Lista todas as entidades manipuláveis (slug, model, nº de registros) |
| `describe_entity(entity)` | Mostra os campos de uma entidade (tipo, obrigatório, choices, FK) |

> Use estas duas **antes** de criar/atualizar: elas dizem os **slugs** válidos e
> os **campos** esperados em `data`.

### 4.2 CRUD genérico (todas as entidades)

| Tool | O que faz |
|------|-----------|
| `list_records(entity, brokerage_id?, search?, filters?, limit?, offset?)` | Lista com busca textual, filtros exatos e paginação |
| `get_record(entity, id)` | Retorna um registro completo |
| `count_records(entity, brokerage_id?, filters?)` | Conta registros |
| `create_record(entity, data, brokerage_id?)` | Cria (valida com `full_clean`) |
| `update_record(entity, id, data)` | Atualiza parcialmente |
| `delete_record(entity, id)` | Exclui (cuidado com cascata) |

**Entidades cobertas (slugs):** `brokerage`, `plan`, `subscription`, `user`,
`client`, `insurer`, `line_of_business`, `proposal`, `covered_item`, `policy`,
`endorsement`, `renewal`, `claim`, `agent`, `producer`, `commission`,
`commission_split`, `document`, `pipeline`, `stage`, `deal`,
`deal_stage_history`, `notification`, `chat_session`, `chat_message` (CRUD
completo de **todos** os models do sistema).

### 4.3 Métricas e uso do sistema

| Tool | Retorna |
|------|---------|
| `general_metrics(brokerage_id?)` | Contagens e somatórios principais |
| `policy_metrics(brokerage_id?)` | Apólices por status/seguradora/ramo e prêmios |
| `commission_metrics(brokerage_id?)` | Comissões a receber/recebidas/pagas, repasses |
| `claim_metrics(brokerage_id?)` | Sinistros por status, reclamado x aprovado |
| `crm_metrics(brokerage_id?)` | Negociações por status/etapa e valor do funil |
| `proposal_metrics(brokerage_id?)` | Propostas por status e **taxa de conversão** |
| `pending_renewals(brokerage_id?, days?)` | Renovações a vencer (padrão 30 dias) |
| `list_brokerages(search?, active_only?, limit?)` | Corretoras com plano/assinatura |
| `system_usage()` | Usuários, corretoras, chat, documentos, storage, etc. |

---

## 5. Multi-tenancy nas tools

O isolamento por **corretora** (`brokerage`) no SCSI é **explícito** (o manager
não filtra sozinho). Como o MCP é exclusivo de **administradores do Django**, as
tools enxergam **todas as corretoras** por padrão — comportamento correto para um
super-operador. Para focar em uma corretora, passe `brokerage_id`.

- **Listagem/métricas:** `brokerage_id` é **opcional** (sem ele, visão global).
- **Criação de entidade tenant-aware** (`client`, `policy`, `claim`, etc.):
  `brokerage_id` é **obrigatório** — a tool recusa criar "órfão" de corretora.
- `user` tem `brokerage` **opcional** (não é tenant-aware): pode ser criado
  sem `brokerage_id`.

---

## 6. Como conectar um cliente MCP

O endpoint é **streamable HTTP**:

- **Produção:** `https://<SEU_DOMINIO>/mcp`
- **Local:** `http://localhost:8000/mcp`

A maioria dos clientes MCP fala "stdio". A ponte padrão para um endpoint HTTP com
header de auth é o **`mcp-remote`**:

=== "Claude Desktop / Claude Code (claude_desktop_config.json)"
    ```json
    {
      "mcpServers": {
        "scsi": {
          "command": "npx",
          "args": [
            "-y", "mcp-remote",
            "https://SEU_DOMINIO/mcp",
            "--header", "Authorization: Basic SEU_TOKEN_BASE64"
          ]
        }
      }
    }
    ```

=== "Teste rápido via curl (handshake)"
    ```bash
    curl -i https://SEU_DOMINIO/mcp \
      -H "Authorization: Basic SEU_TOKEN_BASE64" \
      -H "Accept: application/json, text/event-stream" \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
    ```

=== "Inspecionar tools localmente (sem cliente)"
    ```bash
    python manage.py mcp_inspect   # lista todas as tools e seus schemas
    ```

Depois de conectado, o agente vê as 17 tools e pode chamá-las. Exemplo de
chamada (JSON-RPC) que a IA monta sozinha:

```json
{ "jsonrpc": "2.0", "id": 2, "method": "tools/call",
  "params": { "name": "proposal_metrics", "arguments": { "brokerage_id": 1 } } }
```

---

## 7. Casos de uso

- *"Quantas apólices ativas e qual o prêmio total?"* → `policy_metrics`.
- *"Liste os sinistros abertos da corretora 3."* → `list_records('claim', brokerage_id=3, filters={'status':'opened'})`.
- *"Cadastre o cliente João (PF, CPF 123) na corretora 1."* → `describe_entity('client')` e então `create_record('client', {...}, brokerage_id=1)`.
- *"Quais renovações vencem em 15 dias?"* → `pending_renewals(days=15)`.
- *"Qual a taxa de conversão de propostas?"* → `proposal_metrics`.
- *"Promova o usuário X para is_staff."* → `update_record('user', X, {'is_staff': true})`.
- *"Quanto de comissão está pendente?"* → `commission_metrics`.

---

## 8. O que foi implementado (passo a passo)

1. **Dependências** (`requirements.txt`): `djangorestframework==3.16.1` e
   `django-mcp-server==0.5.6` (este traz o SDK `mcp` e o transporte streamable HTTP).
2. **`core/mcp.py`**: `ScsiAdminMCPToolset(MCPToolset)` com o registro `ENTITIES`,
   o CRUD genérico (serialização automática, `full_clean`, coerção de FKs,
   hash de senha para `usuario`), as tools de métricas/uso, e os helpers de
   autenticação admin-only.
3. **`core/apps.py`**: `CoreConfig` — registra `core` como app para que o
   autodiscover do `mcp_server` importe `core/mcp.py`.
4. **`core/settings.py`** (bloco `MCP_ENABLED`, guardado por import): só ativa o
   MCP se `rest_framework` + `mcp_server` estiverem instalados. Quando ativo,
   adiciona `rest_framework`, `mcp_server` e `core` ao `INSTALLED_APPS` e define
   `DJANGO_MCP_ENDPOINT`, `DJANGO_MCP_AUTHENTICATION_CLASSES` e
   `DJANGO_MCP_GLOBAL_SERVER_CONFIG`.
5. **`core/urls.py`**: monta `path('', include('mcp_server.urls'))` (endpoint
   `/mcp`) apenas quando `MCP_ENABLED`.

> **Não interfere no que já está no ar:** toda a ativação é guardada por import
> (`MCP_ENABLED`). Se as libs não estiverem instaladas, o app sobe **igual** e
> nada de MCP é exposto. No próximo `deploy.sh` (que reconstrói a imagem com o
> `requirements.txt`), o `/mcp` passa a existir automaticamente.

### Por que `core` vira app?

O `django-mcp-server` descobre tools via `autodiscover_modules('mcp')` — ele
importa o módulo `mcp` de cada app instalado. Como a classe fica em
`core/mcp.py`, registramos `core` como app (sem models, sem migrations) para que
a descoberta funcione — exatamente o padrão do MentorIA.

---

## 9. Segurança

- **HTTPS obrigatório:** o Basic Auth trafega a senha codificada (não cifrada);
  o TLS do Traefik protege em trânsito.
- **Admin-only por tool:** mesmo autenticado, um não-admin recebe `PermissionDenied`.
- **Sem exposição acidental:** sem as libs, o endpoint nem existe.
- **Auditoria/rotação:** use um admin dedicado para automação; revogue trocando a
  senha ou removendo `is_staff`/`is_superuser`.
- **Cascata em exclusões:** `delete_record` pode apagar relacionados (FKs
  `CASCADE`). A tool informa quantos objetos foram afetados; a IA deve confirmar
  antes de excluir entidades "pai" (`client`, `policy`).

---

## 10. Solução de problemas

| Sintoma | Causa provável | Ação |
|---------|----------------|------|
| `/mcp` retorna 404 | libs não instaladas / app não redeployado | instale as deps e rode `deploy.sh` |
| 401 Unauthorized | token errado, ou senha trocada | regenere `base64(email:senha)` |
| `PermissionDenied` em toda tool | usuário não é admin | use um usuário `is_staff`/`is_superuser` |
| Tool de criação falha com "Validação falhou" | campo obrigatório/constraint | use `describe_entity` e ajuste `data` |
| "informe 'brokerage_id'" | entidade tenant-aware | passe `brokerage_id` na criação |

Comandos úteis:

```bash
python manage.py mcp_inspect          # lista tools + schemas
docker service logs -f scsi_v1_app    # erros do endpoint /mcp em produção
```
