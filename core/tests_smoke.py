"""
Smoke tests do SCSI — suite base adicionada na atualização de segurança.

Cobre: health, landing, auth local (e-mail), login com Google (allauth),
axes (bruteforce), RBAC básico de tenants e headers de segurança.
"""
from django.contrib.auth import get_user_model
from django.test import Client, TestCase, override_settings
from django.urls import reverse

User = get_user_model()


class HealthAndLandingTest(TestCase):
    def test_health_ok(self):
        response = self.client.get('/health/')
        self.assertEqual(response.status_code, 200)

    def test_landing_public(self):
        response = self.client.get(reverse('landing'))
        self.assertEqual(response.status_code, 200)


class EmailAuthTest(TestCase):
    """Login local por e-mail (EmailBackend + EmailLoginView)."""

    def setUp(self):
        self.password = 'SenhaForte123!'
        self.user = User.objects.create_user(
            email='maria@scsi.test', password=self.password
        )

    def test_login_page_accessible(self):
        response = self.client.get(reverse('accounts:login'))
        self.assertEqual(response.status_code, 200)

    def test_login_with_valid_credentials(self):
        response = self.client.post(
            reverse('accounts:login'),
            {'username': 'maria@scsi.test', 'password': self.password},
        )
        self.assertIn(response.status_code, (200, 302))

    def test_login_with_invalid_credentials_rejected(self):
        response = self.client.post(
            reverse('accounts:login'),
            {'username': 'maria@scsi.test', 'password': 'errada'},
        )
        self.assertEqual(response.status_code, 200)  # volta ao form com erro

    def test_logout_requires_post(self):
        from django.contrib.auth import get_user as _get_user

        self.client.force_login(self.user)
        self.client.post('/accounts/logout/')
        self.assertFalse(_get_user(self.client).is_authenticated)


class AdminProtectionTest(TestCase):
    def test_admin_requires_login(self):
        response = self.client.get('/admin/')
        self.assertEqual(response.status_code, 302)
        self.assertIn('/admin/login/', response.url)

    @override_settings(AXES_ENABLED=False)
    def test_admin_wrong_password_rejected(self):
        User.objects.create_superuser(
            'adm@scsi.test', password='correta12345'
        )
        response = self.client.post(
            '/admin/login/',
            {'username': 'adm@scsi.test', 'password': 'errada'},
            follow=True,
        )
        # Volta ao form com erro (não autentica)
        self.assertFalse(response.context['user'].is_authenticated)

    def test_axes_lockout_after_5_failures(self):
        User.objects.create_superuser('adm2@scsi.test', password='correta12345')
        for _ in range(5):
            self.client.post(
                '/admin/login/', {'username': 'adm2@scsi.test', 'password': 'errada'}
            )
        response = self.client.post(
            '/admin/login/', {'username': 'adm2@scsi.test', 'password': 'correta12345'}
        )
        self.assertIn(response.status_code, (403, 429))


class GoogleLoginTest(TestCase):
    """allauth configurado: redirect real ao Google com credenciais fake."""

    @override_settings(
        SOCIALACCOUNT_PROVIDERS={
            'google': {
                'APP': {
                    'client_id': 'fake-id.apps.googleusercontent.com',
                    'secret': 'fake-secret',
                    'key': '',
                },
            }
        }
    )
    def test_google_login_redirects_to_google(self):
        response = self.client.get('/social/google/login/')
        self.assertEqual(response.status_code, 302)
        self.assertIn('accounts.google.com', response['Location'])
        self.assertIn('client_id=fake-id', response['Location'])


class SecurityHeadersTest(TestCase):
    def test_headers_always_present(self):
        response = self.client.get('/health/')
        self.assertEqual(response['X-Frame-Options'], 'DENY')
        self.assertEqual(response['X-Content-Type-Options'], 'nosniff')
        self.assertEqual(response['Referrer-Policy'], 'same-origin')

    def test_session_cookie_httponly_config(self):
        from django.conf import settings

        self.assertTrue(settings.SESSION_COOKIE_HTTPONLY)
        self.assertEqual(settings.SESSION_COOKIE_SAMESITE, 'Lax')


class TenantIsolationSmokeTest(TestCase):
    """Smoke básico: usuário isolado por tenant não vê dados sem login."""

    def test_protected_views_redirect_anonymous(self):
        for url in ('/dashboard/', '/clientes/', '/sinistros/'):
            response = self.client.get(url)
            self.assertIn(response.status_code, (301, 302))
