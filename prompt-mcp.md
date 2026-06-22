# Prompt — Implementar uma stack de MCP (Model Context Protocol) administrativa

> **Como usar:** abra o repositório-alvo no seu agente de IA (Claude Code,
> Cursor, etc.) e cole o conteúdo de `<prompt>` a `</prompt>`. O prompt é
> **agnóstico de projeto**: descobre os models, o User e o mecanismo multi-tenant
> lendo o código. Os blocos de código são **implementações de referência** — o
> *engine* genérico de CRUD é reutilizável quase verbatim; só o registro
> `ENTITIES`, a constante `TENANT_FK` e as tools de métricas precisam ser
> adaptados aos models do alvo.
>
> Stack-alvo: **Django + Docker Swarm/Traefik**, config via `.env`, com modelos
> de domínio próprios. Usa **`django-mcp-server`** + **DRF BasicAuthentication**.
>
> Convenção de código: **identificadores, parâmetros, slugs e chaves de saída em
> inglês (PEP-8)**; comentários, docstrings e mensagens de erro podem ser no
> idioma do projeto.

---

<prompt>

<role>
Você é um(a) engenheiro(a) Django sênior especialista em integração de IA e
protocolos de agentes. Você implementa servidores MCP de produção com segurança:
autenticação correta, autorização admin-only, degradação graciosa e tools
tipadas e validadas. Você conhece a biblioteca django-mcp-server, o DRF e o ORM
do Django a fundo, e escreve código em inglês seguindo PEP-8.
</role>

<context>
O repositório-alvo é uma aplicação Django JÁ EM PRODUÇÃO:
- Vários apps com models de domínio (ORM).
- Um User customizado (possivelmente login por e-mail) com is_staff/is_superuser.
- Pode ter multi-tenancy (FK de tenant em alguns models).
- Config via .env (django-environ ou equivalente). Deploy em Docker Swarm + Traefik.
- NÃO há servidor MCP ainda.
</context>

<objective>
Adicionar um servidor MCP administrativo, centralizado em core/mcp.py, usando
django-mcp-server. O servidor DEVE expor:
1. CRUD COMPLETO de TODAS as entidades/models do sistema.
2. Tools de métricas e uso do sistema (contagens, somatórios, status, conversão).
Autenticado SOMENTE por administradores do Django via HTTP Basic Auth.
</objective>

<hard_constraints>
Regras MANDATÓRIAS. Violá-las invalida a entrega.
1. NÃO interferir no deploy existente. A ativação do MCP DEVE ser GUARDADA por
   import (`importlib.util.find_spec`): sem as libs (rest_framework + mcp_server),
   o app sobe IGUAL e nada de MCP é exposto.
2. Toda a lógica do MCP DEVE ficar centralizada em `core/mcp.py` (ou no pacote do
   projeto), numa classe que herda de `mcp_server.MCPToolset`.
3. A autenticação DEVE ser HTTP Basic (DRF `BasicAuthentication`), configurada em
   `DJANGO_MCP_AUTHENTICATION_CLASSES`. O cliente envia
   `Authorization: Basic base64(usuario:senha)`.
4. Acesso ADMIN-ONLY: CADA tool DEVE chamar um `_require_admin()` que levanta
   `PermissionDenied` se o usuário não for `is_staff` nem `is_superuser`.
5. As tools DEVEM cobrir CRUD completo de TODAS as entidades + métricas/uso.
6. O endpoint DEVE ser montado em `/mcp` via `include('mcp_server.urls')`.
7. NÃO faça hardcode de credenciais. Use o backend de auth existente do projeto.
8. CÓDIGO EM INGLÊS seguindo PEP-8 (nomes de classes/métodos/variáveis,
   parâmetros, slugs de entidade e chaves dos dicts de saída). Comentários,
   docstrings e mensagens de erro podem ficar no idioma do projeto.
</hard_constraints>

<discovery_first>
ANTES de escrever, INSPECIONE o repositório e ANOTE:

