"""
Servidor MCP (Model Context Protocol) do SCSI — ferramentas administrativas.

Toda a stack de MCP fica centralizada aqui, usando a biblioteca
``django-mcp-server`` (mesma adotada no MentorIA). Este módulo é descoberto
automaticamente pelo ``mcp_server`` (autodiscover do módulo ``mcp`` dos apps
instalados) — por isso ``core`` é registrado como app quando o MCP está ativo
(ver core/settings.py).

Autenticação e autorização
--------------------------
- O endpoint ``/mcp`` exige HTTP Basic Auth (``rest_framework`` BasicAuthentication),
  configurado em ``DJANGO_MCP_AUTHENTICATION_CLASSES`` (core/settings.py).
- O cliente envia ``Authorization: Basic base64(email:senha)``. O ``EmailBackend``
  do projeto valida e-mail + senha contra a base de usuários do Django.
- **Apenas administradores do Django** (``is_staff`` ou ``is_superuser``) podem
  usar qualquer tool: cada método chama ``self._require_admin()`` na entrada.

Cobertura de tools
------------------
- CRUD genérico e COMPLETO de todas as entidades do sistema, dirigido por um
  registro (``ENTITIES``): list/get/create/update/delete/count.
- Tools de métricas/uso do sistema (apólices, comissões, sinistros, CRM,
  propostas, renovações, uso geral) para leitura agregada.

Multi-tenancy
-------------
O isolamento por corretora (``brokerage``) é EXPLÍCITO no projeto (o manager não
filtra sozinho). Como o MCP é exclusivo de administradores do Django, as tools
enxergam TODAS as corretoras por padrão e aceitam ``brokerage_id`` opcional para
restringir a uma corretora específica. Na criação de entidades tenant-aware,
``brokerage_id`` é obrigatório.
"""

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


# Campo da FK de tenant (corretora). Models com esta FK OBRIGATÓRIA são tenant-aware.
TENANT_FK = 'brokerage'

# ─────────────────────────────────────────────────────────────────────────────
# Registro de entidades expostas pelo CRUD genérico.
# slug (snake_case, baseado no model) -> "app_label.ModelName"
# ─────────────────────────────────────────────────────────────────────────────
ENTITIES = {
    # Tenancy / catalog
    'brokerage': 'tenants.Brokerage',
    'plan': 'tenants.Plan',
    'subscription': 'tenants.Subscription',
    # Accounts
    'user': 'accounts.User',
    # Base records
    'client': 'clients.Client',
    'insurer': 'insurers.Insurer',
    'line_of_business': 'insurers.LineOfBusiness',
    # Insurance
    'proposal': 'insurance.Proposal',
    'covered_item': 'insurance.CoveredItem',
    'policy': 'insurance.Policy',
    'endorsement': 'insurance.Endorsement',
    'renewal': 'insurance.Renewal',
    # Claims
    'claim': 'claims.Claim',
    # Partners
    'agent': 'partners.Agent',
    'producer': 'partners.Producer',
    # Commissions
    'commission': 'commissions.Commission',
    'commission_split': 'commissions.CommissionSplit',
    # Documents
    'document': 'documents.Document',
    # CRM
    'pipeline': 'crm.Pipeline',
    'stage': 'crm.Stage',
    'deal': 'crm.Deal',
    'deal_stage_history': 'crm.DealStageHistory',
    # Notifications
    'notification': 'notifications.Notification',
    # AI
    'chat_session': 'ai_agents.ChatSession',
    'chat_message': 'ai_agents.ChatMessage',
}


