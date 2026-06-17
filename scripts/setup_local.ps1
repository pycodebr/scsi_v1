<#
=============================================================================
 setup_local.ps1  —  Setup de ambiente de desenvolvimento (Windows 10/11)
=============================================================================
 Imersão IA Builders — workflow de IA Assistida (SCSI e qualquer outro projeto)

 O QUE ESTE SCRIPT FAZ (idempotente — pula o que já está instalado):
   1. Verifica/instala o gerenciador de pacotes do Windows (winget)
   2. Habilita o WSL2 (necessário para o Docker Desktop)
   3. Instala Python 3.13                      (se faltar)
   4. Instala Node.js LTS + npm/npx            (se faltar)
   5. Instala Docker Desktop                   (se faltar)
   6. Instala os CLIs de IA:
        - Claude Code  (@anthropic-ai/claude-code)
        - OpenCode     (opencode-ai)
        - Codex CLI    (@openai/codex)
   7. Instala git e ferramentas de apoio
   8. Cria a pasta do SEU projeto (pergunta onde e qual nome)
   9. Cria a .venv, instala Django, roda 'django-admin startproject core .'
      e gera o requirements.txt
  10. Cria um arquivo .env com as variáveis mais usadas (em branco)

 COMO RODAR (PowerShell COMO ADMINISTRADOR):
   1. Abra o menu Iniciar, digite "PowerShell"
   2. Clique com o botão direito > "Executar como administrador"
   3. Libere a execução do script nesta janela:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
   4. Rode:
        .\scripts\setup_local.ps1

 Em caso de erro, o motivo aparece na tela e um log completo fica em:
   .\setup_local.log
