#!/usr/bin/env bash
# =============================================================================
#  setup_local.sh  —  Setup de ambiente de desenvolvimento (Linux e macOS)
# =============================================================================
#  Imersão IA Builders — workflow de IA Assistida (SCSI e qualquer outro projeto)
#
#  O QUE ESTE SCRIPT FAZ (de forma idempotente — pula o que já está instalado):
#    1. Detecta seu sistema operacional e gerenciador de pacotes
#    2. Instala Python 3.13 + venv               (se faltar)
#    3. Instala Node.js + npm/npx                 (se faltar)
#    4. Instala Docker + Docker Compose           (se faltar)
#    5. Instala os CLIs de IA:
#         - Claude Code  (@anthropic-ai/claude-code)
#         - OpenCode     (opencode-ai)
#         - Codex CLI    (@openai/codex)
#    6. Instala ferramentas de apoio (git, curl, etc.)
#    7. Cria a pasta do SEU projeto (pergunta onde e qual nome)
#    8. Cria a .venv, instala Django, roda `django-admin startproject core .`
#       e gera o requirements.txt
#    9. Cria um arquivo .env com as variáveis mais usadas (em branco)
#
#  USO:
#    bash scripts/setup_local.sh
#    # ou torne executável:  chmod +x scripts/setup_local.sh && ./scripts/setup_local.sh
#
#  Em caso de erro, o script mostra o motivo, a linha e o comando que falhou,
#  e grava um log completo em:  ./setup_local.log
# =============================================================================

set -Eeuo pipefail

# Se a entrada padrão NÃO for um terminal (ex.: rodando via 'curl ... | bash'),
# redireciona a entrada para o terminal real — assim as perguntas funcionam
# mesmo quando o script chega pelo "cano" do curl.
if [[ ! -t 0 && -e /dev/tty ]]; then exec </dev/tty; fi

# ─────────────────────────────────────────────────────────────────────────────
#  Constantes / Configuração
# ─────────────────────────────────────────────────────────────────────────────
readonly PYTHON_TARGET="3.13"            # versão alvo do Python
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="$(pwd)/setup_local.log"
TOTAL_STEPS=9
CURRENT_STEP=0

# ─────────────────────────────────────────────────────────────────────────────
#  Cores e símbolos (com fallback se o terminal não suportar)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD="$(tput bold)";   RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"; GREY="$(tput setaf 8)"
else
  BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; GREY=""
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Logging visual e didático
# ─────────────────────────────────────────────────────────────────────────────
# Tudo também é gravado (sem cores) no LOG_FILE para diagnóstico.
_logfile() { printf '%s %s\n' "[$(date '+%H:%M:%S')]" "$1" >>"$LOG_FILE"; }

banner() {
  echo ""
  echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  printf "${BOLD}${CYAN}║${RESET} %-60s ${BOLD}${CYAN}║${RESET}\n" "$1"
  echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
}

step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  echo ""
  echo "${BOLD}${BLUE}▶ ETAPA ${CURRENT_STEP}/${TOTAL_STEPS}:${RESET} ${BOLD}$1${RESET}"
  echo "${GREY}──────────────────────────────────────────────────────────────${RESET}"
  _logfile "ETAPA ${CURRENT_STEP}/${TOTAL_STEPS}: $1"
}

info()    { echo "  ${BLUE}ℹ${RESET}  $1";        _logfile "INFO  $1"; }
ok()      { echo "  ${GREEN}✔${RESET}  $1";        _logfile "OK    $1"; }
warn()    { echo "  ${YELLOW}⚠${RESET}  $1";        _logfile "WARN  $1"; }
skip()    { echo "  ${GREEN}✓${RESET}  ${GREY}$1 (já instalado — pulando)${RESET}"; _logfile "SKIP  $1"; }
working() { echo "  ${CYAN}⏳${RESET} $1...";       _logfile "WORK  $1"; }