```bash
# Pacote do projeto (settings.py/urls.py) e apps locais
grep -nE "LOCAL_APPS|INSTALLED_APPS|AUTH_USER_MODEL|environ|decouple" -r */settings.py
# TODOS os models (entity slug -> app.Model) para montar o registro ENTITIES
find . -path ./.venv -prune -o -name models.py -print | xargs grep -nE "class .*\(.*Model\)"
# User customizado: campos, USERNAME_FIELD, is_staff/is_superuser, backend de auth
sed -n '1,80p' <accounts_app>/models.py; cat <accounts_app>/backends.py 2>/dev/null
# Multi-tenancy: existe FK de tenant? é obrigatória? o manager filtra sozinho?
grep -rnE "class .*Manager|for_tenant|current_tenant|TenantAware|ForeignKey\(.*[Tt]enant" .
# DRF/MCP já presentes?
grep -rnE "rest_framework|mcp_server|djangomcp" */settings.py requirements.txt
```

Defina e ANOTE:
- `PKG` = pacote do projeto (ex.: `core`).
- `ADMIN_RULE` = `is_staff or is_superuser`.
- `TENANT_FK` = nome da FK de tenant (ex.: `brokerage`, `tenant`, `company`) e se
  é OBRIGATÓRIA (null=False) nos models tenant-aware. Use `None` se não houver.
- `ENTITIES` = mapa slug(inglês, snake_case)→"app.Model" de TODOS os models.
</discovery_first>

<reference_architecture>
- Cliente de IA → `https://<dominio>/mcp` com `Authorization: Basic …`.
- `django-mcp-server` autentica via DRF BasicAuthentication (valida usuario+senha
  contra os usuários do Django pelo backend existente).
- Cada tool exige admin (`_require_admin`) antes de tocar o ORM.
- `mcp_server` descobre tools via `autodiscover_modules('mcp')` — importa o módulo
  `mcp` de cada app instalado. Por isso o pacote do projeto (`core`) DEVE ser um
  app instalado para que `core/mcp.py` seja descoberto.
- Multi-tenancy: como o MCP é admin-only, as tools veem TODOS os tenants por
  padrão e aceitam `brokerage_id` (ou `<tenant>_id`) opcional; na criação de
  entidade tenant-aware esse id é OBRIGATÓRIO.
</reference_architecture>

<deliverables>

### 1. Dependências (`requirements.txt`)

```
djangorestframework==3.16.1
django-mcp-server==0.5.6
```

### 2. `core/mcp.py` — engine genérico (REUTILIZÁVEL quase verbatim)

Adapte: o registro `ENTITIES`, a constante `TENANT_FK` e as tools de métricas
(use os models reais). O resto funciona como está. Código em inglês (PEP-8).

