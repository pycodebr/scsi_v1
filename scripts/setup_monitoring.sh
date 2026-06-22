#!/usr/bin/env bash
# =============================================================================
#  setup_monitoring.sh — Sobe a stack de MONITORAMENTO, passo a passo (guiado)
# =============================================================================
#  PycodeBR — monitoria, observabilidade e logs "como mágica", para qualquer
#  sistema com a mesma stack/estrutura do SCSI (Django + Docker Swarm + Traefik).
#
#  O QUE ESTE SCRIPT FAZ (em linguagem simples):
#    Depois que o seu sistema já está no ar (você rodou o setup_deploy.sh),
#    este script sobe — SEPARADAMENTE, sem mexer no sistema — as ferramentas que
#    deixam você "enxergar" a aplicação por dentro:
#       • Prometheus  -> coleta números (métricas): requisições, erros, CPU, RAM
#       • Grafana     -> telas bonitas (dashboards) para ver esses números
#       • Loki        -> junta os LOGS de todos os containers num lugar só
#       • Promtail    -> entrega os logs ao Loki
#       • node-exporter / cAdvisor -> métricas do servidor e dos containers
#
#  IMPORTANTE: subir a monitoria NÃO derruba e NÃO altera o sistema em produção.
#  São stacks separadas. Você pode rodar este script quando quiser, depois do
#  deploy da aplicação.
#
#  COMO RODAR (na VPS, como usuário 'deploy', dentro da pasta do projeto):
#      bash scripts/setup_monitoring.sh
#
#  É IDEMPOTENTE: pode rodar de novo quantas vezes quiser — pula o que já existe.
#  Em caso de erro, mostra o motivo/linha/comando e grava log em ~/setup_monitoring.log
# =============================================================================

set -Eeuo pipefail

# Se a entrada padrão NÃO for um terminal (ex.: 'curl ... | bash'), aponta a
# entrada para o terminal real — assim as perguntas funcionam mesmo via "cano".
if [[ ! -t 0 && -e /dev/tty ]]; then exec </dev/tty; fi

# ─────────────────────────────────────────────────────────────────────────────
#  Cores / logging visual
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD="$(tput bold)";   RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"; GREY="$(tput setaf 8)"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; GREY=""
fi

LOG_FILE="${HOME:-/root}/setup_monitoring.log"
STEP=0
PHASE_LABEL="MONITORIA"

_logfile() { printf '%s %s\n' "[$(date '+%F %H:%M:%S')]" "$1" >>"$LOG_FILE" 2>/dev/null || true; }

banner() {
  echo ""
  echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  printf "${BOLD}${CYAN}║${RESET} %-60s ${BOLD}${CYAN}║${RESET}\n" "$1"
  echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
}
step() {
  STEP=$((STEP + 1))
  echo ""
  echo "${BOLD}${BLUE}▶ ${PHASE_LABEL} — PASSO ${STEP}:${RESET} ${BOLD}$1${RESET}"
  echo "${GREY}──────────────────────────────────────────────────────────────${RESET}"
  _logfile "PASSO ${STEP}: $1"
}
info()    { echo "  ${BLUE}ℹ${RESET}  $1";  _logfile "INFO  $1"; }
ok()      { echo "  ${GREEN}✔${RESET}  $1";  _logfile "OK    $1"; }
warn()    { echo "  ${YELLOW}⚠${RESET}  $1"; _logfile "WARN  $1"; }
skip()    { echo "  ${GREEN}✓${RESET}  ${GREY}$1 (já existe — pulando)${RESET}"; _logfile "SKIP  $1"; }
working() { echo "  ${CYAN}⏳${RESET} $1..."; _logfile "WORK  $1"; }