=============================================================================
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Libera a execução de scripts .ps1 APENAS nesta sessão (escopo Process: não pede
# admin e não altera nada permanente no sistema). É necessário porque o 'npm' no
# Windows é um 'npm.ps1' e, com a ExecutionPolicy padrão (Restricted), comandos
# como 'npm --version' / 'npm install -g' (e os shims claude/opencode/codex) seriam
# bloqueados com "a execução de scripts foi desabilitada neste sistema".
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch {}

# Evita que o pip escreva o aviso "A new release of pip..." no stderr — que, com
# ErrorActionPreference='Stop', seria interpretado como erro fatal pelo PowerShell.
$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'

$script:LogFile   = Join-Path (Get-Location) 'setup_local.log'
$script:Step      = 0
$script:TotalStep = 10
Set-Content -Path $script:LogFile -Value "[$(Get-Date -Format HH:mm:ss)] Início do setup" -Encoding utf8

# ─────────────────────────────────────────────────────────────────────────────
#  Logging visual e didático
# ─────────────────────────────────────────────────────────────────────────────
function Write-Log { param([string]$Msg) Add-Content -Path $script:LogFile -Value "[$(Get-Date -Format HH:mm:ss)] $Msg" }

function Show-Banner { param([string]$Text)
  Write-Host ""
  Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
  Write-Host ("║ {0,-60} ║" -f $Text) -ForegroundColor Cyan
  Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
}
function Show-Step { param([string]$Text)
  $script:Step++
  Write-Host ""
  Write-Host "▶ ETAPA $($script:Step)/$($script:TotalStep): $Text" -ForegroundColor Blue
  Write-Host "──────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
  Write-Log "ETAPA $($script:Step)/$($script:TotalStep): $Text"
}
function Info    { param([string]$m) Write-Host "  i  $m" -ForegroundColor Blue;   Write-Log "INFO  $m" }
function Ok      { param([string]$m) Write-Host "  OK $m" -ForegroundColor Green;  Write-Log "OK    $m" }
function Warn    { param([string]$m) Write-Host "  !  $m" -ForegroundColor Yellow; Write-Log "WARN  $m" }
function Skip    { param([string]$m) Write-Host "  -  $m (ja instalado - pulando)" -ForegroundColor DarkGray; Write-Log "SKIP  $m" }
function Working { param([string]$m) Write-Host "  .. $m..." -ForegroundColor Cyan; Write-Log "WORK  $m" }

# ─────────────────────────────────────────────────────────────────────────────
#  Saída segura — PAUSA antes de sair para a janela NÃO fechar e sumir o erro
# ─────────────────────────────────────────────────────────────────────────────
function Wait-Key {
  # Só pausa se houver interface interativa (não trava em automação/CI).
  if ([Environment]::UserInteractive) {
    try { Read-Host "`n  >> Pressione ENTER para fechar esta janela" | Out-Null } catch {}
  }
}
function Exit-Script { param([int]$Code = 0) Wait-Key; exit $Code }

# ─────────────────────────────────────────────────────────────────────────────
#  Tratamento de erros
# ─────────────────────────────────────────────────────────────────────────────
function Stop-OnError { param([System.Management.Automation.ErrorRecord]$Err)
  Write-Host ""
  Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Red
  Write-Host "║  ERRO — o script parou                                        ║" -ForegroundColor Red
  Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Red
  Write-Host "  Etapa....: $($script:Step)/$($script:TotalStep)" -ForegroundColor Red
  Write-Host "  Motivo...: $($Err.Exception.Message)" -ForegroundColor Red
  Write-Host "  Linha....: $($Err.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
  Write-Host "  Comando..: $($Err.InvocationInfo.Line.Trim())" -ForegroundColor Red
  Write-Host ""
  Write-Host "  O que fazer:" -ForegroundColor Yellow
  Write-Host "    1. Leia o 'Motivo' acima."
  Write-Host "    2. Log completo em: $($script:LogFile)"
  Write-Host "    3. Rode o script de novo — ele e idempotente e retoma de onde da."
  Write-Host ""
  Write-Log  "ERRO: $($Err.Exception.Message) | linha $($Err.InvocationInfo.ScriptLineNumber)"
  Write-Log  ($Err | Out-String)
  Wait-Key            # pausa para o usuario LER o erro antes da janela fechar
  exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
#  Utilitários
# ─────────────────────────────────────────────────────────────────────────────
function Test-Cmd { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Testa se um módulo Python está instalado SEM disparar erro fatal. Quando o módulo
# NÃO existe, o "import" joga um traceback no stderr; com ErrorActionPreference='Stop'
# isso viraria erro fatal (e o '2>$null' não suprime no PowerShell 5.1). Por isso
# baixamos o ErrorActionPreference só aqui e checamos o código de saída.
function Test-PyModule {
  param([string]$Module)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  try {
    & python -c "import $Module" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  } finally { $ErrorActionPreference = $prev }
}

function Update-Path {
  # Recarrega o PATH (Máquina + Usuário) para enxergar o que acabou de ser instalado
  $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [System.Environment]::GetEnvironmentVariable('Path','User')
}

function Invoke-Retry { param([scriptblock]$Action, [int]$Max = 3, [int]$Delay = 3)
  for ($i = 1; $i -le $Max; $i++) {
    try { & $Action; return $true }
    catch {
      if ($i -ge $Max) { throw }
      Warn "Tentativa $i/$Max falhou. Nova tentativa em ${Delay}s..."
      Start-Sleep -Seconds $Delay; $Delay *= 2
    }
  }
}

function Confirm-SN { param([string]$Prompt)
  while ($true) {
    $a = Read-Host "  ? $Prompt [S/N]"
    switch -Regex ($a.ToUpper()) {
      '^(S|SIM)$'     { return $true }
      '^(N|NAO|NÃO)$' { return $false }
      default         { Warn "Responda com S (sim) ou N (nao)." }
    }
  }
}

# Instala um pacote via winget de forma idempotente, verificando o comando alvo
function Install-Winget { param([string]$Id, [string]$CheckCmd, [string]$Label)
  if ($CheckCmd -and (Test-Cmd $CheckCmd)) { Skip $Label; return }
  Working "Instalando $Label ($Id)"
  Invoke-Retry { winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Add-Content $script:LogFile } | Out-Null
  Update-Path
  Ok "$Label instalado"
}

trap { Stop-OnError $_ }

# =============================================================================
#  ETAPA 0 — Boas-vindas + checagens
# =============================================================================
Show-Banner "SETUP DE AMBIENTE — Imersao IA Builders (Windows)"
Write-Host "  Este script prepara tudo que voce precisa para desenvolver."
Write-Host "  Ele e seguro e idempotente: pode rodar quantas vezes quiser."
Write-Host "  Log completo desta execucao: $($script:LogFile)" -ForegroundColor DarkGray

Show-Step "Verificando pre-requisitos (Administrador + winget)"

# Precisa ser Administrador (WSL e Docker exigem)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Warn "Este script PRECISA ser executado como Administrador."
  Write-Host "  Feche esta janela, abra o PowerShell com 'Executar como administrador' e rode de novo."
  Exit-Script 1
}
Ok "Rodando como Administrador"

# winget vem com o 'App Installer' da Microsoft Store no Windows 10/11
if (Test-Cmd winget) {
  Ok "winget disponivel ($(winget --version 2>$null))"
} else {
  Warn "winget nao encontrado. Instale o 'App Installer' pela Microsoft Store e rode de novo:"
  Write-Host "    https://apps.microsoft.com/detail/9NBLGGH4NNS1"
  Exit-Script 1
}

# =============================================================================
#  ETAPA 1 — Git + ferramentas de apoio
# =============================================================================
Show-Step "Git e ferramentas de apoio"
Install-Winget -Id 'Git.Git' -CheckCmd 'git' -Label 'Git'

# =============================================================================
#  ETAPA 2 — WSL2 (necessário para o Docker Desktop)
# =============================================================================
Show-Step "WSL2 (necessario para o Docker no Windows)"

$wslOk = $false
try { wsl --status *> $null; if ($LASTEXITCODE -eq 0) { $wslOk = $true } } catch { $wslOk = $false }

if ($wslOk) {
  Skip "WSL2"
} else {
  Working "Habilitando o WSL2 e instalando o Ubuntu (pode pedir REINICIAR)"
  try {
    wsl --install -d Ubuntu 2>&1 | Add-Content $script:LogFile
    Ok "WSL2 habilitado"
    Warn "IMPORTANTE: pode ser necessario REINICIAR o Windows agora."
    Warn "Apos reiniciar, rode este script de novo — ele continua de onde parou."
  } catch {
    Warn "Nao consegui habilitar o WSL automaticamente."
    Warn "Habilite manualmente (Admin): wsl --install   e reinicie o PC."
  }
}

# =============================================================================
#  ETAPA 3 — Python 3.13
# =============================================================================
Show-Step "Python 3.13"
# 'py -3.13' é a forma confiável de detectar uma versão específica no Windows
$pyHas313 = $false
try { & py -3.13 --version *> $null; if ($LASTEXITCODE -eq 0) { $pyHas313 = $true } } catch {}
if ($pyHas313) {
  Skip "Python 3.13 ($(py -3.13 --version 2>&1))"
} else {
  Install-Winget -Id 'Python.Python.3.13' -CheckCmd '' -Label 'Python 3.13'
}
Update-Path

# Resolve um executável de Python utilizável
$PythonExe = $null
foreach ($cand in @('py -3.13','python','python3')) {
  $parts = $cand.Split(' ')
  if (Test-Cmd $parts[0]) { $PythonExe = $cand; break }
}
if (-not $PythonExe) { throw "Python nao ficou disponivel no PATH. Feche e reabra o PowerShell e rode de novo." }
Info "Usando Python: $PythonExe"

# =============================================================================
#  ETAPA 4 — Node.js LTS + npm/npx
# =============================================================================
Show-Step "Node.js LTS + npm/npx"
if ((Test-Cmd node) -and (Test-Cmd npm)) {
  Skip "Node.js ($(node --version)) / npm ($(npm --version))"
} else {
  Install-Winget -Id 'OpenJS.NodeJS.LTS' -CheckCmd '' -Label 'Node.js LTS'
}
Update-Path

# =============================================================================
#  ETAPA 5 — Docker Desktop
# =============================================================================
Show-Step "Docker Desktop"
if (Test-Cmd docker) {
  Skip "Docker ($(docker --version 2>$null))"
} else {
  Install-Winget -Id 'Docker.DockerDesktop' -CheckCmd '' -Label 'Docker Desktop'
  Warn "Abra o 'Docker Desktop' uma vez para concluir a configuracao."
  Warn "Ele usara o WSL2 como backend. Confirme depois com: docker run hello-world"
}

# =============================================================================
#  ETAPA 6 — CLIs de IA (Claude Code, OpenCode, Codex)
# =============================================================================
Show-Step "CLIs de IA (Claude Code · OpenCode · Codex)"
function Install-NpmCli { param([string]$Bin,[string]$Pkg,[string]$Label)
  if (Test-Cmd $Bin) { Skip $Label; return }
  Working "Instalando $Label ($Pkg)"
  try {
    Invoke-Retry { npm install -g $Pkg 2>&1 | Add-Content $script:LogFile } | Out-Null
    Update-Path
    Ok "$Label instalado"
  } catch {
    Warn "Nao consegui instalar $Label. Instale depois com: npm i -g $Pkg"
  }
}
if (Test-Cmd npm) {
  Install-NpmCli -Bin 'claude'   -Pkg '@anthropic-ai/claude-code' -Label 'Claude Code CLI'
  Install-NpmCli -Bin 'opencode' -Pkg 'opencode-ai'               -Label 'OpenCode CLI'
  Install-NpmCli -Bin 'codex'    -Pkg '@openai/codex'             -Label 'Codex CLI'
} else {
  Warn "npm indisponivel (talvez precise reabrir o PowerShell). Pulei os CLIs de IA."
}

# =============================================================================
#  ETAPA 7 — Dados do projeto (onde e qual nome)
# =============================================================================
Show-Step "Dados do seu projeto"
Write-Host "  Agora vamos criar a pasta do seu projeto."
Write-Host ""

$DefaultDir = Join-Path $env:USERPROFILE 'projects'
$BaseDir = Read-Host "  Onde deseja criar a pasta do seu projeto? [$DefaultDir]"
if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = $DefaultDir }

while ($true) {
  $ProjectName = Read-Host "  Qual o nome do projeto? (nao use espacos)"
  if ([string]::IsNullOrWhiteSpace($ProjectName)) { Warn "O nome nao pode ser vazio." }
  elseif ($ProjectName -match '\s') { Warn "O nome nao pode ter espacos. Use _ ou - (ex: scsi_v1)." }
  elseif ($ProjectName -notmatch '^[A-Za-z0-9._-]+$') { Warn "Use apenas letras, numeros, ponto, hifen ou underline." }
  else { break }
}
$ProjectDir = Join-Path $BaseDir $ProjectName
Info "Caminho do projeto: $ProjectDir"

# =============================================================================
#  ETAPA 8 — Criação da pasta (com checagem de pasta existente)
# =============================================================================
Show-Step "Criando a pasta do projeto"
if (Test-Path $ProjectDir) {
  Warn "A pasta '$ProjectDir' JA EXISTE."
  if ((Get-ChildItem -Force $ProjectDir | Measure-Object).Count -gt 0) {
    Warn "E ela NAO esta vazia. Criar o projeto aqui pode sobrescrever arquivos."
  }
  if (Confirm-SN "Deseja MESMO continuar usando esta pasta existente?") {
    Ok "Ok, continuando na pasta existente."
  } else {
    Info "Operacao cancelada. Rode o script de novo com outro caminho/nome."
    Exit-Script 0
  }
} else {
  Working "Criando $ProjectDir"
  New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
  Ok "Pasta criada"
}
Set-Location $ProjectDir

# =============================================================================
#  ETAPA 9 — .venv + Django + startproject + requirements.txt
# =============================================================================
Show-Step "Ambiente Python do projeto (.venv + Django)"

if (Test-Path ".venv") {
  Skip ".venv ja existe"
} else {
  Working "Criando ambiente virtual (.venv)"
  $pyParts = $PythonExe.Split(' ')
  if ($pyParts.Length -gt 1) {
    & $pyParts[0] $pyParts[1..($pyParts.Length-1)] -m venv .venv
  } else {
    & $pyParts[0] -m venv .venv
  }
  Ok ".venv criada"
}

# Ativa a venv nesta sessão
$Activate = Join-Path $ProjectDir ".venv\Scripts\Activate.ps1"
. $Activate
Ok "Ambiente virtual ativado ($(python --version 2>&1))"

Working "Atualizando pip"
Invoke-Retry { python -m pip install --upgrade pip 2>&1 | Add-Content $script:LogFile } | Out-Null
Ok "pip atualizado"

if (Test-PyModule 'django') {
  Skip "Django ($(python -c 'import django; print(django.get_version())'))"
} else {
  Working "Instalando Django"
  Invoke-Retry { pip install Django 2>&1 | Add-Content $script:LogFile } | Out-Null
  Ok "Django instalado ($(python -c 'import django; print(django.get_version())'))"
}

if (Test-Path "manage.py") {
  Skip "Projeto Django ja existe (manage.py encontrado)"
} else {
  Working "Criando projeto Django: django-admin startproject core ."
  django-admin startproject core .
  Ok "Projeto 'core' criado"
}

Working "Gerando requirements.txt (pip freeze)"
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
pip freeze 2>$null | Out-File -Encoding utf8 requirements.txt
$ErrorActionPreference = $prevEAP
Ok "requirements.txt gerado"

# =============================================================================
#  ETAPA 10 — .env com as variáveis mais usadas (em branco)
# =============================================================================
Show-Step "Arquivo .env (variaveis de ambiente)"
if (Test-Path ".env") {
  Skip ".env ja existe (nao foi sobrescrito)"
} else {
  Working "Criando .env modelo"
  $envContent = @'
# =============================================================================
#  .env — variaveis de ambiente do projeto (PREENCHA antes de rodar)
#  Nunca versione este arquivo com segredos reais (mantenha no .gitignore).
# =============================================================================

# --- Django ---
SECRET_KEY=
DEBUG=True
ALLOWED_HOSTS=localhost,127.0.0.1
CSRF_TRUSTED_ORIGINS=http://localhost:8000,http://127.0.0.1:8000

# --- Localizacao ---
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
'@
  Set-Content -Path ".env" -Value $envContent -Encoding utf8
  Ok ".env criado (variaveis em branco, prontas para preencher)"
}

if (-not (Test-Path ".gitignore")) {
  Set-Content -Path ".gitignore" -Value ".venv/`n__pycache__/`n*.pyc`n.env`ndb.sqlite3`nstaticfiles/`nmedia/" -Encoding utf8
  Ok ".gitignore criado (protege .venv, .env e db.sqlite3)"
}

# =============================================================================
#  FIM — Resumo + próximos passos
# =============================================================================
Show-Banner "TUDO PRONTO!"
Write-Host "  Seu ambiente e seu projeto estao configurados."
Write-Host ""
Write-Host "  Resumo:"
Write-Host "    * Projeto.: $ProjectDir"
Write-Host "    * Python..: $(python --version 2>&1)"
if (Test-Cmd node)   { Write-Host "    * Node....: $(node --version)" }
if (Test-Cmd docker) { Write-Host "    * Docker..: $(docker --version 2>$null)" }
Write-Host ""
Write-Host "  Proximos passos:"
Write-Host "    1. cd $ProjectDir"
Write-Host "    2. .\.venv\Scripts\Activate.ps1     # ativar o ambiente"
Write-Host "    3. python manage.py runserver       # testar o Django"
Write-Host "    4. Preencha o arquivo .env com seus valores"
Write-Host "    5. Abra seu CLI de IA na pasta: claude (ou opencode / codex)"
Write-Host ""
Warn "Se voce acabou de habilitar o WSL2/Docker, talvez precise REINICIAR o Windows."
Write-Log "CONCLUIDO com sucesso — projeto em $ProjectDir"
Wait-Key   # mantem a janela aberta para o usuario ler o resumo
