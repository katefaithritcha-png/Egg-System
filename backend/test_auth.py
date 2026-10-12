import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

os.environ['AUTH_PBKDF2_ITERATIONS'] = '12000'
os.environ['AUTH_TESTING'] = '1'
os.environ['AUTH_ADMIN_PASSWORD'] = 'AdminPass1'
os.environ['AUTH_WORKER_PASSWORD'] = 'WorkerPass1'
os.environ['AUTH_SESSION_TTL_SECONDS'] = '3600'
os.environ['AUTH_SESSION_IDLE_SECONDS'] = '1800'
os.environ['AUTH_VERIFY_TTL_SECONDS'] = '3600'
os.environ['AUTH_RESET_TTL_SECONDS'] = '3600'
os.environ.pop('SMTP_HOST', None)

_TEMP_DIR = tempfile.TemporaryDirectory()
os.environ['AUTH_DATA_DIR'] = _TEMP_DIR.name
os.environ['AUTH_DB_PATH'] = str(Path(_TEMP_DIR.name) / 'auth.sqlite')
os.environ['AUTH_OUTBOX_DIR'] = str(Path(_TEMP_DIR.name) / 'outbox')

from flask import Flask  # noqa: E402
from flask.testing import FlaskClient  # noqa: E402

import auth  # noqa: E402


def _outbox_token() -> str:
    files = sorted((auth._OUTBOX_DIR).glob('*.txt'))
    assert files, 'expected an outbox email'
    text = files[-1].read_text(encoding='utf-8')
    match = re.search(r'token=([A-Za-z0-9_\-]+)', text)
    if match is None:
        match = re.search(r'\b(\d{6})\b', text)
    assert match, text
    return match.group(1)


class AuthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        app = Flask(__name__)
        app.config['TESTING'] = True
        auth.init_auth(app)
        cls.app = app

    def setUp(self) -> None:
        auth.reset_rate_limits_for_tests()
        self.client: FlaskClient = self.app.test_client()

    def _signup(self, email: str, password: str = 'NewUser12') -> dict:
        response = self.client.post(
            '/auth/signup',
            json={'name': 'Test User', 'email': email, 'password': password},
        )
        self.assertIn(response.status_code, (200, 201), response.get_data(as_text=True))
        payload = response.get_json() or {}
        self._last_code = payload.get('verificationCode')
        return payload

    def _verify_latest(self) -> None:
        token = getattr(self, '_last_code', None) or _outbox_token()
        response = self.client.post('/auth/verify-email', json={'token': token})
        self.assertEqual(response.status_code, 200, response.get_data(as_text=True))

    def test_passwords_are_hashed_and_not_returned(self) -> None:
        login = self.client.post(
            '/auth/login',
            json={'email': 'admin@eggsystem.local', 'password': 'AdminPass1'},
        )
        self.assertEqual(login.status_code, 200)
        payload = login.get_json()
        dumped = json.dumps(payload)
        self.assertNotIn('AdminPass1', dumped)
        self.assertNotIn('password_hash', dumped)
        self.assertNotIn('pbkdf2_sha256', dumped)
        self.assertIn('token', payload['session'])
        conn = auth._connect()
        try:
            row = conn.execute(
                "SELECT password_hash FROM users WHERE email = ?",
                ('admin@eggsystem.local',),
            ).fetchone()
            self.assertTrue(row['password_hash'].startswith('pbkdf2_sha256$'))
            self.assertNotEqual(row['password_hash'], 'AdminPass1')
        finally:
            conn.close()

    def test_login_rejects_wrong_password(self) -> None:
        response = self.client.post(
            '/auth/login',
            json={'email': 'admin@eggsystem.local', 'password': 'WrongPass1'},
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(response.get_json()['code'], 'invalid_credentials')

    def test_signup_requires_email_verification(self) -> None:
        email = 'verify-me@eggsystem.local'
        self._signup(email)
        blocked = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'NewUser12'},
        )
        self.assertEqual(blocked.status_code, 403)
        self.assertEqual(blocked.get_json()['code'], 'unverified_email')
        self.assertNotIn('token', json.dumps(blocked.get_json()))
        self._verify_latest()
        allowed = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'NewUser12'},
        )
        self.assertEqual(allowed.status_code, 200)
        self.assertTrue(allowed.get_json()['user']['emailVerified'])

    def test_signup_returns_verification_code_for_the_app(self) -> None:
        response = self.client.post(
            '/auth/signup',
            json={
                'name': 'Shown Code',
                'email': 'show-code@eggsystem.local',
                'password': 'NewUser12',
            },
        )
        self.assertEqual(response.status_code, 201)
        payload = response.get_json()
        code = payload['verificationCode']
        self.assertRegex(code, r'^\d{6}$')
        matching = list(auth._OUTBOX_DIR.glob('*show-code*'))
        self.assertTrue(matching)
        self.assertIn(code, matching[-1].read_text(encoding='utf-8'))

    def test_signup_reissues_code_for_unverified_email(self) -> None:
        email = 'retry-signup@eggsystem.local'
        first = self.client.post(
            '/auth/signup',
            json={'name': 'First Try', 'email': email, 'password': 'NewUser12'},
        )
        self.assertEqual(first.status_code, 201)
        second = self.client.post(
            '/auth/signup',
            json={'name': 'Second Try', 'email': email, 'password': 'NewUser99'},
        )
        self.assertEqual(second.status_code, 200)
        self.assertRegex(second.get_json()['verificationCode'], r'^\d{6}$')
        blocked = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'NewUser99'},
        )
        self.assertEqual(blocked.status_code, 403)
        self.assertEqual(blocked.get_json()['code'], 'unverified_email')
        self.assertRegex(blocked.get_json()['verificationCode'], r'^\d{6}$')

    def test_signup_creates_one_time_worker_and_cannot_replace_admin(self) -> None:
        blocked = self.client.post(
            '/auth/signup',
            json={
                'name': 'Farm Admin',
                'email': auth.FIXED_ADMIN_EMAIL,
                'password': 'NewUser12',
                'role': 'admin',
            },
        )
        self.assertEqual(blocked.status_code, 403)
        self.assertEqual(blocked.get_json()['code'], 'admin_fixed')
        worker = self.client.post(
            '/auth/signup',
            json={
                'name': 'Farm Worker',
                'email': 'not-admin@eggsystem.local',
                'password': 'NewUser12',
                'role': 'admin',
            },
        )
        self.assertEqual(worker.status_code, 201)
        conn = auth._connect()
        try:
            fixed = conn.execute(
                "SELECT role, one_time, password_hash FROM users WHERE email = ?",
                (auth.FIXED_ADMIN_EMAIL,),
            ).fetchone()
            worker_row = conn.execute(
                "SELECT role, email_verified, one_time FROM users WHERE email = ?",
                ('not-admin@eggsystem.local',),
            ).fetchone()
            self.assertEqual(fixed['role'], 'admin')
            self.assertEqual(fixed['one_time'], 0)
            self.assertTrue(fixed['password_hash'].startswith('pbkdf2_sha256$'))
            self.assertNotIn(auth.FIXED_ADMIN_PASSWORD, fixed['password_hash'])
            self.assertEqual(worker_row['role'], 'worker')
            self.assertEqual(worker_row['email_verified'], 0)
            self.assertEqual(worker_row['one_time'], 1)
        finally:
            conn.close()

    def test_worker_account_can_sign_in_only_once(self) -> None:
        email = 'once@eggsystem.local'
        self._signup(email, 'NewUser12')
        self._verify_latest()
        first = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'NewUser12'},
        )
        self.assertEqual(first.status_code, 200)
        auth.reset_rate_limits_for_tests()
        second = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'NewUser12'},
        )
        self.assertEqual(second.status_code, 403)
        self.assertEqual(second.get_json()['code'], 'account_used')

    def test_fixed_admin_can_sign_in_again(self) -> None:
        for _ in range(2):
            login = self.client.post(
                '/auth/login',
                json={
                    'email': auth.FIXED_ADMIN_EMAIL,
                    'password': auth.FIXED_ADMIN_PASSWORD,
                },
            )
            self.assertEqual(login.status_code, 200, login.get_data(as_text=True))
            self.assertEqual(login.get_json()['user']['role'], 'admin')
            self.assertNotIn(auth.FIXED_ADMIN_PASSWORD, json.dumps(login.get_json()))

    def test_verified_signup_with_same_password_signs_in(self) -> None:
        email = 'again@eggsystem.local'
        self._signup(email)
        self._verify_latest()
        again = self.client.post(
            '/auth/signup',
            json={
                'name': 'Again User',
                'email': email,
                'password': 'NewUser12',
                'role': 'worker',
            },
        )
        self.assertEqual(again.status_code, 200)
        payload = again.get_json()
        self.assertIn('token', payload['session'])
        self.assertTrue(payload['user']['emailVerified'])

    def test_verified_signup_with_new_password_keeps_old_login_until_code(self) -> None:
        email = 'reclaim@eggsystem.local'
        self._signup(email, 'OldPass12')
        self._verify_latest()
        again = self.client.post(
            '/auth/signup',
            json={
                'name': 'Reclaim User',
                'email': email,
                'password': 'NewPass12',
                'role': 'admin',
            },
        )
        self.assertEqual(again.status_code, 200)
        code = again.get_json()['verificationCode']
        self.assertRegex(code, r'^\d{6}$')
        old_login = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'OldPass12'},
        )
        self.assertEqual(old_login.status_code, 200)
        verify = self.client.post('/auth/verify-email', json={'token': code})
        self.assertEqual(verify.status_code, 200)
        new_login = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'NewPass12'},
        )
        self.assertEqual(new_login.status_code, 403)
        self.assertEqual(new_login.get_json()['code'], 'account_used')

    def test_login_is_rate_limited(self) -> None:
        for _ in range(auth.LOGIN_EMAIL_LIMIT):
            response = self.client.post(
                '/auth/login',
                json={'email': 'admin@eggsystem.local', 'password': 'WrongPass1'},
            )
            self.assertEqual(response.status_code, 401)
        blocked = self.client.post(
            '/auth/login',
            json={'email': 'admin@eggsystem.local', 'password': 'AdminPass1'},
        )
        self.assertEqual(blocked.status_code, 429)
        self.assertEqual(blocked.get_json()['code'], 'rate_limited')

    def test_sessions_expire(self) -> None:
        login = self.client.post(
            '/auth/login',
            json={'email': 'worker@eggsystem.local', 'password': 'WorkerPass1'},
        )
        token = login.get_json()['session']['token']
        conn = auth._connect()
        try:
            conn.execute(
                "UPDATE sessions SET expires_at = '2000-01-01T00:00:00Z' WHERE token_hash = ?",
                (auth.hash_token(token),),
            )
            conn.commit()
        finally:
            conn.close()
        me = self.client.get('/auth/me', headers={'Authorization': f'Bearer {token}'})
        self.assertEqual(me.status_code, 401)

    def test_idle_sessions_expire(self) -> None:
        login = self.client.post(
            '/auth/login',
            json={'email': 'worker@eggsystem.local', 'password': 'WorkerPass1'},
        )
        token = login.get_json()['session']['token']
        conn = auth._connect()
        try:
            conn.execute(
                "UPDATE sessions SET last_seen_at = '2000-01-01T00:00:00Z' WHERE token_hash = ?",
                (auth.hash_token(token),),
            )
            conn.commit()
        finally:
            conn.close()
        me = self.client.get('/auth/me', headers={'Authorization': f'Bearer {token}'})
        self.assertEqual(me.status_code, 401)

    def test_password_reset_tokens_expire(self) -> None:
        forgot = self.client.post(
            '/auth/forgot-password',
            json={'email': 'admin@eggsystem.local'},
        )
        self.assertEqual(forgot.status_code, 200)
        self.assertNotIn('token', json.dumps(forgot.get_json()))
        token = _outbox_token()
        conn = auth._connect()
        try:
            conn.execute(
                "UPDATE email_tokens SET expires_at = '2000-01-01T00:00:00Z' WHERE token_hash = ?",
                (auth.hash_token(token),),
            )
            conn.commit()
        finally:
            conn.close()
        reset = self.client.post(
            '/auth/reset-password',
            json={'token': token, 'password': 'FreshPass9'},
        )
        self.assertEqual(reset.status_code, 400)
        self.assertEqual(reset.get_json()['code'], 'invalid_token')

    def test_password_reset_succeeds_and_revokes_sessions(self) -> None:
        email = 'reset-user@eggsystem.local'
        self._signup(email, 'OldPass12')
        self._verify_latest()
        login = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'OldPass12'},
        )
        self.assertEqual(login.status_code, 200)
        old_token = login.get_json()['session']['token']
        self.client.post('/auth/forgot-password', json={'email': email})
        token = _outbox_token()
        reset = self.client.post(
            '/auth/reset-password',
            json={'token': token, 'password': 'FreshPass9'},
        )
        self.assertEqual(reset.status_code, 200)
        stale = self.client.get('/auth/me', headers={'Authorization': f'Bearer {old_token}'})
        self.assertEqual(stale.status_code, 401)
        auth.reset_rate_limits_for_tests()
        new_login = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'FreshPass9'},
        )
        self.assertEqual(new_login.status_code, 403)
        self.assertEqual(new_login.get_json()['code'], 'account_used')

    def test_forgot_password_does_not_reveal_accounts(self) -> None:
        known = self.client.post(
            '/auth/forgot-password',
            json={'email': 'admin@eggsystem.local'},
        )
        unknown = self.client.post(
            '/auth/forgot-password',
            json={'email': 'missing@eggsystem.local'},
        )
        self.assertEqual(known.status_code, 200)
        self.assertEqual(unknown.status_code, 200)
        self.assertEqual(known.get_json()['message'], unknown.get_json()['message'])

    def test_change_password_requires_current_password(self) -> None:
        email = 'change-user@eggsystem.local'
        self._signup(email, 'WorkerPass1')
        self._verify_latest()
        login = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'WorkerPass1'},
        )
        token = login.get_json()['session']['token']
        denied = self.client.post(
            '/auth/change-password',
            json={'currentPassword': 'NopePass1', 'newPassword': 'Changed99'},
            headers={'Authorization': f'Bearer {token}'},
        )
        self.assertEqual(denied.status_code, 401)
        ok = self.client.post(
            '/auth/change-password',
            json={'currentPassword': 'WorkerPass1', 'newPassword': 'Changed99'},
            headers={'Authorization': f'Bearer {token}'},
        )
        self.assertEqual(ok.status_code, 200)
        auth.reset_rate_limits_for_tests()
        old = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'WorkerPass1'},
        )
        self.assertEqual(old.status_code, 401)
        fresh = self.client.post(
            '/auth/login',
            json={'email': email, 'password': 'Changed99'},
        )
        self.assertEqual(fresh.status_code, 403)
        self.assertEqual(fresh.get_json()['code'], 'account_used')


if __name__ == '__main__':
    try:
        unittest.main()
    finally:
        _TEMP_DIR.cleanup()