# ─────────────────────────────────────────────────────────────────────────────
#  Tratamento de erros — mostra motivo, linha, comando e onde parou
# ─────────────────────────────────────────────────────────────────────────────
on_error() {
  local exit_code=$1 line=$2 cmd=$3
  echo ""
  echo "${BOLD}${RED}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo "${BOLD}${RED}║  ❌ ERRO — o script parou                                     ║${RESET}"
  echo "${BOLD}${RED}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo "  ${RED}Etapa........:${RESET} ${CURRENT_STEP}/${TOTAL_STEPS}"
  echo "  ${RED}Linha........:${RESET} ${line}"
  echo "  ${RED}Comando......:${RESET} ${cmd}"
  echo "  ${RED}Código saída.:${RESET} ${exit_code}"
  echo ""
  echo "  ${YELLOW}O que fazer:${RESET}"
  echo "    1. Leia a mensagem de erro logo acima desta caixa."
  echo "    2. O log completo está em: ${BOLD}${LOG_FILE}${RESET}"
  echo "    3. Rode o script de novo — ele é idempotente e retoma de onde dá."
  echo "    4. Se persistir, copie o log e peça ajuda ao seu CLI de IA."
  echo ""
  _logfile "ERRO exit=$exit_code line=$line cmd=<$cmd> step=$CURRENT_STEP/$TOTAL_STEPS"
  exit "$exit_code"
}
trap 'on_error $? ${LINENO} "$BASH_COMMAND"' ERR

# ─────────────────────────────────────────────────────────────────────────────
#  Utilitários
# ─────────────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# Retenta um comando até 3x com backoff (útil para downloads/instalações de rede)
retry() {
  local max=3 attempt=1 delay=3
  until "$@"; do
    if (( attempt >= max )); then
      warn "Falhou após ${max} tentativas: $*"
      return 1
    fi
    warn "Tentativa ${attempt}/${max} falhou. Nova tentativa em ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1)); delay=$((delay * 2))
  done
}

# Pergunta sim/não exigindo S ou N explícito
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

# ─────────────────────────────────────────────────────────────────────────────
#  Detecção de SO e gerenciador de pacotes
# ─────────────────────────────────────────────────────────────────────────────
OS=""           # macos | linux
DISTRO=""       # debian | fedora | arch | ...
PKG=""          # brew | apt | dnf | pacman | zypper
SUDO=""         # "" ou "sudo"

detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *) echo "SO não suportado: $(uname -s). Use Linux ou macOS (no Windows use setup_local.ps1)."; exit 1 ;;
  esac

  if [[ "$OS" == "macos" ]]; then
    PKG="brew"
  else
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      DISTRO="${ID:-}${ID_LIKE:+ $ID_LIKE}"
    fi
    if   have apt-get; then PKG="apt"
    elif have dnf;     then PKG="dnf"
    elif have pacman;  then PKG="pacman"
    elif have zypper;  then PKG="zypper"
    else
      echo "Não encontrei um gerenciador de pacotes suportado (apt/dnf/pacman/zypper)."
      exit 1
    fi
    # Define SUDO se não formos root
    if [[ "$(id -u)" -ne 0 ]]; then
      have sudo || { echo "Preciso de 'sudo' para instalar pacotes no Linux."; exit 1; }
      SUDO="sudo"
    fi
  fi

  info "Sistema......: ${BOLD}${OS}${RESET}${DISTRO:+ (${DISTRO})}"
  info "Gerenciador..: ${BOLD}${PKG}${RESET}"
}

# Atualiza índice de pacotes (apenas 1x por execução, quando aplicável)
PKG_UPDATED=0
pkg_update_once() {
  [[ "$PKG_UPDATED" -eq 1 ]] && return 0
  case "$PKG" in
    apt)    working "Atualizando índice de pacotes (apt update)"; retry $SUDO apt-get update -y >>"$LOG_FILE" 2>&1 ;;
    dnf)    : ;;  # dnf resolve metadados automaticamente
    pacman) working "Sincronizando pacotes (pacman -Sy)"; retry $SUDO pacman -Sy --noconfirm >>"$LOG_FILE" 2>&1 ;;
    zypper) working "Atualizando repositórios (zypper refresh)"; retry $SUDO zypper --non-interactive refresh >>"$LOG_FILE" 2>&1 ;;
  esac
  PKG_UPDATED=1
}

