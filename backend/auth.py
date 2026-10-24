"""Farm-PC accounts, sessions, and email verification codes."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import smtplib
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from pathlib import Path

from flask import Flask, jsonify, request

from firebase_store import (
    ensure_firebase_email_user,
    firebase_password_ok,
    lookup_firebase_id_token,
    mark_email_verified,
    record_backend_email,
    sync_mail_config,
    upsert_user_profile,
    write_verification_record,
)

_ROOT = Path(__file__).resolve().parent


def _load_env_file() -> None:
    if os.environ.get('AUTH_TESTING') == '1':
        return
    path = _ROOT / '.env'
    if not path.is_file():
        return
    for raw in path.read_text(encoding='utf-8').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


_load_env_file()

LOGIN_EMAIL_LIMIT = int(os.environ.get('AUTH_LOGIN_EMAIL_LIMIT', '8'))
_LOGIN_WINDOW_SECONDS = int(os.environ.get('AUTH_LOGIN_WINDOW_SECONDS', '900'))
_PBKDF2_ITERATIONS = int(os.environ.get('AUTH_PBKDF2_ITERATIONS', '120000'))
_SESSION_TTL = int(os.environ.get('AUTH_SESSION_TTL_SECONDS', '43200'))
_SESSION_IDLE = int(os.environ.get('AUTH_SESSION_IDLE_SECONDS', '1800'))
_VERIFY_TTL = int(os.environ.get('AUTH_VERIFY_TTL_SECONDS', '3600'))
_RESET_TTL = int(os.environ.get('AUTH_RESET_TTL_SECONDS', '3600'))

_DATA_DIR = Path(os.environ.get('AUTH_DATA_DIR', str(_ROOT / 'data')))
_DB_PATH = Path(os.environ.get('AUTH_DB_PATH', str(_DATA_DIR / 'auth.sqlite')))
_OUTBOX_DIR = Path(os.environ.get('AUTH_OUTBOX_DIR', str(_DATA_DIR / 'outbox')))

_login_hits: dict[str, list[float]] = {}
_FORGOT_MESSAGE = 'If an account exists, a reset code was sent.'


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def _parse_iso(value: str) -> datetime:
    text = value.strip()
    if text.endswith('Z'):
        text = text[:-1] + '+00:00'
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _connect() -> sqlite3.Connection:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    _DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(_DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode('utf-8')).hexdigest()


def _hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        'sha256',
        password.encode('utf-8'),
        salt.encode('utf-8'),
        _PBKDF2_ITERATIONS,
    ).hex()
    return f'pbkdf2_sha256${_PBKDF2_ITERATIONS}${salt}${digest}'


def _password_ok(password: str, stored: str) -> bool:
    try:
        scheme, rounds, salt, digest = stored.split('$', 3)
    except ValueError:
        return False
    if scheme != 'pbkdf2_sha256':
        return False
    check = hashlib.pbkdf2_hmac(
        'sha256',
        password.encode('utf-8'),
        salt.encode('utf-8'),
        int(rounds),
    ).hex()
    return hmac.compare_digest(check, digest)


def reset_rate_limits_for_tests() -> None:
    _login_hits.clear()


def _rate_limited(email: str) -> bool:
    now = time.monotonic()
    bucket = [stamp for stamp in _login_hits.get(email, []) if now - stamp < _LOGIN_WINDOW_SECONDS]
    if len(bucket) >= LOGIN_EMAIL_LIMIT:
        _login_hits[email] = bucket
        return True
    bucket.append(now)
    _login_hits[email] = bucket
    return False


def _clear_rate(email: str) -> None:
    _login_hits.pop(email, None)


def _init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            role TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            pending_password_hash TEXT,
            email_verified INTEGER NOT NULL DEFAULT 0,
            assigned_zone TEXT NOT NULL DEFAULT 'Farm',
            created_at TEXT NOT NULL,
            password_changed_at TEXT
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            expires_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS email_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            purpose TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            expires_at TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        CREATE TABLE IF NOT EXISTS farm_snapshots (
            user_id INTEGER PRIMARY KEY,
            payload TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id)
        );
        """
    )
    conn.commit()


