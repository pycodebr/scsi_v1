# SCSI v1

Sistema de Corretora de Seguros (Django 6, multi-tenant, Celery, DRF, IA/MCP).

## Rodar localmente

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # preencha SECRET_KEY (obrigatória, sem default) e DEBUG=True
python manage.py migrate
python manage.py runserver
```

## Login com Google (opcional, novo)

1. Crie credenciais OAuth em https://console.cloud.google.com/apis/credentials
2. Callback: `https://SEU-DOMINIO/social/google/login/callback/`
3. Preencha no `.env`:

```env
GOOGLE_OAUTH_CLIENT_ID=xxx.apps.googleusercontent.com
GOOGLE_OAUTH_SECRET=GOCSPX-xxx
STAFF_EMAILS=admin@scsi.digital   # opcional: e-mails com staff garantido
```

O login local por e-mail continua funcionando normalmente.

## Segurança (atualização 2026-09)

- `SECRET_KEY` sem default inseguro (falha cedo se ausente) — fix do report-security.md §1.1
- `DEBUG` default `False` (fail-safe) — §1.2
- Headers sempre ativos: `Referrer-Policy`, `COOP`, `SESSION_COOKIE_HTTPONLY/SAMESITE`, `CSRF_COOKIE_HTTPONLY`, sessão 8h
- django-axes: bloqueio de 1h após 5 tentativas erradas (por IP; User é e-mail, sem username)
- django-allauth (Google OAuth) com `SOCIALACCOUNT_LOGIN_ON_GET`
- Suite de testes: 13 smoke tests (`python manage.py test core.tests_smoke`)

## Testes

```bash
python manage.py test core.tests_smoke
```

## Docker

```bash
docker compose up --build
```

## Documentação

```bash
mkdocs serve
```
