#!/bin/bash
set -euo pipefail

# SCSI — Deploy script for Docker Swarm
# Uso:
#   ./scripts/deploy.sh            -> só redeploy do stack
#   ./scripts/deploy.sh build      -> build + push da imagem e redeploy
#
# Pré-requisitos (rodar no nó manager do Swarm, no diretório do projeto):
#   - arquivo .env presente (com DEBUG=False em produção)
#   - secret do Cloudflare criado:
#       printf '<TOKEN>' | docker secret create CLOUDFLARE_DNS_API_TOKEN -
#   - rede externa criada:
#       docker network create --driver overlay --attachable traefik_public

REGISTRY="${REGISTRY:-ghcr.io/pycodebr/scsi_v1:latest}"
STACK_NAME="${STACK_NAME:-scsi_v1}"
STACK_FILE="docker-stack.yml"

echo "=== SCSI Deploy ==="

# --- Carrega o .env no ambiente (necessário para interpolações ${...} do stack:
#     ACME_EMAIL, DOMAIN). Parser seguro: NÃO faz `source` (valores com &, $, *,
#     espaços etc. quebrariam o shell) — apenas exporta KEY=VALUE literalmente. ---
if [ -f .env ]; then
    echo ">>> Carregando .env..."
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"                 # remove CR (arquivos salvos no Windows)
        case "$line" in
            ''|\#*) continue ;;              # ignora linha vazia / comentário
        esac
        [ "${line#*=}" = "$line" ] && continue   # sem '=' → ignora
        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"     # trim espaços à esquerda da chave
        key="${key%"${key##*[![:space:]]}"}"     # trim espaços à direita da chave
        case "$key" in
            ''|*[!A-Za-z0-9_]*) continue ;;  # chave inválida → ignora
        esac
        case "$value" in                     # remove aspas envolventes, se houver
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        export "$key=$value"
    done < .env
else
    echo "AVISO: .env não encontrado no diretório atual."
fi

# --- Valida que o secret do Cloudflare existe (TLS depende dele) ---
if ! docker secret inspect CLOUDFLARE_DNS_API_TOKEN >/dev/null 2>&1; then
    echo "ERRO: secret 'CLOUDFLARE_DNS_API_TOKEN' não existe."
    echo "      Crie com: printf '<TOKEN>' | docker secret create CLOUDFLARE_DNS_API_TOKEN -"
    exit 1
fi

# --- Build + push (opcional) ---
if [ "${1:-}" = "build" ]; then
    echo ">>> Building image..."
    docker build -t "$REGISTRY" .
    echo ">>> Pushing image..."
    docker push "$REGISTRY"
fi

# --- Deploy do stack ---
echo ">>> Deploying stack..."
docker stack deploy -c "$STACK_FILE" --with-registry-auth "$STACK_NAME"

# --- Força rollout dos serviços que usam a imagem da aplicação (puxa :latest novo) ---
echo ">>> Forçando rollout dos serviços da aplicação..."
for svc in app celery_worker celery_beat; do
    docker service update --force "${STACK_NAME}_${svc}" >/dev/null 2>&1 || true
done

echo ">>> Aguardando estabilizar..."
sleep 10

echo ">>> Status dos serviços:"
docker service ls --format "table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}" | grep -E "^${STACK_NAME}_|NAME"

echo ""
echo "=== Pós-deploy ==="
echo "Migrations e collectstatic rodam automaticamente no entrypoint do serviço 'app'"
echo "(com advisory lock — seguro para múltiplas réplicas)."
echo ""
echo "Criar superusuário (manual, 1x):"
echo "  APP=\$(docker ps --filter name=${STACK_NAME}_app -q | head -n1)"
echo "  docker exec -it \$APP python manage.py createsuperuser"
echo ""
echo "Logs:"
echo "  docker service logs -f ${STACK_NAME}_app"
echo "  docker service logs -f ${STACK_NAME}_traefik"