```python
"""Servidor MCP administrativo. Admin-only (is_staff/is_superuser). django-mcp-server."""
from datetime import date, datetime, timedelta
from decimal import Decimal
from uuid import UUID

from django.apps import apps
from django.core.exceptions import PermissionDenied
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import transaction
from django.db.models import Count, DecimalField, Q, Sum, Value
from django.db.models.functions import Coalesce
from django.utils import timezone
from mcp_server import MCPToolset

# Nome da FK de tenant (None se o projeto não for multi-tenant). ADAPTE.
TENANT_FK = 'brokerage'

# slug (snake_case) -> "app_label.ModelName". ADAPTE a TODOS os models do alvo.
ENTITIES = {
    'client': 'clients.Client',
    'policy': 'insurance.Policy',
    # ... todos os models do sistema ...
}


class AdminMCPToolset(MCPToolset):
    """Tools administrativas expostas via MCP (todas exigem admin do Django)."""

    # ── Authentication / authorization ──
    def _user(self):
        user = getattr(self.request, 'user', None)
        if not user or not getattr(user, 'is_authenticated', False):
            raise PermissionDenied('Autenticação obrigatória para usar o MCP.')
        return user

    def _require_admin(self):
        user = self._user()
        if not (user.is_staff or user.is_superuser):
            raise PermissionDenied('Apenas administradores do Django podem usar o MCP.')
        return user

    # ── Model / record helpers ──
    def _user_model(self):
        from django.contrib.auth import get_user_model
        return get_user_model()

    def _entity(self, entity):
        label = ENTITIES.get((entity or '').strip().lower())
        if not label:
            available = ', '.join(sorted(ENTITIES))
            raise ValueError(f"Entidade '{entity}' desconhecida. Use: {available}.")
        return apps.get_model(label)

    @staticmethod
    def _is_tenant_aware(model):
        # Tenant-aware só quando a FK de tenant é OBRIGATÓRIA (null=False).
        if not TENANT_FK:
            return False
        for field in model._meta.concrete_fields:
            if field.name == TENANT_FK and field.is_relation:
                return not field.null
        return False

    @staticmethod
    def _relations(model):
        return [f.name for f in model._meta.concrete_fields if f.is_relation]

    @staticmethod
    def _clamp(value, default=50, maximum=200):
        try:
            value = int(value)
        except (TypeError, ValueError):
            value = default
        return max(1, min(value or default, maximum))

    def _to_jsonable(self, value):
        if value is None or isinstance(value, (str, int, float, bool)):
            return value
        if isinstance(value, Decimal):
            return float(value)
        if isinstance(value, (datetime, date)):
            return value.isoformat()
        if isinstance(value, UUID):
            return str(value)
        if isinstance(value, (list, tuple)):
            return [self._to_jsonable(item) for item in value]
        if isinstance(value, dict):
            return {str(k): self._to_jsonable(v) for k, v in value.items()}
        return str(value)

    def _serialize(self, obj):
        data = {}
        for field in obj._meta.concrete_fields:
            if field.is_relation:
                related_id = getattr(obj, field.attname)
                if related_id is None:
                    data[field.name] = None
                else:
                    related = getattr(obj, field.name, None)
                    data[field.name] = {'id': related_id, 'label': str(related) if related else None}
            elif field.get_internal_type() in ('FileField', 'ImageField'):
                value = getattr(obj, field.attname)
                data[field.name] = (value or None) and str(value)
            else:
                data[field.name] = self._to_jsonable(getattr(obj, field.attname))
        data['_label'] = str(obj)
        return data

    def _field_specs(self, model):
        specs = []
        for field in model._meta.concrete_fields:
            spec = {
                'name': field.name,
                'type': field.get_internal_type(),
                'editable': bool(field.editable),
                'required': bool(
                    field.editable and not field.blank
                    and not field.has_default() and not field.primary_key
                ),
                'nullable': bool(field.null),
            }
            if field.is_relation and field.related_model is not None:
                spec['relation_to'] = field.related_model._meta.label
            choices = getattr(field, 'choices', None)
            if choices:
                spec['choices'] = [c[0] for c in choices if not isinstance(c[1], (list, tuple))]
            specs.append(spec)
        return specs

    def _get_object(self, model, pk):
        try:
            return model._default_manager.get(pk=pk)
        except model.DoesNotExist:
            raise ValueError(f'{model.__name__} com id={pk} não encontrado.')

    def _scope(self, queryset, model, brokerage_id):
        if not brokerage_id or not self._is_tenant_aware(model):
            return queryset
        return queryset.filter(**{f'{TENANT_FK}_id': brokerage_id})

    def _clean_filters(self, model, filters):
        names = {f.name for f in model._meta.get_fields()}
        names.update(f.attname for f in model._meta.concrete_fields)
        cleaned = {}
        for key, value in (filters or {}).items():
            if key.split('__', 1)[0] not in names:
                raise ValueError(f"Filtro '{key}' inválido para {model.__name__}.")
            cleaned[key] = value
        return cleaned

    def _search_q(self, model, term):
        text_types = {'CharField', 'TextField', 'EmailField', 'SlugField'}
        query = Q()
        for field in model._meta.concrete_fields:
            if field.get_internal_type() in text_types and not field.is_relation:
                query |= Q(**{f'{field.name}__icontains': term})
        return query

    def _apply_data(self, model, data, instance=None):
        if not isinstance(data, dict):
            raise ValueError("O parâmetro 'data' deve ser um objeto.")
        field_map = {f.name: f for f in model._meta.concrete_fields}
        obj = instance if instance is not None else model()
        for key, value in data.items():
            name = key[:-3] if key.endswith('_id') and key[:-3] in field_map else key
            field = field_map.get(name)
            if field is None or not field.editable or field.primary_key:
                raise ValueError(f"Campo '{key}' inválido em {model.__name__}.")
            setattr(obj, field.attname if field.is_relation else field.name, value)
        return obj

    @staticmethod
    def _format_validation_error(exc):
        if hasattr(exc, 'message_dict'):
            parts = [f"{k}: {', '.join(map(str, v))}" for k, v in exc.message_dict.items()]
            return 'Validação falhou — ' + '; '.join(parts)
        messages = getattr(exc, 'messages', [str(exc)])
        return 'Validação falhou — ' + '; '.join(map(str, messages))

    def _sum(self, queryset, field):
        result = queryset.aggregate(
            total=Coalesce(Sum(field), Value(0), output_field=DecimalField())
        )['total']
        return float(result or 0)

    def _scoped(self, label, brokerage_id):
        model = apps.get_model(label)
        queryset = model._default_manager.all()
        if brokerage_id and self._is_tenant_aware(model):
            queryset = queryset.filter(**{f'{TENANT_FK}_id': brokerage_id})
        return queryset

    # ── Catalog ──
    def list_entities(self) -> list[dict]:
        """Lista as entidades manipuláveis (slug, model, nº de registros)."""
        self._require_admin()
        result = []
        for slug, label in sorted(ENTITIES.items()):
            model = apps.get_model(label)
            result.append({
                'entity': slug,
                'model': model._meta.label,
                'tenant_aware': self._is_tenant_aware(model),
                'total_records': model._default_manager.count(),
            })
        return result

    def describe_entity(self, entity: str) -> dict:
        """Descreve os campos de uma entidade (tipo, obrigatório, choices, FK)."""
        self._require_admin()
        model = self._entity(entity)
        return {
            'entity': entity,
            'model': model._meta.label,
            'tenant_aware': self._is_tenant_aware(model),
            'fields': self._field_specs(model),
        }

    # ── Generic CRUD ──
    def list_records(
        self,
        entity: str,
        brokerage_id: int | None = None,
        search: str | None = None,
        filters: dict | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> dict:
        """Lista registros com busca textual, filtros exatos e paginação."""
        self._require_admin()
        model = self._entity(entity)
        queryset = model._default_manager.all()
        relations = self._relations(model)
        if relations:
            queryset = queryset.select_related(*relations)
        queryset = self._scope(queryset, model, brokerage_id)
        if filters:
            queryset = queryset.filter(**self._clean_filters(model, filters))
        if search:
            queryset = queryset.filter(self._search_q(model, search))
        total = queryset.count()
        limit = self._clamp(limit)
        offset = max(0, int(offset or 0))
        records = [self._serialize(o) for o in queryset.order_by('-pk')[offset:offset + limit]]
        return {'entity': entity, 'total': total, 'offset': offset, 'limit': limit, 'records': records}

    def get_record(self, entity: str, id: int) -> dict:
        """Retorna um registro completo."""
        self._require_admin()
        return self._serialize(self._get_object(self._entity(entity), id))

    def count_records(self, entity: str, brokerage_id: int | None = None,
                      filters: dict | None = None) -> dict:
        """Conta registros (com filtros/escopo opcionais)."""
        self._require_admin()
        model = self._entity(entity)
        queryset = self._scope(model._default_manager.all(), model, brokerage_id)
        if filters:
            queryset = queryset.filter(**self._clean_filters(model, filters))
        return {'entity': entity, 'total': queryset.count()}

    def create_record(self, entity: str, data: dict, brokerage_id: int | None = None) -> dict:
        """Cria um registro (valida com full_clean). FKs por id. 'user': inclua password."""
        self._require_admin()
        model = self._entity(entity)
        data = dict(data or {})
        password = data.pop('password', None) if model is self._user_model() else None
        obj = self._apply_data(model, data)
        if self._is_tenant_aware(model):
            tenant_id = brokerage_id or getattr(obj, f'{TENANT_FK}_id', None)
            if not tenant_id:
                raise ValueError(f"A entidade '{entity}' é tenant-aware: informe 'brokerage_id'.")
            setattr(obj, f'{TENANT_FK}_id', tenant_id)
        if password is not None:
            obj.set_password(password)
        try:
            with transaction.atomic():
                obj.full_clean()
                obj.save()
        except DjangoValidationError as exc:
            raise ValueError(self._format_validation_error(exc))
        return self._serialize(obj)

    def update_record(self, entity: str, id: int, data: dict) -> dict:
        """Atualiza parcialmente (apenas campos enviados). 'user': password redefine a senha."""
        self._require_admin()
        model = self._entity(entity)
        obj = self._get_object(model, id)
        data = dict(data or {})
        password = data.pop('password', None) if model is self._user_model() else None
        self._apply_data(model, data, instance=obj)
        if password:
            obj.set_password(password)
        try:
            with transaction.atomic():
                obj.full_clean()
                obj.save()
        except DjangoValidationError as exc:
            raise ValueError(self._format_validation_error(exc))
        return self._serialize(obj)

    def delete_record(self, entity: str, id: int) -> dict:
        """Exclui um registro (pode cascatear). Bloqueia auto-exclusão do usuário."""
        self._require_admin()
        model = self._entity(entity)
        obj = self._get_object(model, id)
        if model is self._user_model() and obj.pk == self._user().pk:
            raise ValueError('Não é possível excluir o próprio usuário autenticado.')
        label = str(obj)
        affected, per_model = obj.delete()
        return {'entity': entity, 'id': id, 'deleted': label,
                'affected_objects': affected, 'detail': per_model}

    # ── Metrics (ADAPTE aos models/status reais do projeto) ──
    def general_metrics(self, brokerage_id: int | None = None) -> dict:
        """Visão geral: contagens e somatórios principais (ADAPTE aos models)."""
        self._require_admin()
        return {
            'clients_total': self._scoped('clients.Client', brokerage_id).count(),
            'active_policies': self._scoped('insurance.Policy', brokerage_id).filter(status='active').count(),
            # ... demais contagens/somatórios relevantes (use Count, Sum+Coalesce, values().annotate()) ...
        }

    def system_usage(self) -> dict:
        """Indicadores de uso/adoção (ADAPTE)."""
        self._require_admin()
        user_model = self._user_model()
        return {
            'users_total': user_model.objects.count(),
            'admin_users': user_model.objects.filter(Q(is_staff=True) | Q(is_superuser=True)).count(),
        }
```