def _seed(conn: sqlite3.Connection) -> None:
    seeds = (
        (
            os.environ.get('AUTH_ADMIN_EMAIL', 'admin@eggsystem.local'),
            os.environ.get('AUTH_ADMIN_PASSWORD', ''),
            'Farm Admin',
            'admin',
        ),
        (
            os.environ.get('AUTH_WORKER_EMAIL', 'worker@eggsystem.local'),
            os.environ.get('AUTH_WORKER_PASSWORD', ''),
            'Farm Worker',
            'worker',
        ),
    )
    now = _iso(_utcnow())
    for email, password, name, role in seeds:
        normalized = (email or '').strip().lower()
        if not normalized or not password:
            continue
        row = conn.execute('SELECT id FROM users WHERE email = ?', (normalized,)).fetchone()
        if row is not None:
            continue
        conn.execute(
            """
            INSERT INTO users (
                email, name, role, password_hash, email_verified,
                assigned_zone, created_at, password_changed_at
            ) VALUES (?, ?, ?, ?, 1, 'Farm', ?, ?)
            """,
            (normalized, name, role, _hash_password(password), now, now),
        )
    conn.commit()


def _user_by_email(conn: sqlite3.Connection, email: str) -> sqlite3.Row | None:
    return conn.execute(
        'SELECT * FROM users WHERE email = ?',
        (email.strip().lower(),),
    ).fetchone()


def _public_user(row: sqlite3.Row) -> dict:
    return {
        'name': row['name'],
        'email': row['email'],
        'role': row['role'],
        'assignedZone': row['assigned_zone'],
        'emailVerified': bool(row['email_verified']),
        'passwordChangedAt': row['password_changed_at'],
    }


def _sync_profile(row: sqlite3.Row) -> None:
    upsert_user_profile(
        email=row['email'],
        name=row['name'],
        role=row['role'],
        assigned_zone=row['assigned_zone'],
        email_verified=bool(row['email_verified']),
        created_at=row['created_at'],
        password_hash=row['password_hash'],
    )


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in conn.execute(f'PRAGMA table_info({table})')}