# Instala um pacote pelo gerenciador nativo
pkg_install() {
  local pkg="$1"
  pkg_update_once
  case "$PKG" in
    brew)   retry brew install "$pkg" >>"$LOG_FILE" 2>&1 ;;
    apt)    retry $SUDO apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
    dnf)    retry $SUDO dnf install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
    pacman) retry $SUDO pacman -S --noconfirm "$pkg" >>"$LOG_FILE" 2>&1 ;;
    zypper) retry $SUDO zypper --non-interactive install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
  esac
}

# =============================================================================
#  ETAPA 0 — Boas-vindas + pré-requisitos
# =============================================================================
: >"$LOG_FILE"   # zera o log desta execução
banner "🚀  SETUP DE AMBIENTE — Imersão IA Builders"
echo "  Este script prepara tudo que você precisa para desenvolver."
echo "  Ele é ${BOLD}seguro${RESET} e ${BOLD}idempotente${RESET}: pode rodar quantas vezes quiser."
echo "  Log completo desta execução: ${GREY}${LOG_FILE}${RESET}"

step "Detectando seu sistema e ferramentas base"
detect_os

# Homebrew é pré-requisito no macOS
if [[ "$OS" == "macos" ]] && ! have brew; then
  working "Instalando Homebrew (gerenciador de pacotes do macOS)"
  retry /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Carrega o brew no PATH desta sessão (Apple Silicon e Intel)
  if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then eval "$(/usr/local/bin/brew shellenv)"; fi
  ok "Homebrew instalado"
elif [[ "$OS" == "macos" ]]; then
  skip "Homebrew"
fi

# Ferramentas base mínimas
for tool in git curl; do
  if have "$tool"; then skip "$tool"; else working "Instalando $tool"; pkg_install "$tool"; ok "$tool instalado"; fi
done
# Em Debian/Ubuntu, garante suporte a repositórios https e build de pacotes Python
if [[ "$PKG" == "apt" ]]; then
  pkg_install ca-certificates || true
  pkg_install software-properties-common || true
fi

# =============================================================================
#  ETAPA 1 — Python 3.13 + venv
# =============================================================================
step "Python ${PYTHON_TARGET} + venv"

python_ok() {
  # Verdadeiro se existe um python com a versão alvo e o módulo venv funciona
  local bin
  for bin in "python${PYTHON_TARGET}" python3 python; do
    if have "$bin" && "$bin" -c "import sys; exit(0 if sys.version_info[:2]==(${PYTHON_TARGET/./, }) else 1)" 2>/dev/null; then
      if "$bin" -c "import venv" 2>/dev/null; then PYTHON_BIN="$bin"; return 0; fi
    fi
  done
  return 1
}

PYTHON_BIN=""
if python_ok; then
  skip "Python ${PYTHON_TARGET} ($("$PYTHON_BIN" --version 2>&1))"
else
  working "Instalando Python ${PYTHON_TARGET}"
  case "$PKG" in
    brew)
      pkg_install "python@${PYTHON_TARGET}"
      ;;
    apt)
      # deadsnakes oferece versões recentes de Python no Ubuntu/Debian
      if ! apt-cache show "python${PYTHON_TARGET}" >/dev/null 2>&1; then
        info "Adicionando o PPA deadsnakes (Python recente)"
        pkg_install software-properties-common
        retry $SUDO add-apt-repository -y ppa:deadsnakes/ppa >>"$LOG_FILE" 2>&1 || \
          warn "Não consegui adicionar o deadsnakes; tentando pacote nativo da distro."
        PKG_UPDATED=0; pkg_update_once
      fi
      pkg_install "python${PYTHON_TARGET}" || pkg_install python3
      pkg_install "python${PYTHON_TARGET}-venv" || pkg_install python3-venv || true
      pkg_install "python${PYTHON_TARGET}-dev"  || true
      ;;
    dnf)
      pkg_install "python${PYTHON_TARGET/./}" || pkg_install "python${PYTHON_TARGET}" || pkg_install python3
      ;;
    pacman)
      pkg_install python
      ;;
    zypper)
      pkg_install "python${PYTHON_TARGET/./}" || pkg_install python3
      ;;
  esac
  if python_ok; then
    ok "Python instalado: $("$PYTHON_BIN" --version 2>&1)"
  else
    # fallback: qualquer python3 com venv serve para continuar
    if have python3 && python3 -c "import venv" 2>/dev/null; then
      PYTHON_BIN="python3"
      warn "Python ${PYTHON_TARGET} exato não disponível; usando $(python3 --version 2>&1)."
    else
      echo "Não consegui deixar um Python utilizável com venv. Veja $LOG_FILE."; exit 1
    fi
  fi