> Inclua AINDA tools de métricas específicas do domínio (por status, por
> categoria, taxa de conversão, valores a receber/pagos, itens "a vencer").

### 3. `core/apps.py` — registrar o pacote como app

```python
from django.apps import AppConfig


class CoreConfig(AppConfig):
    """Registra 'core' como app para o autodiscover do mcp_server achar core/mcp.py."""

    default_auto_field = 'django.db.models.BigAutoField'
    name = 'core'
```

### 4. `core/settings.py` — bloco GUARDADO (ao final)

```python
import importlib.util as _importlib_util

MCP_ENABLED = all(
    _importlib_util.find_spec(_mod) is not None
    for _mod in ('rest_framework', 'mcp_server')
)
if MCP_ENABLED:
    INSTALLED_APPS = INSTALLED_APPS + ['rest_framework', 'mcp_server', 'core']
    DJANGO_MCP_ENDPOINT = env('DJANGO_MCP_ENDPOINT', default='mcp')
    DJANGO_MCP_AUTHENTICATION_CLASSES = ['rest_framework.authentication.BasicAuthentication']
    DJANGO_MCP_GLOBAL_SERVER_CONFIG = {
        'name': env('DJANGO_MCP_SERVER_NAME', default='<projeto>'),
        'instructions': (
            'Servidor MCP administrativo. Todas as tools exigem admin do Django. '
            'Use list_entities e describe_entity para descobrir slugs e campos.'
        ),
        'stateless': env.bool('DJANGO_MCP_STATELESS', default=True),
    }
```

