"""Middlewares próprios do projeto."""


class MetricsHostMiddleware:
    """Libera o scrape do `/metrics` sem afrouxar o ALLOWED_HOSTS das rotas públicas.

    O Prometheus coleta o `/metrics` pela rede overlay interna do Swarm, conectando
    diretamente no IP do container do app (ex.: 10.0.1.18). Logo o header ``Host`` da
    requisição é esse IP — que não está (e não deve estar) no ``ALLOWED_HOSTS``, pois
    é dinâmico (muda por réplica/redeploy e por rede a que o container está conectado).
    Isso fazia o Django responder ``400 DisallowedHost`` e o Prometheus nunca coletar
    as métricas (`scsi_django_*`), deixando os painéis do Grafana em "no data".

    Como o ``/metrics`` NÃO é roteado pelo Traefik (não é público), aqui reescrevemos
    o ``Host`` APENAS dessa rota para um valor já presente no ``ALLOWED_HOSTS``
    (``localhost``), antes de qualquer middleware do Django chamar ``get_host()``.
    As rotas públicas seguem com a validação normal de host intacta.

    Deve ser o PRIMEIRO middleware da pilha (antes do ``SecurityMiddleware``, que é
    quem dispara o ``DisallowedHost``).
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        if request.path == '/metrics':
            request.META['HTTP_HOST'] = 'localhost'
        return self.get_response(request)
