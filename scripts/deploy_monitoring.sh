#!/bin/bash
set -euo pipefail

# ── SCSI — Deploy da stack de MONITORAMENTO (Docker Swarm, executado NA VPS) ──
# Faz para a monitoria o mesmo papel que o deploy.sh faz para a aplicação:
# reconcilia a stack e força o rollout dos serviços. Roda de forma SEPARADA do
# deploy do sistema — assim você atualiza a monitoria sem mexer no app, e
# vice-versa.
#
# Uso:
#   ./scripts/deploy_monitoring.sh            deploy/reconcile + rollout
#   ./scripts/deploy_monitoring.sh --clean    remove a stack e recria do zero
#                                             (os volumes de dados são preservados)
#
# Pré-requisitos na VPS (nó manager do Swarm), no diretório do projeto:
#   - .env preenchido com a seção "Monitoramento" (GRAFANA_*, *_RETENTION)
#   - rede externa do Traefik:  traefik_public  (criada no deploy da aplicação)
#   - DNS de ${GRAFANA_DOMAIN} apontando para o IP da VPS
#
# Dica: na PRIMEIRA vez, prefira o guia passo a passo:  ./scripts/setup_monitoring.sh

STACK_NAME="monitoring"
STACK_FILE="monitoring-stack.yml"

# ── Cores ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!!]${NC} $1"; }
error() { echo -e "${RED}[ERRO]${NC} $1"; exit 1; }

CLEAN=0
[ "${1:-}" = "--clean" ] && CLEAN=1

echo "=== SCSI — Deploy da MONITORIA ($STACK_NAME) ==="
echo ""

# ── 0. Pré-condições ──
command -v docker >/dev/null 2>&1 || error "Docker não encontrado."
docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active \
    || error "Este nó não está em Swarm ativo (rode: docker swarm init)."
[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" = "true" ] \
    || error "Este nó NÃO é manager do Swarm — necessário para deploy de stack."

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"
[ -f "$STACK_FILE" ] || error "$STACK_FILE não encontrado em $REPO_DIR"

# ── 1. Carrega .env (parser seguro: NÃO faz source) ──
[ -f .env ] || error "Arquivo .env não encontrado em $REPO_DIR"
echo "--- Carregando .env ---"
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    [ "${line#*=}" = "$line" ] && continue
    key="${line%%=*}"; value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    export "$key=$value"
done < .env
info ".env carregado"

# ── 2. Variáveis obrigatórias da monitoria ──
echo ""
echo "--- Validações ---"
[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] \
    || error "GRAFANA_ADMIN_PASSWORD vazio no .env — defina a senha do admin do Grafana."
[ -n "${GRAFANA_DOMAIN:-}" ] \
    || error "GRAFANA_DOMAIN vazio no .env — defina o subdomínio do Grafana (ex.: grafana.scsi.digital)."

# Variáveis do servidor MCP do Grafana (serviço grafana-mcp). NÃO são obrigatórias
# para o resto da stack subir — por isso AVISAMOS em vez de abortar (degradação
# graciosa). Sem elas, só o endpoint MCP fica inoperante (ver docs/monitoring.md).
for v in MCP_DOMAIN GRAFANA_SERVICE_ACCOUNT_TOKEN MCP_BASICAUTH_USERS; do
    eval "_val=\${$v:-}"
    [ -n "$_val" ] \
        || warn "$v vazio no .env — o serviço 'grafana-mcp' não funcionará até preencher (ver docs/monitoring.md)."
done

# Caminho ABSOLUTO dos configs (montados nos containers). Sempre derivado do
# repo para garantir consistência, independente do que estiver no .env.
export MONITORING_CONFIG_DIR="$REPO_DIR/monitoring"
for f in \
    "monitoring/prometheus/prometheus.yml" \
    "monitoring/prometheus/alert_rules.yml" \
    "monitoring/loki/loki-config.yml" \
    "monitoring/promtail/promtail-config.yml" \
    "monitoring/grafana/provisioning/datasources/datasources.yml" \
    "monitoring/grafana/provisioning/dashboards/dashboards.yml" ; do
    [ -f "$REPO_DIR/$f" ] || error "Arquivo de config ausente: $f"
done

# Defaults de retenção (caso o .env não traga).
export PROMETHEUS_RETENTION="${PROMETHEUS_RETENTION:-15d}"
export LOKI_RETENTION="${LOKI_RETENTION:-360h}"
export GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
info "Configs e variáveis OK (MONITORING_CONFIG_DIR=$MONITORING_CONFIG_DIR)"

# ── 3. Rede overlay da monitoria ──
echo ""
echo "--- Rede 'monitoring' ---"
if docker network ls --format '{{.Name}}' | grep -qx monitoring; then
    info "Rede 'monitoring' já existe"
else
    docker network create --driver overlay --attachable monitoring >/dev/null
    info "Rede 'monitoring' criada"
fi
docker network ls --format '{{.Name}}' | grep -qx traefik_public \
    || error "Rede 'traefik_public' ausente — faça o deploy da aplicação primeiro (setup_deploy.sh)."

# ── 4. (Opcional) limpeza total da stack ──
if [ "$CLEAN" -eq 1 ]; then
    echo ""
    echo "--- Removendo stack '$STACK_NAME' (volumes preservados) ---"
    docker stack rm "$STACK_NAME" || true
    echo "    Aguardando os serviços encerrarem..."
    sleep 15
    info "Stack removida — será recriada do zero"
fi

# ── 5. Deploy do stack ──
echo ""
echo "--- Deploy do stack de monitoramento ---"
docker stack deploy -c "$STACK_FILE" "$STACK_NAME"
info "Stack reconciliada"

# ── 6. Força rollout (garante configs/imagens novas) ──
if [ "$CLEAN" -eq 0 ]; then
    echo ""
    echo "--- Rollout dos serviços ---"
    for svc in prometheus grafana grafana-mcp loki promtail node-exporter cadvisor; do
        docker service update --force "${STACK_NAME}_${svc}" >/dev/null 2>&1 \
            && info "rollout: ${STACK_NAME}_${svc}" \
            || warn "rollout falhou (serviço ainda não existe?): ${STACK_NAME}_${svc}"
    done
fi

echo ""
echo "--- Aguardando estabilizar ---"
sleep 10

echo ""
echo "--- Status ---"
docker service ls --format "table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}" \
    | grep -E "^NAME|^${STACK_NAME}_" || true

echo ""
echo "=== Deploy da monitoria concluído! ==="
echo "  Grafana:    https://${GRAFANA_DOMAIN}  (login: ${GRAFANA_ADMIN_USER})"
[ -n "${MCP_DOMAIN:-}" ] \
    && echo "  MCP:        https://${MCP_DOMAIN}/mcp  (streamable-http, protegido por Basic Auth)"
echo "  Retenção:   métricas=${PROMETHEUS_RETENTION}  logs=${LOKI_RETENTION}"
echo ""
echo "  Logs:       docker service logs -f ${STACK_NAME}_prometheus"
echo "  Alvos:      no Grafana -> Explore (Prometheus) -> query 'up'"