### 5. `core/urls.py` — montar o endpoint (guardado)

```python
from django.conf import settings
# ... urlpatterns existente ...
if getattr(settings, 'MCP_ENABLED', False):
    urlpatterns += [path('', include('mcp_server.urls'))]   # endpoint /mcp
```

### 6. Documentação

Crie `docs/mcp.md` (registre no nav, se houver) com: o que é MCP e por quê;
diagrama de arquitetura e **sequenceDiagram** do fluxo de auth; catálogo de tools;
multi-tenancy; **como gerar o token Basic de um admin**; como conectar um cliente
(config do Claude/`mcp-remote`, `curl` de teste, `manage.py mcp_inspect`); casos
de uso; segurança; troubleshooting.
</deliverables>

<auth_details>
Geração do token (é só `base64("usuario:senha")` de um admin do Django):
```bash
echo -n 'admin@dominio:SENHA' | base64
python -c "import base64;print(base64.b64encode(b'admin@dominio:SENHA').decode())"
```
Header: `Authorization: Basic <token>`. Se o projeto loga por e-mail, o "usuario"
é o e-mail. NUNCA versione o token; use sempre HTTPS; revogue trocando a senha ou
removendo is_staff/is_superuser. Crie um admin com `manage.py createsuperuser`.
</auth_details>