def _issue_session(conn: sqlite3.Connection, user_id: int) -> dict:
    token = secrets.token_urlsafe(32)
    now = _utcnow()
    expires = _iso(now + timedelta(seconds=_SESSION_TTL))
    seen = _iso(now)
    if 'created_at' in _columns(conn, 'sessions'):
        conn.execute(
            """
            INSERT INTO sessions (user_id, token_hash, created_at, expires_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (user_id, hash_token(token), seen, expires, seen),
        )
    else:
        conn.execute(
            """
            INSERT INTO sessions (user_id, token_hash, expires_at, last_seen_at)
            VALUES (?, ?, ?, ?)
            """,
            (user_id, hash_token(token), expires, seen),
        )
    conn.commit()
    return {
        'token': token,
        'expiresAt': _iso(now + timedelta(seconds=_SESSION_TTL)),
        'idleTimeoutSeconds': _SESSION_IDLE,
    }


def _session_user(conn: sqlite3.Connection) -> sqlite3.Row | None:
    header = request.headers.get('Authorization', '')
    if not header.lower().startswith('bearer '):
        return None
    token = header.split(' ', 1)[1].strip()
    if not token:
        return None
    row = conn.execute(
        """
        SELECT users.*, sessions.expires_at AS session_expires,
               sessions.last_seen_at AS session_seen, sessions.id AS session_id
        FROM sessions JOIN users ON users.id = sessions.user_id
        WHERE sessions.token_hash = ?
        """,
        (hash_token(token),),
    ).fetchone()
    if row is None:
        return None
    now = _utcnow()
    if _parse_iso(row['session_expires']) <= now:
        return None
    if _parse_iso(row['session_seen']) + timedelta(seconds=_SESSION_IDLE) <= now:
        return None
    conn.execute(
        'UPDATE sessions SET last_seen_at = ? WHERE id = ?',
        (_iso(now), row['session_id']),
    )
    conn.commit()
    return row


def get_request_user():
    conn = _connect()
    try:
        row = _session_user(conn)
        if row is None:
            return None
        return _public_user(row)
    finally:
        conn.close()


def get_user_from_authorization(authorization: str | None):
    """Session lookup for FastAPI (no Flask request context)."""
    header = (authorization or '').strip()
    if not header.lower().startswith('bearer '):
        return None
    token = header.split(' ', 1)[1].strip()
    if not token:
        return None
    conn = _connect()
    try:
        row = conn.execute(
            """
            SELECT users.*, sessions.expires_at AS session_expires,
                   sessions.last_seen_at AS session_seen, sessions.id AS session_id
            FROM sessions JOIN users ON users.id = sessions.user_id
            WHERE sessions.token_hash = ?
            """,
            (hash_token(token),),
        ).fetchone()
        if row is None:
            return None
        now = _utcnow()
        if _parse_iso(row['session_expires']) <= now:
            return None
        if _parse_iso(row['session_seen']) + timedelta(seconds=_SESSION_IDLE) <= now:
            return None
        conn.execute(
            'UPDATE sessions SET last_seen_at = ? WHERE id = ?',
            (_iso(now), row['session_id']),
        )
        conn.commit()
        return _public_user(row)
    finally:
        conn.close()


def _revoke_sessions(conn: sqlite3.Connection, user_id: int) -> None:
    conn.execute('DELETE FROM sessions WHERE user_id = ?', (user_id,))


def _smtp_send(host: str, user: str, password: str, message: EmailMessage) -> None:
    """Gmail accepts either STARTTLS on 587 or SSL on 465. Try the configured port, then the other."""
    configured = int(os.environ.get('SMTP_PORT', '587') or '587')
    ports = [configured] + [port for port in (587, 465) if port != configured]
    last_error: Exception | None = None
    for port in ports:
        try:
            if port == 465:
                with smtplib.SMTP_SSL(host, port, timeout=20) as smtp:
                    smtp.login(user, password)
                    smtp.send_message(message)
                return
            with smtplib.SMTP(host, port, timeout=20) as smtp:
                smtp.ehlo()
                smtp.starttls()
                smtp.ehlo()
                smtp.login(user, password)
                smtp.send_message(message)
            return
        except Exception as exc:  # noqa: BLE001
            last_error = exc
    if last_error is not None:
        raise last_error


def _deliver_code(email: str, purpose: str, code: str) -> None:
    _OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
    safe = email.replace('@', '_at_').replace('.', '_')
    stamp = _utcnow().strftime('%Y%m%d%H%M%S%f')
    path = _OUTBOX_DIR / f'{stamp}-{safe}-{purpose}.txt'
    subject = 'Egg System verification code' if purpose != 'reset' else 'Egg System password reset'
    body = (
        f'To: {email}\n'
        f'Subject: {subject}\n\n'
        f'Your code is {code}\n'
        f'token={code}\n'
    )
    path.write_text(body, encoding='utf-8')
    host = os.environ.get('SMTP_HOST', '').strip()
    user = os.environ.get('SMTP_USER', '').strip()
    password = os.environ.get('SMTP_PASSWORD', '').replace(' ', '')
    sender = (os.environ.get('SMTP_FROM') or user).strip()
    if os.environ.get('AUTH_TESTING') == '1' or not (host and user and password and sender):
        print(f'[auth] verification code stored in outbox for {email}')
        return
    message = EmailMessage()
    message['Subject'] = subject
    message['From'] = sender
    message['To'] = email
    message.set_content(
        f'Your Egg System code is {code}. It expires in one hour.\n'
    )
    try:
        _smtp_send(host, user, password, message)
        print(f'[auth] verification email sent to {email}')
        record_backend_email(
            email,
            event=purpose,
            first_seen_at=_iso(_utcnow()),
            last_seen_at=_iso(_utcnow()),
            attempt_count=1,
        )
    except Exception as exc:  # noqa: BLE001
        print(f'[auth] SMTP send failed for {email}: {exc}')


def _issue_code(
    conn: sqlite3.Connection,
    user_id: int,
    email: str,
    purpose: str,
    *,
    replace: bool = True,
) -> str:
    code = f'{secrets.randbelow(1_000_000):06d}'
    ttl = _RESET_TTL if purpose == 'reset' else _VERIFY_TTL
    expires = _iso(_utcnow() + timedelta(seconds=ttl))
    if replace:
        conn.execute(
            'DELETE FROM email_tokens WHERE user_id = ? AND purpose = ?',
            (user_id, purpose),
        )
    if 'created_at' in _columns(conn, 'email_tokens'):
        conn.execute(
            """
            INSERT INTO email_tokens (user_id, purpose, token_hash, expires_at, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (user_id, purpose, hash_token(code), expires, _iso(_utcnow())),
        )
    else:
        conn.execute(
            """
            INSERT INTO email_tokens (user_id, purpose, token_hash, expires_at)
            VALUES (?, ?, ?, ?)
            """,
            (user_id, purpose, hash_token(code), expires),
        )
    conn.commit()
    write_verification_record(email, code_hash=hash_token(code), expires_at=expires, purpose=purpose)
    _deliver_code(email, purpose, code)
    return code


def _json_error(message: str, status: int, code: str, **extra):
    payload = {'error': message, 'code': code}
    payload.update(extra)
    return jsonify(payload), status


def _password_policy(password: str) -> str | None:
    if len(password) < 8 or not any(ch.isalpha() for ch in password) or not any(ch.isdigit() for ch in password):
        return 'Password must be at least 8 characters and include a letter and a number.'
    return None


def init_auth(app: Flask) -> None:
    conn = _connect()
    try:
        _init_db(conn)
        _seed(conn)
    finally:
        conn.close()
    if os.environ.get('AUTH_TESTING') != '1':
        sync_mail_config()

    @app.get('/auth/health')
    def auth_health():
        return jsonify({'ok': True, 'service': 'egg-system-auth'})

    @app.post('/auth/signup')
    def signup():
        body = request.get_json(silent=True) or {}
        name = str(body.get('name') or '').strip()
        email = str(body.get('email') or '').strip().lower()
        password = str(body.get('password') or '')
        if not name or '@' not in email:
            return _json_error('Enter a name and email.', 400, 'invalid_request')
        policy = _password_policy(password)
        if policy:
            return _json_error(policy, 400, 'weak_password')
        conn = _connect()
        try:
            existing = _user_by_email(conn, email)
            now = _iso(_utcnow())
            if existing is None:
                conn.execute(
                    """
                    INSERT INTO users (
                        email, name, role, password_hash, email_verified,
                        assigned_zone, created_at
                    ) VALUES (?, ?, 'worker', ?, 0, 'Farm', ?)
                    """,
                    (email, name, _hash_password(password), now),
                )
                conn.commit()
                row = _user_by_email(conn, email)
                assert row is not None
                code = _issue_code(conn, row['id'], email, 'verify')
                ensure_firebase_email_user(email, password)
                _sync_profile(row)
                return jsonify({
                    'message': 'Account created. Enter the verification code sent to your email.',
                    'verificationCode': code,
                }), 201
            if not existing['email_verified']:
                conn.execute(
                    'UPDATE users SET name = ?, password_hash = ? WHERE id = ?',
                    (name, _hash_password(password), existing['id']),
                )
                conn.commit()
                code = _issue_code(conn, existing['id'], email, 'verify')
                return jsonify({
                    'message': 'A new verification code was sent.',
                    'verificationCode': code,
                }), 200
            if _password_ok(password, existing['password_hash']):
                session = _issue_session(conn, existing['id'])
                return jsonify({
                    'message': 'Signed in.',
                    'user': _public_user(existing),
                    'session': session,
                }), 200
            conn.execute(
                'UPDATE users SET pending_password_hash = ? WHERE id = ?',
                (_hash_password(password), existing['id']),
            )
            conn.commit()
            code = _issue_code(conn, existing['id'], email, 'verify')
            return jsonify({
                'message': 'Confirm the code to update this account.',
                'verificationCode': code,
            }), 200
        finally:
            conn.close()

    @app.post('/auth/login')
    def login():
        body = request.get_json(silent=True) or {}
        email = str(body.get('email') or '').strip().lower()
        password = str(body.get('password') or '')
        if _rate_limited(email):
            return _json_error('Too many sign-in attempts. Try again later.', 429, 'rate_limited')
        conn = _connect()
        try:
            row = _user_by_email(conn, email)
            if row is None and firebase_password_ok(email, password):
                now = _iso(_utcnow())
                conn.execute(
                    """
                    INSERT INTO users (
                        email, name, role, password_hash, email_verified,
                        assigned_zone, created_at, password_changed_at
                    ) VALUES (?, ?, 'worker', ?, 1, 'Farm', ?, ?)
                    """,
                    (email, email.split('@')[0], _hash_password(password), now, now),
                )
                conn.commit()
                row = _user_by_email(conn, email)
            if row is None or not _password_ok(password, row['password_hash']):
                return _json_error('Wrong email or password.', 401, 'invalid_credentials')
            if not row['email_verified']:
                code = _issue_code(conn, row['id'], email, 'verify', replace=False)
                return _json_error(
                    'Verify your email before signing in.',
                    403,
                    'unverified_email',
                    verificationCode=code,
                )
            _clear_rate(email)
            session = _issue_session(conn, row['id'])
            return jsonify({'user': _public_user(row), 'session': session})
        finally:
            conn.close()

    @app.post('/auth/verify-email')
    def verify_email():
        body = request.get_json(silent=True) or {}
        token = str(body.get('token') or body.get('code') or '').strip()
        return _consume_code(token, apply_pending=True)

    @app.post('/auth/verify-login')
    def verify_login():
        body = request.get_json(silent=True) or {}
        token = str(body.get('token') or body.get('code') or '').strip()
        return _consume_code(token, apply_pending=True, sign_in=True)

    @app.post('/auth/resend-verification')
    def resend_verification():
        body = request.get_json(silent=True) or {}
        email = str(body.get('email') or '').strip().lower()
        conn = _connect()
        try:
            row = _user_by_email(conn, email)
            if row is not None and not row['email_verified']:
                code = _issue_code(conn, row['id'], email, 'verify')
                return jsonify({
                    'message': 'A new verification code was sent.',
                    'verificationCode': code,
                })
            return jsonify({'message': 'If the account is unverified, a new code was sent.'})
        finally:
            conn.close()

    @app.post('/auth/forgot-password')
    def forgot_password():
        body = request.get_json(silent=True) or {}
        email = str(body.get('email') or '').strip().lower()
        conn = _connect()
        try:
            row = _user_by_email(conn, email)
            if row is not None:
                _issue_code(conn, row['id'], email, 'reset')
            return jsonify({'message': _FORGOT_MESSAGE})
        finally:
            conn.close()

    @app.post('/auth/reset-password')
    def reset_password():
        body = request.get_json(silent=True) or {}
        token = str(body.get('token') or '').strip()
        password = str(body.get('password') or '')
        policy = _password_policy(password)
        if policy:
            return _json_error(policy, 400, 'weak_password')
        conn = _connect()
        try:
            found = _find_token(conn, token, 'reset')
            if found is None:
                return _json_error('That code is invalid or expired.', 400, 'invalid_token')
            token_row, user = found
            now = _iso(_utcnow())
            conn.execute(
                """
                UPDATE users
                SET password_hash = ?, pending_password_hash = NULL, password_changed_at = ?
                WHERE id = ?
                """,
                (_hash_password(password), now, user['id']),
            )
            conn.execute('DELETE FROM email_tokens WHERE id = ?', (token_row['id'],))
            _revoke_sessions(conn, user['id'])
            conn.commit()
            return jsonify({'message': 'Password updated.'})
        finally:
            conn.close()

    @app.post('/auth/change-password')
    def change_password():
        body = request.get_json(silent=True) or {}
        current = str(body.get('currentPassword') or '')
        new_password = str(body.get('newPassword') or '')
        policy = _password_policy(new_password)
        if policy:
            return _json_error(policy, 400, 'weak_password')
        conn = _connect()
        try:
            row = _session_user(conn)
            if row is None:
                return _json_error('Sign in again.', 401, 'unauthorized')
            if not _password_ok(current, row['password_hash']):
                return _json_error('Current password is wrong.', 401, 'invalid_credentials')
            now = _iso(_utcnow())
            conn.execute(
                'UPDATE users SET password_hash = ?, password_changed_at = ? WHERE id = ?',
                (_hash_password(new_password), now, row['id']),
            )
            conn.commit()
            fresh = _user_by_email(conn, row['email'])
            assert fresh is not None
            return jsonify({'message': 'Password updated.', 'user': _public_user(fresh)})
        finally:
            conn.close()

    @app.get('/auth/me')
    def me():
        conn = _connect()
        try:
            row = _session_user(conn)
            if row is None:
                return _json_error('Sign in again.', 401, 'unauthorized')
            header = request.headers.get('Authorization', '')
            token = header.split(' ', 1)[1].strip() if ' ' in header else ''
            return jsonify({
                'user': _public_user(row),
                'session': {
                    'token': token,
                    'expiresAt': row['session_expires'],
                    'idleTimeoutSeconds': _SESSION_IDLE,
                },
            })
        finally:
            conn.close()

    @app.post('/auth/logout')
    def logout():
        header = request.headers.get('Authorization', '')
        token = header.split(' ', 1)[1].strip() if header.lower().startswith('bearer ') else ''
        if token:
            conn = _connect()
            try:
                conn.execute('DELETE FROM sessions WHERE token_hash = ?', (hash_token(token),))
                conn.commit()
            finally:
                conn.close()
        return jsonify({'ok': True})

    @app.post('/auth/firebase-login')
    def firebase_login():
        body = request.get_json(silent=True) or {}
        record = lookup_firebase_id_token(str(body.get('idToken') or ''))
        if not record:
            return _json_error('Google sign-in was not accepted.', 401, 'invalid_credentials')
        email = str(record.get('email') or '').strip().lower()
        if not email:
            return _json_error('Google did not return an email.', 400, 'invalid_request')
        requested = str(body.get('role') or 'worker').strip().lower()
        role = requested if body.get('setRole') and requested in ('worker', 'sales') else 'worker'
        name = str(record.get('displayName') or email.split('@')[0])
        conn = _connect()
        try:
            row = _user_by_email(conn, email)
            now = _iso(_utcnow())
            if row is None:
                conn.execute(
                    """
                    INSERT INTO users (
                        email, name, role, password_hash, email_verified,
                        assigned_zone, created_at
                    ) VALUES (?, ?, ?, ?, 1, 'Farm', ?)
                    """,
                    (email, name, role, _hash_password(secrets.token_urlsafe(24)), now),
                )
                conn.commit()
                row = _user_by_email(conn, email)
            assert row is not None
            session = _issue_session(conn, row['id'])
            return jsonify({'user': _public_user(row), 'session': session})
        finally:
            conn.close()

    @app.put('/farm/snapshot')
    def save_farm_snapshot():
        conn = _connect()
        try:
            row = _session_user(conn)
            if row is None:
                return _json_error('Sign in again.', 401, 'unauthorized')
            payload = request.get_json(silent=True) or {}
            conn.execute(
                """
                INSERT INTO farm_snapshots (user_id, payload) VALUES (?, ?)
                ON CONFLICT(user_id) DO UPDATE SET payload = excluded.payload
                """,
                (row['id'], json.dumps(payload)),
            )
            conn.commit()
            return jsonify({'ok': True})
        finally:
            conn.close()

    @app.get('/farm/snapshot')
    def load_farm_snapshot():
        conn = _connect()
        try:
            row = _session_user(conn)
            if row is None:
                return _json_error('Sign in again.', 401, 'unauthorized')
            saved = conn.execute(
                'SELECT payload FROM farm_snapshots WHERE user_id = ?',
                (row['id'],),
            ).fetchone()
            if saved is None:
                return jsonify({'snapshot': None}), 404
            return jsonify({'snapshot': json.loads(saved['payload'])})
        finally:
            conn.close()


def _find_token(conn: sqlite3.Connection, token: str, purpose: str | None):
    if not token:
        return None
    query = """
        SELECT email_tokens.*, users.email AS user_email
        FROM email_tokens JOIN users ON users.id = email_tokens.user_id
        WHERE email_tokens.token_hash = ?
    """
    params: tuple = (hash_token(token),)
    if purpose:
        query += ' AND email_tokens.purpose = ?'
        params = (hash_token(token), purpose)
    token_row = conn.execute(query, params).fetchone()
    if token_row is None:
        return None
    if _parse_iso(token_row['expires_at']) <= _utcnow():
        return None
    user = conn.execute('SELECT * FROM users WHERE id = ?', (token_row['user_id'],)).fetchone()
    if user is None:
        return None
    return token_row, user


def _consume_code(token: str, *, apply_pending: bool, sign_in: bool = False):
    conn = _connect()
    try:
        found = _find_token(conn, token, None if sign_in else 'verify')
        if found is None and not sign_in:
            found = _find_token(conn, token, 'verify')
        if found is None:
            return _json_error('That code is invalid or expired.', 400, 'invalid_token')
        token_row, user = found
        if token_row['purpose'] == 'reset' and not sign_in:
            return _json_error('That code is invalid or expired.', 400, 'invalid_token')
        now = _iso(_utcnow())
        pending = user['pending_password_hash'] if apply_pending else None
        if pending:
            conn.execute(
                """
                UPDATE users
                SET email_verified = 1, password_hash = ?, pending_password_hash = NULL,
                    password_changed_at = ?
                WHERE id = ?
                """,
                (pending, now, user['id']),
            )
        else:
            conn.execute(
                'UPDATE users SET email_verified = 1 WHERE id = ?',
                (user['id'],),
            )
        conn.execute('DELETE FROM email_tokens WHERE id = ?', (token_row['id'],))
        conn.commit()
        fresh = _user_by_email(conn, user['email'])
        assert fresh is not None
        mark_email_verified(fresh['email'])
        _sync_profile(fresh)
        if sign_in:
            session = _issue_session(conn, fresh['id'])
            return jsonify({
                'message': 'Email verified.',
                'user': _public_user(fresh),
                'session': session,
            })
        return jsonify({'message': 'Email verified.'})
    finally:
        conn.close()
