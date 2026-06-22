from django.apps import AppConfig


class CoreConfig(AppConfig):
    """AppConfig do pacote do projeto.

    Registrar ``core`` como app permite que o ``django-mcp-server`` descubra
    automaticamente o módulo ``core/mcp.py`` (autodiscover do módulo ``mcp`` dos
    apps instalados). Só é adicionado ao INSTALLED_APPS quando o MCP está ativo
    (ver core/settings.py — bloco MCP_ENABLED).
    """

    default_auto_field = 'django.db.models.BigAutoField'
    name = 'core'