# Caixa de DESTAQUE para coisas que o usuário PRECISA fazer (copiar/colar/abrir).
action_box() {
  echo ""
  echo "${BOLD}${YELLOW}  ┌──────────────────────── AÇÃO NECESSÁRIA ───────────────────────┐${RESET}"
  while [[ $# -gt 0 ]]; do echo "${BOLD}${YELLOW}  │${RESET} $1"; shift; done
  echo "${BOLD}${YELLOW}  └────────────────────────────────────────────────────────────────┘${RESET}"
  echo ""
}
pause_enter() {
  echo ""
  read -r -p "  ${BOLD}${GREEN}➜ Quando terminar, pressione ENTER para continuar...${RESET} " _ || true
}

# ─────────────────────────────────────────────────────────────────────────────
#  Tratamento de erros
# ─────────────────────────────────────────────────────────────────────────────
on_error() {
  local exit_code=$1 line=$2 cmd=$3
  echo ""
  echo "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo "${BOLD}${RED}║  ❌ ERRO — o script parou                                     ║${RESET}"
  echo "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo "  ${RED}Passo........:${RESET} ${STEP}"
  echo "  ${RED}Linha........:${RESET} ${line}"
  echo "  ${RED}Comando......:${RESET} ${cmd}"
  echo "  ${RED}Código saída.:${RESET} ${exit_code}"
  echo ""
  echo "  ${YELLOW}O que fazer:${RESET}"
  echo "    1. Leia a mensagem de erro logo acima desta caixa."
  echo "    2. Log completo: ${BOLD}${LOG_FILE}${RESET}"
  echo "    3. Rode o script de novo — ele é idempotente e retoma de onde dá."
  echo ""
  _logfile "ERRO exit=$exit_code line=$line cmd=<$cmd> passo=$STEP"
  if [[ -e /dev/tty ]]; then
    read -r -p "  Pressione ENTER para fechar..." _ </dev/tty 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap 'on_error $? ${LINENO} "$BASH_COMMAND"' ERR

# ─────────────────────────────────────────────────────────────────────────────
#  Utilitários
# ─────────────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

confirm_SN() {
  local prompt="$1" answer
  while true; do
    read -r -p "  ${YELLOW}❓ ${prompt} [S/N]:${RESET} " answer || true
    case "$answer" in
      [Ss]|[Ss][Ii][Mm]) return 0 ;;
      [Nn]|[Nn][Aa][Oo]) return 1 ;;
      *) warn "Responda com S (sim) ou N (não)." ;;
    esac
  done
}
ask() {  # ask "Pergunta" "default" -> ecoa a resposta
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "  ${CYAN}❯ ${prompt}${RESET} [${default}]: " answer || true
    echo "${answer:-$default}"
  else
    read -r -p "  ${CYAN}❯ ${prompt}${RESET}: " answer || true
    echo "$answer"
  fi
}
ask_secret() {  # lê valor sem ecoar na tela
  local prompt="$1" answer
  read -r -s -p "  ${CYAN}❯ ${prompt}${RESET}: " answer || true
  echo "" >&2
  echo "$answer"
}
gen_secret() { openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "${1:-20}" || true; }

# Lê uma variável do .env (sem expandir nada). Retorna vazio se não existir.
get_env_var() {
  local k="$1"
  [[ -f .env ]] || { echo ""; return 0; }
  local line; line="$(grep -m1 "^${k}=" .env || true)"
  printf '%s' "${line#*=}"
}
# Define/atualiza uma variável no .env (substitui a linha se existir, senão adiciona).
set_env_var() {
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  [[ -f .env ]] && { grep -v "^${k}=" .env >"$tmp" 2>/dev/null || true; }
  printf '%s=%s\n' "$k" "$v" >>"$tmp"
  mv "$tmp" .env
  chmod 600 .env
}

# =============================================================================
#  INÍCIO
# =============================================================================
banner "SCSI — MONITORIA, OBSERVABILIDADE E LOGS"
echo "  Este guia sobe a stack de monitoramento (Prometheus + Grafana + Loki)."
echo "  ${GREY}Ela é SEPARADA do sistema: não derruba nem altera o que está no ar.${RESET}"
echo ""
echo "  ${BOLD}Pré-requisito:${RESET} o sistema já deve ter sido publicado antes"
echo "  (você já rodou o ${BOLD}setup_deploy.sh${RESET} e o site abre normalmente)."

# ── PASSO 1 — Localizar o projeto ──
step "Localizando a pasta do projeto"
REPO_DIR=""
if [[ -n "${BASH_SOURCE:-}" ]] && [[ -f "$(dirname "${BASH_SOURCE[0]}")/../monitoring-stack.yml" ]]; then
  REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
elif [[ -f "./monitoring-stack.yml" ]]; then
  REPO_DIR="$(pwd)"