class ScsiAdminMCPToolset(MCPToolset):
    """Conjunto de ferramentas administrativas do SCSI expostas via MCP.

    Todos os métodos públicos (sem ``_``) viram tools MCP. Cada tool exige um
    usuário administrador do Django (``is_staff`` ou ``is_superuser``).
    """

    # ── Authentication / authorization ──────────────────────────────────────
    def _user(self):
        user = getattr(self.request, 'user', None)
        if not user or not getattr(user, 'is_authenticated', False):
            raise PermissionDenied('Autenticação obrigatória para usar o MCP.')
        return user

    def _require_admin(self):
        """Garante que o usuário autenticado é admin do Django."""
        user = self._user()
        if not (user.is_staff or user.is_superuser):
            raise PermissionDenied(
                'Apenas administradores do Django (is_staff/is_superuser) podem usar o MCP.'
            )
        return user

    # ── Model / record helpers ──────────────────────────────────────────────
    def _user_model(self):
        return apps.get_model('accounts', 'User')

    def _entity(self, entity):
        label = ENTITIES.get((entity or '').strip().lower())
        if not label:
            available = ', '.join(sorted(ENTITIES))
            raise ValueError(
                f"Entidade '{entity}' desconhecida. Use uma de: {available}."
            )
        return apps.get_model(label)

    @staticmethod
    def _is_tenant_aware(model):
        """True só quando a FK de tenant é OBRIGATÓRIA (TenantAwareModel).

        Models como ``accounts.User`` têm um ``brokerage`` OPCIONAL (null=True) e
        NÃO são tenant-aware — não exigem brokerage_id na criação.
        """
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
        """Serializa uma instância em dict JSON-friendly (FKs como {id, label})."""
        data = {}
        for field in obj._meta.concrete_fields:
            internal_type = field.get_internal_type()
            if field.is_relation:
                related_id = getattr(obj, field.attname)
                if related_id is None:
                    data[field.name] = None
                else:
                    related = getattr(obj, field.name, None)
                    data[field.name] = {'id': related_id, 'label': str(related) if related else None}
            elif internal_type in ('FileField', 'ImageField'):
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
                    field.editable
                    and not field.blank
                    and not field.has_default()
                    and not field.primary_key
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
            raise ValueError(f'{model.__name__} com id={pk} não encontrado(a).')

    def _scope(self, queryset, model, brokerage_id):
        if not brokerage_id:
            return queryset
        if model is apps.get_model('tenants', 'Brokerage'):
            return queryset.filter(pk=brokerage_id)
        if self._is_tenant_aware(model):
            return queryset.filter(**{f'{TENANT_FK}_id': brokerage_id})
        return queryset

    def _clean_filters(self, model, filters):
        names = {f.name for f in model._meta.get_fields()}
        # Aceita também os attnames das FKs (ex.: 'brokerage_id', 'client_id').
        names.update(f.attname for f in model._meta.concrete_fields)
        cleaned = {}
        for key, value in (filters or {}).items():
            base = key.split('__', 1)[0]
            if base not in names:
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
            raise ValueError("O parâmetro 'data' deve ser um objeto (dicionário).")
        field_map = {f.name: f for f in model._meta.concrete_fields}
        obj = instance if instance is not None else model()
        for key, value in data.items():
            name = key[:-3] if key.endswith('_id') and key[:-3] in field_map else key
            field = field_map.get(name)
            if field is None or not field.editable or field.primary_key:
                raise ValueError(f"Campo '{key}' inválido/não editável em {model.__name__}.")
            if field.is_relation:
                setattr(obj, field.attname, value)
            else:
                setattr(obj, field.name, value)
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

    # ════════════════════════════════════════════════════════════════════════
    #  CATALOG / DISCOVERY
    # ════════════════════════════════════════════════════════════════════════
    def list_entities(self) -> list[dict]:
        """Lista todas as entidades (models) manipuláveis pelo CRUD genérico.

        Use esta tool ANTES de criar/atualizar registros para descobrir os slugs
        válidos. Para ver os campos de cada entidade, use ``describe_entity``.
        """
        self._require_admin()
        result = []
        for slug, label in sorted(ENTITIES.items()):
            model = apps.get_model(label)
            result.append({
                'entity': slug,
                'model': model._meta.label,
                'verbose_name': str(model._meta.verbose_name),
                'tenant_aware': self._is_tenant_aware(model),
                'total_records': model._default_manager.count(),
            })
        return result

    def describe_entity(self, entity: str) -> dict:
        """Descreve os campos de uma entidade (nome, tipo, obrigatório, choices, FK).

        Útil para saber exatamente o que enviar em ``data`` ao criar/atualizar.
        """
        self._require_admin()
        model = self._entity(entity)
        return {
            'entity': entity,
            'model': model._meta.label,
            'tenant_aware': self._is_tenant_aware(model),
            'fields': self._field_specs(model),
        }

    # ════════════════════════════════════════════════════════════════════════
    #  GENERIC CRUD (all entities)
    # ════════════════════════════════════════════════════════════════════════
    def list_records(
        self,
        entity: str,
        brokerage_id: int | None = None,
        search: str | None = None,
        filters: dict | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> dict:
        """Lista registros de uma entidade, com busca textual, filtros e paginação.

        - ``entity``: slug da entidade (ver ``list_entities``).
        - ``brokerage_id``: restringe a uma corretora (opcional; admin vê todas).
        - ``search``: texto procurado nos campos de texto (icontains).
        - ``filters``: dict de filtros exatos do ORM, ex.: {"status": "active"}.
        - ``limit`` (1-200) e ``offset`` para paginação.
        """
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
        records = [self._serialize(obj) for obj in queryset.order_by('-pk')[offset:offset + limit]]
        return {
            'entity': entity,
            'total': total,
            'offset': offset,
            'limit': limit,
            'records': records,
        }

    def get_record(self, entity: str, id: int) -> dict:
        """Retorna um registro específico, com todos os campos serializados."""
        self._require_admin()
        model = self._entity(entity)
        return self._serialize(self._get_object(model, id))

    def count_records(
        self,
        entity: str,
        brokerage_id: int | None = None,
        filters: dict | None = None,
    ) -> dict:
        """Conta registros de uma entidade (com filtros/escopo opcionais)."""
        self._require_admin()
        model = self._entity(entity)
        queryset = self._scope(model._default_manager.all(), model, brokerage_id)
        if filters:
            queryset = queryset.filter(**self._clean_filters(model, filters))
        return {'entity': entity, 'total': queryset.count()}

    def create_record(
        self,
        entity: str,
        data: dict,
        brokerage_id: int | None = None,
    ) -> dict:
        """Cria um registro de uma entidade.

        - ``data``: objeto com os campos do registro. Para FKs, informe o id
          (ex.: {"client": 12} ou {"client_id": 12}).
        - ``brokerage_id``: OBRIGATÓRIO para entidades tenant-aware (corretora dona).
        - Para 'user', inclua ``password`` em ``data`` (será criptografado).
        Valida com ``full_clean`` (respeita constraints e validators do model).
        """
        self._require_admin()
        model = self._entity(entity)
        data = dict(data or {})
        password = data.pop('password', None) if model is self._user_model() else None
        obj = self._apply_data(model, data)
        if self._is_tenant_aware(model):
            tenant_id = brokerage_id or getattr(obj, f'{TENANT_FK}_id', None)
            if not tenant_id:
                raise ValueError(
                    f"A entidade '{entity}' é tenant-aware: informe 'brokerage_id'."
                )
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
        """Atualiza parcialmente um registro (apenas os campos enviados em ``data``).

        Para 'user', ``password`` em ``data`` redefine a senha (criptografada).
        """
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
        """Exclui um registro. ATENÇÃO: deleções podem cascatear (FKs CASCADE).

        Bloqueia a exclusão do próprio usuário autenticado.
        """
        self._require_admin()
        model = self._entity(entity)
        obj = self._get_object(model, id)
        if model is self._user_model() and obj.pk == self._user().pk:
            raise ValueError('Você não pode excluir o próprio usuário autenticado.')
        label = str(obj)
        affected, per_model = obj.delete()
        return {
            'entity': entity,
            'id': id,
            'deleted': label,
            'affected_objects': affected,
            'detail': per_model,
        }

    # ════════════════════════════════════════════════════════════════════════
    #  METRICS / SYSTEM USAGE
    # ════════════════════════════════════════════════════════════════════════
    def general_metrics(self, brokerage_id: int | None = None) -> dict:
        """Visão geral do sistema: contagens e somatórios principais.

        ``brokerage_id`` opcional restringe os números a uma corretora.
        """
        self._require_admin()
        brokerage_model = apps.get_model('tenants', 'Brokerage')
        return {
            'brokerages_total': brokerage_model.objects.count(),
            'users_total': self._scoped('accounts.User', brokerage_id).count(),
            'clients_total': self._scoped('clients.Client', brokerage_id).count(),
            'active_clients': self._scoped('clients.Client', brokerage_id).filter(is_active=True).count(),
            'insurers_total': self._scoped('insurers.Insurer', brokerage_id).count(),
            'proposals_total': self._scoped('insurance.Proposal', brokerage_id).count(),
            'policies_total': self._scoped('insurance.Policy', brokerage_id).count(),
            'active_policies': self._scoped('insurance.Policy', brokerage_id).filter(status='active').count(),
            'claims_total': self._scoped('claims.Claim', brokerage_id).count(),
            'open_claims': self._scoped('claims.Claim', brokerage_id).filter(
                status__in=['opened', 'under_analysis']).count(),
            'open_deals': self._scoped('crm.Deal', brokerage_id).filter(status='open').count(),
            'active_total_premium': self._sum(
                self._scoped('insurance.Policy', brokerage_id).filter(status='active'), 'total_premium'),
            'pending_commission': self._sum(
                self._scoped('commissions.Commission', brokerage_id).filter(status='pending'), 'insurer_amount'),
        }

    def policy_metrics(self, brokerage_id: int | None = None) -> dict:
        """Métricas de apólices: por status, por seguradora, por ramo e prêmios."""
        self._require_admin()
        queryset = self._scoped('insurance.Policy', brokerage_id)
        return {
            'total': queryset.count(),
            'by_status': list(queryset.values('status').annotate(total=Count('id')).order_by('-total')),
            'by_insurer': list(
                queryset.values('insurer__name').annotate(total=Count('id')).order_by('-total')[:20]),
            'by_line_of_business': list(
                queryset.values('line_of_business__name').annotate(total=Count('id')).order_by('-total')[:20]),
            'net_premium_total': self._sum(queryset, 'net_premium'),
            'total_premium': self._sum(queryset, 'total_premium'),
            'active_premium': self._sum(queryset.filter(status='active'), 'total_premium'),
        }

    def commission_metrics(self, brokerage_id: int | None = None) -> dict:
        """Métricas de comissões: a receber, recebidas, pagas e repasses pendentes."""
        self._require_admin()
        commissions = self._scoped('commissions.Commission', brokerage_id)
        splits = self._scoped('commissions.CommissionSplit', brokerage_id)
        return {
            'commissions_total': commissions.count(),
            'by_status': list(commissions.values('status').annotate(total=Count('id')).order_by('-total')),
            'pending_amount': self._sum(commissions.filter(status='pending'), 'insurer_amount'),
            'received_amount': self._sum(commissions.filter(status='received'), 'insurer_amount'),
            'paid_amount': self._sum(commissions.filter(status='paid'), 'insurer_amount'),
            'pending_splits': splits.filter(status='pending').count(),
            'pending_split_amount': self._sum(splits.filter(status='pending'), 'amount'),
        }

    def claim_metrics(self, brokerage_id: int | None = None) -> dict:
        """Métricas de sinistros: por status, valores reclamados x aprovados."""
        self._require_admin()
        queryset = self._scoped('claims.Claim', brokerage_id)
        return {
            'total': queryset.count(),
            'by_status': list(queryset.values('status').annotate(total=Count('id')).order_by('-total')),
            'total_claimed_amount': self._sum(queryset, 'claimed_amount'),
            'total_approved_amount': self._sum(queryset, 'approved_amount'),
        }

    def crm_metrics(self, brokerage_id: int | None = None) -> dict:
        """Métricas do CRM: negociações por status, por etapa e valor do funil."""
        self._require_admin()
        queryset = self._scoped('crm.Deal', brokerage_id)
        return {
            'total': queryset.count(),
            'by_status': list(queryset.values('status').annotate(total=Count('id')).order_by('-total')),
            'by_stage': list(
                queryset.values('stage__name').annotate(total=Count('id')).order_by('-total')[:30]),
            'open_estimated_value': self._sum(queryset.filter(status='open'), 'estimated_value'),
        }

    def proposal_metrics(self, brokerage_id: int | None = None) -> dict:
        """Métricas de propostas: por status e taxa de conversão em apólice."""
        self._require_admin()
        queryset = self._scoped('insurance.Proposal', brokerage_id)
        total = queryset.count()
        converted = queryset.filter(status='converted').count()
        return {
            'total': total,
            'by_status': list(queryset.values('status').annotate(total=Count('id')).order_by('-total')),
            'converted': converted,
            'conversion_rate_pct': round((converted / total) * 100, 2) if total else 0.0,
        }

    def pending_renewals(self, brokerage_id: int | None = None, days: int = 30) -> list[dict]:
        """Lista renovações a vencer nos próximos ``days`` (padrão 30), ordenadas."""
        self._require_admin()
        renewal_model = apps.get_model('insurance', 'Renewal')
        cutoff_date = timezone.localdate() + timedelta(days=int(days or 30))
        queryset = renewal_model._default_manager.filter(
            status__in=['pending', 'in_progress'], due_date__lte=cutoff_date,
        ).select_related('policy', 'policy__client')
        if brokerage_id:
            queryset = queryset.filter(**{f'{TENANT_FK}_id': brokerage_id})
        result = []
        for renewal in queryset.order_by('due_date')[:200]:
            result.append({
                'id': renewal.pk,
                'status': renewal.status,
                'due_date': renewal.due_date.isoformat() if renewal.due_date else None,
                'policy': {'id': renewal.policy_id, 'label': str(renewal.policy)} if renewal.policy_id else None,
                'client': str(renewal.policy.client) if renewal.policy_id and renewal.policy.client_id else None,
            })
        return result

    def list_brokerages(
        self,
        search: str | None = None,
        active_only: bool = False,
        limit: int = 50,
    ) -> list[dict]:
        """Lista corretoras (tenants) com plano e assinatura — visão de admin."""
        self._require_admin()
        brokerage_model = apps.get_model('tenants', 'Brokerage')
        queryset = brokerage_model.objects.select_related('plan', 'subscription', 'owner')
        if active_only:
            queryset = queryset.filter(is_active=True)
        if search:
            queryset = queryset.filter(
                Q(legal_name__icontains=search)
                | Q(trade_name__icontains=search)
                | Q(cnpj__icontains=search)
            )
        result = []
        for brokerage in queryset.order_by('trade_name', 'legal_name')[:self._clamp(limit)]:
            subscription = getattr(brokerage, 'subscription', None)
            result.append({
                'id': brokerage.pk,
                'legal_name': brokerage.legal_name,
                'trade_name': brokerage.trade_name,
                'cnpj': brokerage.cnpj,
                'is_active': brokerage.is_active,
                'plan': str(brokerage.plan) if brokerage.plan_id else None,
                'subscription_status': subscription.status if subscription else None,
                'owner': str(brokerage.owner) if brokerage.owner_id else None,
            })
        return result

    def system_usage(self) -> dict:
        """Indicadores de uso/adoção: usuários, corretoras, chat, documentos, etc."""
        self._require_admin()
        user_model = apps.get_model('accounts', 'User')
        brokerage_model = apps.get_model('tenants', 'Brokerage')
        chat_session_model = apps.get_model('ai_agents', 'ChatSession')
        chat_message_model = apps.get_model('ai_agents', 'ChatMessage')
        document_model = apps.get_model('documents', 'Document')
        notification_model = apps.get_model('notifications', 'Notification')
        return {
            'users_total': user_model.objects.count(),
            'active_users': user_model.objects.filter(is_active=True).count(),
            'admin_users': user_model.objects.filter(Q(is_staff=True) | Q(is_superuser=True)).count(),
            'users_by_role': list(
                user_model.objects.values('role').annotate(total=Count('id')).order_by('-total')),
            'brokerages_total': brokerage_model.objects.count(),
            'active_brokerages': brokerage_model.objects.filter(is_active=True).count(),
            'chat_sessions': chat_session_model.objects.count(),
            'chat_messages': chat_message_model.objects.count(),
            'documents': document_model.objects.count(),
            'storage_bytes': int(
                document_model.objects.aggregate(total=Coalesce(Sum('size'), Value(0)))['total'] or 0),
            'unread_notifications': notification_model.objects.filter(is_read=False).count(),
        }