fi

# =============================================================================
#  ETAPA 2 — Node.js + npm/npx
# =============================================================================
step "Node.js + npm/npx"

if have node && have npm && have npx; then
  skip "Node.js ($(node --version)) / npm ($(npm --version))"
else
  working "Instalando Node.js LTS"
  case "$PKG" in
    brew)
      pkg_install node
      ;;
    apt)
      # NodeSource fornece o Node LTS mais atual para Debian/Ubuntu
      retry bash -c "curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -" >>"$LOG_FILE" 2>&1 \
        || warn "NodeSource falhou; tentando pacote da distro."
      pkg_install nodejs || true
      have npm || pkg_install npm || true
      ;;
    dnf)
      retry bash -c "curl -fsSL https://rpm.nodesource.com/setup_lts.x | $SUDO bash -" >>"$LOG_FILE" 2>&1 || true
      pkg_install nodejs || true
      ;;
    pacman)
      pkg_install nodejs; pkg_install npm
      ;;
    zypper)
      pkg_install nodejs; pkg_install npm || true
      ;;
  esac
  if have node && have npm; then
    ok "Node.js instalado: $(node --version) (npm $(npm --version))"
  else
    echo "Não consegui instalar o Node.js. Veja $LOG_FILE."; exit 1
  fi
fi

# =============================================================================
#  ETAPA 3 — Docker + Docker Compose
# =============================================================================
step "Docker + Docker Compose"

if have docker && docker compose version >/dev/null 2>&1; then
  skip "Docker ($(docker --version | awk '{print $3}' | tr -d ,))"
elif have docker; then
  skip "Docker (instalado)"
  warn "Plugin 'docker compose' não detectado — verifique sua instalação do Docker."
else
  working "Instalando Docker"
  case "$OS" in
    macos)
      # No macOS o Docker roda via Docker Desktop (aplicativo)
      retry brew install --cask docker >>"$LOG_FILE" 2>&1
      ok "Docker Desktop instalado"
      warn "Abra o aplicativo ${BOLD}Docker${RESET} uma vez para finalizar a configuração."
      warn "Depois confirme com: ${BOLD}docker run hello-world${RESET}"
      ;;
    linux)
      # Script oficial de conveniência da Docker (cobre as principais distros)
      working "Baixando e executando o instalador oficial da Docker"
      retry bash -c "curl -fsSL https://get.docker.com | $SUDO sh" >>"$LOG_FILE" 2>&1
      # Habilita e inicia o serviço, se houver systemd
      if have systemctl; then
        $SUDO systemctl enable --now docker >>"$LOG_FILE" 2>&1 || true
      fi
      # Adiciona o usuário ao grupo docker (evita precisar de sudo)
      if [[ -n "$SUDO" ]]; then
        $SUDO groupadd -f docker >>"$LOG_FILE" 2>&1 || true
        $SUDO usermod -aG docker "$USER" >>"$LOG_FILE" 2>&1 || true
        warn "Você foi adicionado ao grupo 'docker'. ${BOLD}Faça logout/login${RESET} (ou rode 'newgrp docker') para usar o Docker sem sudo."
      fi
      ok "Docker instalado"
      ;;
  esac
fi

# =============================================================================
#  ETAPA 4 — CLIs de IA (Claude Code, OpenCode, Codex)
# =============================================================================
step "CLIs de IA (Claude Code · OpenCode · Codex)"

# Instala um pacote npm global de forma idempotente (verifica o binário)
npm_global_cli() {
  local bin="$1" pkg="$2" label="$3"
  if have "$bin"; then
    skip "$label"
  else
    working "Instalando $label  ($pkg)"
    if retry npm install -g "$pkg" >>"$LOG_FILE" 2>&1; then
      ok "$label instalado"
    else
      warn "Não consegui instalar $label via npm. Você pode instalar depois com: npm i -g $pkg"
    fi
  fi
}