else
  warn "Não encontrei o monitoring-stack.yml automaticamente."
  REPO_DIR="$(ask "Informe o caminho completo da pasta do projeto" "$HOME/scsi_v1")"
fi
cd "$REPO_DIR"
[[ -f monitoring-stack.yml ]] || { echo "  ${RED}monitoring-stack.yml não está em $REPO_DIR${RESET}"; exit 1; }
[[ -f .env ]] || { echo "  ${RED}.env não encontrado em $REPO_DIR — rode o setup_deploy.sh antes.${RESET}"; exit 1; }
ok "Projeto: ${BOLD}${REPO_DIR}${RESET}"

# ── PASSO 2 — Checar pré-requisitos (Docker / Swarm / Traefik) ──
step "Verificando o ambiente (Docker, Swarm e Traefik)"
have docker || { echo "  ${RED}Docker não encontrado. Rode o setup_deploy.sh primeiro.${RESET}"; exit 1; }
docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active \
  || { echo "  ${RED}Docker Swarm não está ativo. Rode o setup_deploy.sh primeiro.${RESET}"; exit 1; }
[[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null)" == "true" ]] \
  || { echo "  ${RED}Este nó não é manager do Swarm. Rode na VPS manager.${RESET}"; exit 1; }
ok "Docker Swarm ativo (este nó é manager)"

if docker network ls --format '{{.Name}}' | grep -qx traefik_public; then
  ok "Rede 'traefik_public' encontrada (sinal de que o sistema já foi publicado)"
else
  warn "Rede 'traefik_public' NÃO existe — isso indica que o sistema ainda não foi publicado."
  action_box \
    "Antes da monitoria, publique o sistema com:" \
    "    ${BOLD}bash scripts/setup_deploy.sh${RESET}" \
    "Depois rode este script novamente."
  exit 1
fi

# ── PASSO 3 — Carregar o domínio base do projeto ──
step "Lendo o domínio do projeto"
DOMAIN_BASE="$(get_env_var DOMAIN)"
if [[ -z "$DOMAIN_BASE" ]]; then
  warn "Variável DOMAIN não encontrada no .env."
  DOMAIN_BASE="$(ask "Qual o domínio base do projeto? (ex.: scsi.digital)" "")"
fi
info "Domínio base do projeto: ${BOLD}${DOMAIN_BASE:-<não definido>}${RESET}"

# ── PASSO 4 — Configurar o Grafana (domínio + senha) no .env ──
step "Configurando o acesso ao Grafana"
echo "  O Grafana é a tela onde você vê os gráficos. Ele será publicado num"
echo "  subdomínio com HTTPS automático (mesmo certificado curinga do projeto)."
echo ""

GRAFANA_DOMAIN_CUR="$(get_env_var GRAFANA_DOMAIN)"
DEFAULT_GRAFANA_DOMAIN="${GRAFANA_DOMAIN_CUR:-grafana.${DOMAIN_BASE:-exemplo.com}}"
GRAFANA_DOMAIN_VAL="$(ask "Subdomínio do Grafana" "$DEFAULT_GRAFANA_DOMAIN")"
set_env_var "GRAFANA_DOMAIN" "$GRAFANA_DOMAIN_VAL"
ok "GRAFANA_DOMAIN = ${BOLD}${GRAFANA_DOMAIN_VAL}${RESET}"

GRAFANA_USER_CUR="$(get_env_var GRAFANA_ADMIN_USER)"
GRAFANA_USER_VAL="$(ask "Usuário admin do Grafana" "${GRAFANA_USER_CUR:-admin}")"
set_env_var "GRAFANA_ADMIN_USER" "$GRAFANA_USER_VAL"

GRAFANA_PASS_CUR="$(get_env_var GRAFANA_ADMIN_PASSWORD)"
if [[ -n "$GRAFANA_PASS_CUR" && "$GRAFANA_PASS_CUR" != "troque-esta-senha-do-grafana" ]]; then
  skip "Senha do Grafana já definida no .env"
  GRAFANA_PASS_VAL="$GRAFANA_PASS_CUR"
else
  echo "  Defina a senha do admin do Grafana (ENTER em branco gera uma forte)."
  GRAFANA_PASS_VAL="$(ask_secret "Senha do admin do Grafana (ENTER = gerar)")"
  if [[ -z "$GRAFANA_PASS_VAL" ]]; then
    GRAFANA_PASS_VAL="$(gen_secret 20)"
    info "Senha gerada automaticamente."
  fi
  set_env_var "GRAFANA_ADMIN_PASSWORD" "$GRAFANA_PASS_VAL"
fi
ok "Credenciais do Grafana salvas no .env"

# ── PASSO 5 — Garantir defaults de retenção / namespace ──
step "Definindo retenção de métricas e logs"
[[ -n "$(get_env_var PROMETHEUS_RETENTION)" ]]      || set_env_var "PROMETHEUS_RETENTION" "15d"
[[ -n "$(get_env_var LOKI_RETENTION)" ]]            || set_env_var "LOKI_RETENTION" "360h"
[[ -n "$(get_env_var PROMETHEUS_METRIC_NAMESPACE)" ]] || set_env_var "PROMETHEUS_METRIC_NAMESPACE" "scsi"
info "Métricas guardadas por ${BOLD}$(get_env_var PROMETHEUS_RETENTION)${RESET}; logs por ${BOLD}$(get_env_var LOKI_RETENTION)${RESET}"
info "Namespace das métricas: ${BOLD}$(get_env_var PROMETHEUS_METRIC_NAMESPACE)${RESET}"

# ── PASSO 6 — Apontar o DNS do Grafana ──
step "Apontando o DNS do Grafana"
PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
echo "  Para o navegador encontrar o Grafana, crie um registro DNS apontando o"
echo "  subdomínio para o IP da sua VPS (no painel do seu provedor de DNS)."
action_box \
  "No seu DNS (ex.: Cloudflare), crie um registro:" \
  "    Tipo:   ${BOLD}A${RESET}" \
  "    Nome:   ${BOLD}${GRAFANA_DOMAIN_VAL}${RESET}" \
  "    Valor:  ${BOLD}${PUBLIC_IP:-<IP da sua VPS>}${RESET}" \
  "    Proxy:  pode deixar ligado (nuvem laranja) — o TLS é resolvido via DNS." \
  "" \
  "Se você usa o curinga *.${DOMAIN_BASE} no Cloudflare, talvez já esteja pronto."
if ! confirm_SN "O registro DNS do Grafana já está criado/propagando?"; then
  warn "Sem problema — você pode criar agora; a stack sobe mesmo assim."
  warn "O HTTPS pode levar 1-2 min para validar após o DNS propagar."
fi

# ── PASSO 7 — Criar a rede 'monitoring' ──
step "Criando a rede interna da monitoria"
if docker network ls --format '{{.Name}}' | grep -qx monitoring; then
  skip "Rede 'monitoring'"
else
  working "docker network create --driver overlay --attachable monitoring"
  docker network create --driver overlay --attachable monitoring >>"$LOG_FILE" 2>&1
  ok "Rede 'monitoring' criada"
fi

# ── PASSO 8 — Conferir os arquivos de configuração ──
step "Conferindo os arquivos de configuração da monitoria"
MISSING=0
for f in \
    "monitoring/prometheus/prometheus.yml" \
    "monitoring/prometheus/alert_rules.yml" \
    "monitoring/loki/loki-config.yml" \
    "monitoring/promtail/promtail-config.yml" \
    "monitoring/grafana/provisioning/datasources/datasources.yml" \
    "monitoring/grafana/provisioning/dashboards/dashboards.yml" \
    "monitoring/grafana/dashboards/scsi-overview.json" ; do
  if [[ -f "$REPO_DIR/$f" ]]; then ok "encontrado: $f"; else warn "AUSENTE: $f"; MISSING=1; fi
done
[[ "$MISSING" -eq 0 ]] || { echo "  ${RED}Faltam arquivos de config — verifique o clone do repositório.${RESET}"; exit 1; }
# O Prometheus precisa do caminho ABSOLUTO dos configs para o bind mount.
set_env_var "MONITORING_CONFIG_DIR" "$REPO_DIR/monitoring"
ok "MONITORING_CONFIG_DIR = ${BOLD}${REPO_DIR}/monitoring${RESET}"

# ── PASSO 9 — Lembrete sobre o /metrics do app ──
step "Sobre as métricas da aplicação (/metrics)"
echo "  O Prometheus coleta as métricas do Django no endpoint interno /metrics."
echo "  Esse endpoint passa a existir quando o app sobe com a biblioteca"
echo "  ${BOLD}django-prometheus${RESET} (já incluída no requirements.txt deste projeto)."
echo ""
echo "  Se o sistema já estava no ar ANTES desta atualização, rode um deploy do"
echo "  app para ativar o /metrics (isso é seguro e rápido):"
action_box \
  "Para ativar o /metrics no app (quando puder, sem pressa):" \
  "    ${BOLD}bash scripts/deploy.sh${RESET}" \
  "" \
  "A monitoria sobe mesmo sem isso: o alvo 'django' aparece como DOWN até lá."
echo "  ${GREY}(Não é obrigatório agora — você pode seguir e ativar depois.)${RESET}"

# ── PASSO 10 — Subir a stack de monitoramento ──
step "Subindo a stack de monitoramento"
echo "  Vamos carregar o .env e publicar a stack 'monitoring' no Swarm."
echo ""
# Carrega o .env de forma segura (NÃO faz source) e exporta para o stack deploy.
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in ''|\#*) continue ;; esac
  [ "${line#*=}" = "$line" ] && continue
  k="${line%%=*}"; v="${line#*=}"
  k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
  case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
  case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
  export "$k=$v"
done < .env

working "docker stack deploy -c monitoring-stack.yml monitoring"
docker stack deploy -c monitoring-stack.yml monitoring >>"$LOG_FILE" 2>&1
ok "Stack 'monitoring' publicada"

working "aguardando os serviços iniciarem (20s)"
sleep 20

# ── PASSO 11 — Verificar os serviços ──
step "Conferindo os serviços da monitoria"
echo ""
docker service ls --format "table {{.Name}}\t{{.Mode}}\t{{.Replicas}}\t{{.Image}}" \
  | grep -E "^NAME|^monitoring_" || true
echo ""
RUNNING="$(docker service ls --filter name=monitoring_ --format '{{.Replicas}}' | grep -c '/' || true)"
if [[ "$RUNNING" -ge 1 ]]; then
  ok "Serviços de monitoria publicados."
else
  warn "Os serviços ainda estão iniciando — confira em alguns segundos com:"
  echo "      docker service ls | grep monitoring_"
fi

# ── PASSO 12 — Como usar ──
banner "✅ MONITORIA NO AR"
echo ""
echo "  ${BOLD}Grafana:${RESET}  https://${GRAFANA_DOMAIN_VAL}"
echo "     usuário: ${BOLD}${GRAFANA_USER_VAL}${RESET}"
echo "     senha:   ${BOLD}${GRAFANA_PASS_VAL}${RESET}   ${GREY}(guarde com cuidado)${RESET}"
echo ""
echo "  ${BOLD}Já vem pronto (provisionado):${RESET}"
echo "     • Fontes de dados Prometheus e Loki conectadas"
echo "     • Dashboard ${BOLD}\"SCSI — Visão Geral\"${RESET} (pasta SCSI no Grafana)"
echo ""
echo "  ${BOLD}Dashboards extras da comunidade${RESET} (Grafana > Dashboards > Import > ID):"
echo "     • ${BOLD}1860${RESET}   Node Exporter Full (servidor) — funciona direto"
echo "     • ${BOLD}14282${RESET}  Cadvisor exporter (containers) — funciona direto"
echo "     • ${BOLD}21154${RESET}  Docker overview (cAdvisor + node)"
echo "     ${GREY}Dashboards de Django (9528/17658) precisam trocar o prefixo das${RESET}"
echo "     ${GREY}métricas para 'scsi_' — prefira o dashboard 'SCSI — Visão Geral'.${RESET}"
echo ""
echo "  ${BOLD}Ver os logs:${RESET} Grafana > Explore > fonte ${BOLD}Loki${RESET} > consulta:"
echo "     {stack=\"scsi_v1\"}"
echo ""
echo "  ${BOLD}Conferir os alvos:${RESET} Grafana > Explore > Prometheus > consulta: up"
echo "     (cada alvo deve aparecer com valor 1)"
echo ""
echo "  ${GREY}Redeploy futuro da monitoria:  bash scripts/deploy_monitoring.sh${RESET}"
echo "  ${GREY}Log deste guia:                ${LOG_FILE}${RESET}"
echo ""
_logfile "Setup de monitoria concluído com sucesso."