<implementation_rules>
- Guarda de import (`MCP_ENABLED`) é OBRIGATÓRIA (constraint 1).
- `_require_admin()` no INÍCIO de TODA tool pública.
- Métodos com `_` no início são helpers (NÃO viram tools).
- Type hints e docstrings em cada tool: o django-mcp-server gera o schema a
  partir deles (`dict` → object, `int | None = None` → opcional).
- Criação/edição: SEMPRE `full_clean()` dentro de `transaction.atomic()`; converta
  `ValidationError` do Django em `ValueError` legível.
- Senha de usuário: use `set_password` (NUNCA grave em texto puro).
- Multi-tenant: exija o id de tenant na criação de entidades tenant-aware; NÃO o
  exija para models com FK de tenant OPCIONAL (ex.: o próprio User).
- `core` (pacote do projeto) DEVE ser app instalado para o autodiscover achar
  `core/mcp.py`.
- CÓDIGO EM INGLÊS (PEP-8). Comentários/docstrings/mensagens podem ser localizados.
</implementation_rules>

<anti_patterns>
NÃO faça: expor tools sem `_require_admin`; autenticar por token estático/custom
em vez de Basic+usuário do Django; gravar senha sem hash; quebrar o boot quando as
libs faltam (sempre guarde com MCP_ENABLED); colocar a lógica fora de core/mcp.py;
montar o endpoint sem `DJANGO_MCP_AUTHENTICATION_CLASSES`; retornar objetos não
serializáveis; escrever identificadores em outro idioma que não inglês.
</anti_patterns>

<verification>
Valide e relate cada item com PASS/FAIL:

```bash
# 1. Sintaxe
python -m py_compile core/mcp.py core/apps.py core/settings.py core/urls.py
# 2. Não-interferência: sem as libs, MCP_ENABLED=False e o app sobe igual
python -c "import os,django;os.environ['DJANGO_SETTINGS_MODULE']='core.settings';django.setup();from django.conf import settings as s;print('boot ok', s.MCP_ENABLED)"
# 3. Com as libs instaladas: tools registradas
python manage.py mcp_inspect | grep -E "create_record|list_records|general_metrics"
# 4. Runtime (sqlite temporário): admin-only + CRUD + métricas
#    - non-admin -> PermissionDenied
#    - create/get/update/delete de um registro simples
#    - tenant-aware exige brokerage_id; auto-exclusão de usuário bloqueada
#    - general_metrics()/system_usage() retornam dict
```
Instancie a toolset em teste com `AdminMCPToolset(request=SimpleNamespace(user=admin))`.
</verification>

<tips>
- `manage.py mcp_inspect` lista todas as tools e seus JSON-schemas.
- Endpoint streamable HTTP; conecte clientes "stdio" via `npx mcp-remote
  <url>/mcp --header "Authorization: Basic <token>"`.
- Para saber o que enviar em `data`, o agente deve chamar `describe_entity(<slug>)`
  antes de `create_record`.
- `delete_record` pode cascatear (FKs CASCADE) — retorne quantos objetos foram
  afetados e oriente confirmação para entidades "pai".
- O `/mcp` passa a existir só após instalar as deps e redeployar (rebuild da
  imagem). Até lá, retorna 404 — esperado.
</tips>

<output_format>
1. Resumo (até 5 linhas) do que foi implementado.
2. Lista de arquivos criados/alterados, com caminho.
3. Resultado das verificações (<verification>) com PASS/FAIL.
4. Instruções finais: gerar o token Basic de um admin e conectar um cliente MCP.
Implemente DE FATO os arquivos no repositório — não entregue só explicação.
</output_format>

</prompt>