if have npm; then
  npm_global_cli claude   "@anthropic-ai/claude-code" "Claude Code CLI"
  npm_global_cli opencode "opencode-ai"               "OpenCode CLI"
  npm_global_cli codex    "@openai/codex"             "Codex CLI"
else
  warn "npm indisponível — pulei a instalação dos CLIs de IA."
fi

# =============================================================================
#  ETAPA 5 — Coleta dos dados do projeto (onde e qual nome)
# =============================================================================
step "Dados do seu projeto"

echo "  Agora vamos criar a pasta do seu projeto."
echo ""

# Onde criar
DEFAULT_DIR="$HOME/projects"
while true; do
  read -r -p "  ${CYAN}📁 Onde deseja criar a pasta do seu projeto?${RESET} [${DEFAULT_DIR}]: " BASE_DIR || true
  BASE_DIR="${BASE_DIR:-$DEFAULT_DIR}"
  BASE_DIR="${BASE_DIR/#\~/$HOME}"     # expande ~
  [[ -n "$BASE_DIR" ]] && break
  warn "Informe um diretório válido."
done

# Nome do projeto (sem espaços)
while true; do
  read -r -p "  ${CYAN}🏷  Qual o nome do projeto? (não use espaços)${RESET}: " PROJECT_NAME || true
  if [[ -z "$PROJECT_NAME" ]]; then
    warn "O nome não pode ser vazio."
  elif [[ "$PROJECT_NAME" =~ [[:space:]] ]]; then
    warn "O nome não pode ter espaços. Use _ ou - (ex: scsi_v1)."
  elif [[ ! "$PROJECT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
    warn "Use apenas letras, números, ponto, hífen ou underline."
  else
    break
  fi
done

PROJECT_DIR="${BASE_DIR%/}/${PROJECT_NAME}"
info "Caminho do projeto: ${BOLD}${PROJECT_DIR}${RESET}"

# =============================================================================
#  ETAPA 6 — Criação da pasta (com checagem de pasta existente)
# =============================================================================
step "Criando a pasta do projeto"

if [[ -d "$PROJECT_DIR" ]]; then
  warn "A pasta ${BOLD}${PROJECT_DIR}${RESET} JÁ EXISTE."
  if [[ -n "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]]; then
    warn "E ela NÃO está vazia. Criar o projeto aqui pode sobrescrever arquivos."
  fi
  if confirm_SN "Deseja MESMO continuar usando esta pasta existente?"; then
    ok "Ok, continuando na pasta existente."
  else
    info "Operação cancelada pelo usuário. Rode o script de novo com outro caminho/nome."
    exit 0
  fi
else
  working "Criando ${PROJECT_DIR}"
  mkdir -p "$PROJECT_DIR"
  ok "Pasta criada"
fi
cd "$PROJECT_DIR"

# =============================================================================
#  ETAPA 7 — .venv + Django + startproject core . + requirements.txt
# =============================================================================
step "Ambiente Python do projeto (.venv + Django)"

if [[ -d ".venv" ]]; then
  skip ".venv já existe"
else
  working "Criando ambiente virtual (.venv) com ${PYTHON_BIN}"
  "$PYTHON_BIN" -m venv .venv
  ok ".venv criada"
fi

# Ativa a venv NESTA sessão do script
# shellcheck disable=SC1091
source .venv/bin/activate
ok "Ambiente virtual ativado ($(python --version 2>&1))"

working "Atualizando pip"
retry python -m pip install --upgrade pip >>"$LOG_FILE" 2>&1
ok "pip atualizado ($(pip --version | awk '{print $2}'))"

# Instala Django (se ainda não estiver na venv)
if python -c "import django" 2>/dev/null; then
  skip "Django ($(python -c 'import django; print(django.get_version())'))"
else
  working "Instalando Django"
  retry pip install "Django" >>"$LOG_FILE" 2>&1
  ok "Django instalado ($(python -c 'import django; print(django.get_version())'))"
fi

# Cria o projeto Django 'core' no diretório atual (se ainda não existir)
if [[ -f "manage.py" ]]; then
  skip "Projeto Django já existe (manage.py encontrado)"
else
  working "Criando projeto Django: django-admin startproject core ."
  django-admin startproject core .
  ok "Projeto 'core' criado"
fi

# Gera/atualiza requirements.txt
working "Gerando requirements.txt (pip freeze)"
pip freeze >requirements.txt
ok "requirements.txt gerado ($(wc -l <requirements.txt | tr -d ' ') pacotes)"

# =============================================================================
#  ETAPA 8 — Arquivo .env com as variáveis mais usadas (em branco)
# =============================================================================
step "Arquivo .env (variáveis de ambiente)"

if [[ -f ".env" ]]; then
  skip ".env já existe (não foi sobrescrito)"
else
  working "Criando .env modelo"
  cat >.env <<'ENVEOF'
# =============================================================================
#  .env — variáveis de ambiente do projeto (PREENCHA antes de rodar)
#  Nunca versione este arquivo com segredos reais (mantenha no .gitignore).
# =============================================================================

# --- Django ---
SECRET_KEY=
DEBUG=True
ALLOWED_HOSTS=localhost,127.0.0.1
CSRF_TRUSTED_ORIGINS=http://localhost:8000,http://127.0.0.1:8000

# --- Localização ---
TIME_ZONE=America/Sao_Paulo
LANGUAGE_CODE=pt-br

# --- Banco de dados (PostgreSQL) ---
POSTGRES_DB=
POSTGRES_USER=
POSTGRES_PASSWORD=
DATABASE_URL=

# --- RabbitMQ ---
RABBITMQ_DEFAULT_USER=
RABBITMQ_DEFAULT_PASS=

# --- Celery / Redis ---
CELERY_BROKER_URL=
CELERY_RESULT_BACKEND=
REDIS_URL=

# --- IA / LLM ---
OPENAI_API_KEY=
OPENAI_MODEL=
ANTHROPIC_API_KEY=
LANGSMITH_API_KEY=

# --- E-mail (SMTP) ---
EMAIL_BACKEND=django.core.mail.backends.console.EmailBackend
EMAIL_HOST=
EMAIL_PORT=
EMAIL_HOST_USER=
EMAIL_HOST_PASSWORD=
ENVEOF
  ok ".env criado (variáveis em branco, prontas para preencher)"
fi

# Cria um .gitignore mínimo se o projeto ainda não tiver (protege .venv e .env)
if [[ ! -f ".gitignore" ]]; then
  cat >.gitignore <<'GITEOF'
.venv/
__pycache__/
*.pyc
.env
db.sqlite3
staticfiles/
media/
GITEOF
  ok ".gitignore criado (protege .venv, .env e db.sqlite3)"
fi

# =============================================================================
#  FIM — Resumo + próximos passos
# =============================================================================
banner "✅  TUDO PRONTO!"
echo "  Seu ambiente e seu projeto estão configurados."
echo ""
echo "  ${BOLD}Resumo:${RESET}"
echo "    • Projeto.....: ${BOLD}${PROJECT_DIR}${RESET}"
echo "    • Python......: $(python --version 2>&1)"
have node   && echo "    • Node........: $(node --version)"
have docker && echo "    • Docker......: $(docker --version 2>/dev/null | awk '{print $3}' | tr -d , || echo 'instalado')"
have claude   && echo "    • Claude Code.: ok"
have opencode && echo "    • OpenCode....: ok"
have codex    && echo "    • Codex.......: ok"
echo ""
echo "  ${BOLD}Próximos passos:${RESET}"
echo "    1. ${CYAN}cd ${PROJECT_DIR}${RESET}"
echo "    2. ${CYAN}source .venv/bin/activate${RESET}     ${GREY}# ativar o ambiente${RESET}"
echo "    3. ${CYAN}python manage.py runserver${RESET}    ${GREY}# testar o Django${RESET}"
echo "    4. Preencha o arquivo ${BOLD}.env${RESET} com seus valores"
echo "    5. Abra seu CLI de IA na pasta: ${CYAN}claude${RESET} (ou ${CYAN}opencode${RESET} / ${CYAN}codex${RESET})"
echo ""
if [[ "$OS" == "linux" ]] && have docker; then
  echo "  ${YELLOW}Lembrete Docker:${RESET} se 'docker ps' pedir sudo, faça logout/login uma vez."
  echo ""
fi
_logfile "CONCLUÍDO com sucesso — projeto em $PROJECT_DIR"
