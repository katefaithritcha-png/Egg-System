"""Server-side authentication for the Egg System.

Passwords are stored as PBKDF2-HMAC-SHA256 hashes. Session, email-verification,
and password-reset tokens are stored only as SHA-256 hashes. Password hashes and SMTP secrets are never included in API responses.
Six-digit codes are shown in the app so signup can finish if Gmail is delayed.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import smtplib
import sqlite3
import sys
import threading
import time
from collections import defaultdict, deque
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formataddr, make_msgid
from html import escape
from pathlib import Path
from typing import Any

from flask import Blueprint, Flask, g, jsonify, request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from firebase_store import (
    mark_email_verified,
    record_backend_email,
    sync_mail_config,
    upsert_user_profile,
    write_verification_record,
)

ISO = '%Y-%m-%dT%H:%M:%SZ'
EMAIL_RE = re.compile(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
MIN_PASSWORD_LENGTH = 8
PBKDF2_ITERATIONS = int(os.environ.get('AUTH_PBKDF2_ITERATIONS', '310000'))
SESSION_TTL_SECONDS = int(os.environ.get('AUTH_SESSION_TTL_SECONDS', str(8 * 3600)))
SESSION_IDLE_SECONDS = int(os.environ.get('AUTH_SESSION_IDLE_SECONDS', str(30 * 60)))
VERIFY_TTL_SECONDS = int(os.environ.get('AUTH_VERIFY_TTL_SECONDS', str(15 * 60)))
RESET_TTL_SECONDS = int(os.environ.get('AUTH_RESET_TTL_SECONDS', str(60 * 60)))
FIXED_ADMIN_EMAIL = 'katefaithr@gmail.com'
FIXED_ADMIN_PASSWORD = 'Admin123@'
FIXED_ADMIN_NAME = 'Kate Faith'

LOGIN_EMAIL_LIMIT = 12
LOGIN_EMAIL_WINDOW = 15 * 60
LOGIN_IP_LIMIT = 40
LOGIN_IP_WINDOW = 15 * 60
FORGOT_EMAIL_LIMIT = 3
FORGOT_EMAIL_WINDOW = 60 * 60
FORGOT_IP_LIMIT = 10
FORGOT_IP_WINDOW = 60 * 60
SIGNUP_IP_LIMIT = 40
SIGNUP_IP_WINDOW = 60 * 60
RESEND_EMAIL_LIMIT = 20
RESEND_EMAIL_WINDOW = 60 * 60

_DATA_DIR = Path(os.environ.get('AUTH_DATA_DIR', str(Path(__file__).resolve().parent / 'data')))
_DB_PATH = Path(os.environ.get('AUTH_DB_PATH', str(_DATA_DIR / 'auth.sqlite')))
_OUTBOX_DIR = Path(os.environ.get('AUTH_OUTBOX_DIR', str(_DATA_DIR / 'outbox')))
_BOOTSTRAP_FILE = _DATA_DIR / 'bootstrap_credentials.txt'

auth_bp = Blueprint('auth', __name__)
_db_lock = threading.Lock()
_limiter_lock = threading.Lock()
_hits: dict[str, deque[float]] = defaultdict(deque)
_dummy_password_hash = ''


def reset_rate_limits_for_tests() -> None:
    with _limiter_lock:
        _hits.clear()


def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime(ISO)


def _parse_iso(value: str) -> datetime:
    return datetime.strptime(value, ISO).replace(tzinfo=timezone.utc)


def _load_dotenv() -> None:
    for candidate in (
        Path(__file__).resolve().parent / '.env',
        Path(__file__).resolve().parent.parent / '.env',
    ):
        if not candidate.is_file():
            continue
        for raw_line in candidate.read_text(encoding='utf-8').splitlines():
            line = raw_line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, value = line.split('=', 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key.startswith('SMTP_') or key.startswith('FIREBASE_'):
                os.environ[key] = value
            elif key == 'AUTH_VERIFY_TTL_SECONDS' and os.environ.get('AUTH_TESTING') != '1':
                os.environ[key] = value
            else:
                os.environ.setdefault(key, value)
        break


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac(
        'sha256',
        password.encode('utf-8'),
        salt,
        PBKDF2_ITERATIONS,
    )
    return f'pbkdf2_sha256${PBKDF2_ITERATIONS}${salt.hex()}${digest.hex()}'


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, iter_s, salt_hex, digest_hex = stored.split('$', 3)
        if scheme != 'pbkdf2_sha256':
            return False
        iterations = int(iter_s)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(digest_hex)
    except (ValueError, TypeError):
        return False
    actual = hashlib.pbkdf2_hmac(
        'sha256',
        password.encode('utf-8'),
        salt,
        iterations,
    )
    return hmac.compare_digest(actual, expected)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode('utf-8')).hexdigest()


def new_token() -> str:
    return secrets.token_urlsafe(32)


def new_otp_code() -> str:
    return f'{secrets.randbelow(900000) + 100000:06d}'


def validate_password(password: str) -> str | None:
    if len(password) < MIN_PASSWORD_LENGTH:
        return f'Password must be at least {MIN_PASSWORD_LENGTH} characters'
    if not re.search(r'[A-Za-z]', password):
        return 'Password must include a letter'
    if not re.search(r'\d', password):
        return 'Password must include a number'
    return None


def normalize_email(email: str) -> str:
    return email.strip().lower()


def _connect() -> sqlite3.Connection:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(_DB_PATH, timeout=30, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys = ON')
    return conn


def db() -> sqlite3.Connection:
    if 'auth_db' not in g:
        g.auth_db = _connect()
    return g.auth_db


def _init_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL CHECK(role IN ('admin', 'worker')),
            assigned_zone TEXT NOT NULL,
            email_verified INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            password_changed_at TEXT
        );

        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS email_tokens (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            purpose TEXT NOT NULL CHECK(purpose IN ('verify', 'reset')),
            token_hash TEXT NOT NULL UNIQUE,
            expires_at TEXT NOT NULL,
            used_at TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
        CREATE INDEX IF NOT EXISTS idx_tokens_user ON email_tokens(user_id);

        CREATE TABLE IF NOT EXISTS backend_emails (
            email TEXT PRIMARY KEY,
            first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            last_event TEXT NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS farm_snapshots (
            user_id INTEGER PRIMARY KEY,
            payload TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
        );
        """
    )
    cols = {str(row[1]) for row in conn.execute('PRAGMA table_info(users)')}
    for name, spec in (
        ('pending_name', 'TEXT'),
        ('pending_password_hash', 'TEXT'),
        ('pending_role', 'TEXT'),
        ('one_time', 'INTEGER NOT NULL DEFAULT 0'),
        ('consumed_at', 'TEXT'),
    ):
        if name not in cols:
            conn.execute(f'ALTER TABLE users ADD COLUMN {name} {spec}')
    conn.commit()


def _is_gmail(email: str) -> bool:
    return email.lower().endswith('@gmail.com') and EMAIL_RE.match(email) is not None


def _export_backend_emails(conn: sqlite3.Connection) -> None:
    rows = conn.execute(
        """
        SELECT email, first_seen_at, last_seen_at, last_event, attempt_count
        FROM backend_emails
        ORDER BY last_seen_at DESC
        """
    ).fetchall()
    payload = [
        {
            'email': row['email'],
            'firstSeenAt': row['first_seen_at'],
            'lastSeenAt': row['last_seen_at'],
            'lastEvent': row['last_event'],
            'attemptCount': row['attempt_count'],
        }
        for row in rows
    ]
    path = _DATA_DIR / 'backend_emails.json'
    path.write_text(json.dumps(payload, indent=2), encoding='utf-8')


def _record_gmail(conn: sqlite3.Connection, email: str, event: str) -> None:
    email = normalize_email(email)
    if not _is_gmail(email):
        return
    now = _iso(_utcnow())
    existing = conn.execute(
        'SELECT attempt_count FROM backend_emails WHERE email = ?', (email,)
    ).fetchone()
    if existing is None:
        conn.execute(
            """
            INSERT INTO backend_emails (
                email, first_seen_at, last_seen_at, last_event, attempt_count
            ) VALUES (?, ?, ?, ?, 1)
            """,
            (email, now, now, event),
        )
        count = 1
        first_seen = now
    else:
        conn.execute(
            """
            UPDATE backend_emails
            SET last_seen_at = ?, last_event = ?, attempt_count = attempt_count + 1
            WHERE email = ?
            """,
            (now, event, email),
        )
        count = int(existing['attempt_count']) + 1
        first_row = conn.execute(
            'SELECT first_seen_at FROM backend_emails WHERE email = ?', (email,)
        ).fetchone()
        first_seen = first_row['first_seen_at'] if first_row else now
    conn.commit()
    _export_backend_emails(conn)
    record_backend_email(
        email,
        event=event,
        first_seen_at=first_seen,
        last_seen_at=now,
        attempt_count=count,
    )


def _backfill_gmail_addresses(conn: sqlite3.Connection) -> None:
    found: set[str] = set()
    for row in conn.execute('SELECT email FROM users').fetchall():
        found.add(normalize_email(row['email']))
    for key in ('SMTP_USER', 'SMTP_FROM'):
        found.add(normalize_email(os.environ.get(key, '')))
    if _OUTBOX_DIR.is_dir():
        for path in _OUTBOX_DIR.glob('*.txt'):
            try:
                text = path.read_text(encoding='utf-8')
            except OSError:
                continue
            match = re.search(r'(?im)^To:\s*(.+)$', text)
            if match:
                found.add(normalize_email(match.group(1)))
    found.update(
        {
            'katefaithr@gmail.com',
            'katefaithritcha@gmail.com',
            'nathanram366@gmail.com',
            'justine.paghasian27@gmail.com',
            'paghasianjustine@gmail.com',
            'justinepaghasian34@gmail.com',
        }
    )
    for email in sorted(found):
        if _is_gmail(email):
            existing = conn.execute(
                'SELECT email FROM backend_emails WHERE email = ?', (email,)
            ).fetchone()
            if existing is None:
                _record_gmail(conn, email, 'backfill')


def _generate_bootstrap_password() -> str:
    alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    return ''.join(secrets.choice(alphabet) for _ in range(16))


def _seed_user(
    conn: sqlite3.Connection,
    *,
    name: str,
    email: str,
    role: str,
    zone: str,
    env_password_key: str,
    notes: list[str],
) -> None:
    email = normalize_email(email)
    row = conn.execute('SELECT id FROM users WHERE email = ?', (email,)).fetchone()
    if row is not None:
        return
    password = os.environ.get(env_password_key, '').strip()
    generated = False
    if not password:
        password = _generate_bootstrap_password()
        generated = True
    conn.execute(
        """
        INSERT INTO users (
            name, email, password_hash, role, assigned_zone,
            email_verified, created_at, password_changed_at
        ) VALUES (?, ?, ?, ?, ?, 1, ?, NULL)
        """,
        (name, email, hash_password(password), role, zone, _iso(_utcnow())),
    )
    if generated:
        notes.append(f'{email}  {env_password_key}={password}')


def _ensure_fixed_admin(conn: sqlite3.Connection) -> None:
    """Keep one reusable admin. Only the password hash is stored."""
    email = normalize_email(FIXED_ADMIN_EMAIL)
    now = _iso(_utcnow())
    password_hash = hash_password(FIXED_ADMIN_PASSWORD)
    row = conn.execute('SELECT id FROM users WHERE email = ?', (email,)).fetchone()
    if row is None:
        conn.execute(
            """
            INSERT INTO users (
                name, email, password_hash, role, assigned_zone,
                email_verified, created_at, password_changed_at, one_time, consumed_at
            ) VALUES (?, ?, ?, 'admin', 'Operations HQ', 1, ?, NULL, 0, NULL)
            """,
            (FIXED_ADMIN_NAME, email, password_hash, now),
        )
    else:
        conn.execute(
            """
            UPDATE users
            SET name = ?, password_hash = ?, role = 'admin', email_verified = 1,
                one_time = 0, consumed_at = NULL,
                pending_name = NULL, pending_password_hash = NULL, pending_role = NULL
            WHERE id = ?
            """,
            (FIXED_ADMIN_NAME, password_hash, int(row['id'])),
        )
    conn.commit()


def _is_fixed_admin(email: str) -> bool:
    return normalize_email(email) == normalize_email(FIXED_ADMIN_EMAIL)


def _consume_one_time(conn: sqlite3.Connection, user: sqlite3.Row) -> None:
    if int(user['one_time'] or 0) != 1 or user['consumed_at']:
        return
    conn.execute(
        'UPDATE users SET consumed_at = ? WHERE id = ?',
        (_iso(_utcnow()), int(user['id'])),
    )
    conn.commit()


def _seed_users(conn: sqlite3.Connection) -> None:
    notes: list[str] = []
    _seed_user(
        conn,
        name='Aira Santos',
        email=os.environ.get('AUTH_ADMIN_EMAIL', 'admin@eggsystem.local'),
        role='admin',
        zone='Operations HQ',
        env_password_key='AUTH_ADMIN_PASSWORD',
        notes=notes,
    )
    _seed_user(
        conn,
        name='Marco Reyes',
        email=os.environ.get('AUTH_WORKER_EMAIL', 'worker@eggsystem.local'),
        role='worker',
        zone='Coop B',
        env_password_key='AUTH_WORKER_PASSWORD',
        notes=notes,
    )
    conn.commit()
    if not notes:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    header = (
        'Initial passwords for first-boot seed accounts.\n'
        'These values are stored only on the server. Change them after first login.\n'
        f'Generated at {_iso(_utcnow())}\n\n'
    )
    _BOOTSTRAP_FILE.write_text(header + '\n'.join(notes) + '\n', encoding='utf-8')
    try:
        os.chmod(_BOOTSTRAP_FILE, 0o600)
    except OSError:
        pass
    print('[auth] Generated first-boot credentials (server-only):')
    for line in notes:
        print(f'[auth]   {line}')
    print(f'[auth] Also written to {_BOOTSTRAP_FILE}')


def init_auth(app: Flask) -> None:
    global VERIFY_TTL_SECONDS, RESET_TTL_SECONDS, _dummy_password_hash
    _load_dotenv()
    VERIFY_TTL_SECONDS = int(os.environ.get('AUTH_VERIFY_TTL_SECONDS', str(15 * 60)))
    RESET_TTL_SECONDS = int(os.environ.get('AUTH_RESET_TTL_SECONDS', str(60 * 60)))
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    _OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
    conn = _connect()
    try:
        _init_schema(conn)
        _seed_users(conn)
        _ensure_fixed_admin(conn)
        _backfill_gmail_addresses(conn)
        for row in conn.execute('SELECT * FROM users').fetchall():
            _sync_user_row(row)
        sync_mail_config()
        if (
            os.environ.get('AUTH_TESTING') != '1'
            and not os.environ.get('FIREBASE_WEB_API_KEY', '').strip()
        ):
            print(
                '[auth] Firestore is not connected: set FIREBASE_WEB_API_KEY in backend/.env '
                '(Firebase Console > Project settings > General > Web API Key).'
            )
    finally:
        conn.close()
    _dummy_password_hash = hash_password(secrets.token_urlsafe(24))
    app.register_blueprint(auth_bp)

    @app.teardown_appcontext
    def _close_auth_db(_exc: BaseException | None) -> None:
        conn = g.pop('auth_db', None)
        if conn is not None:
            conn.close()


def _client_ip() -> str:
    forwarded = request.headers.get('X-Forwarded-For', '').split(',')[0].strip()
    return forwarded or (request.remote_addr or 'unknown')


def _prune_hits(key: str, window_s: int) -> deque[float]:
    now = time.monotonic()
    bucket = _hits[key]
    cutoff = now - window_s
    while bucket and bucket[0] < cutoff:
        bucket.popleft()
    return bucket


def _too_many(key: str, limit: int, window_s: int) -> tuple[bool, int]:
    with _limiter_lock:
        bucket = _prune_hits(key, window_s)
        if len(bucket) >= limit:
            retry = int(window_s - (time.monotonic() - bucket[0])) + 1
            return True, max(retry, 1)
        return False, 0


def _record_hit(key: str) -> None:
    with _limiter_lock:
        _hits[key].append(time.monotonic())


def _rate_limited(key: str, limit: int, window_s: int) -> tuple[bool, int]:
    limited, retry = _too_many(key, limit, window_s)
    if limited:
        return True, retry
    _record_hit(key)
    return False, 0


def _json_error(message: str, status: int, code: str, retry_after: int | None = None):
    response = jsonify({'error': message, 'code': code})
    if retry_after is not None:
        response.headers['Retry-After'] = str(retry_after)
    return response, status


def _public_user(row: sqlite3.Row) -> dict[str, Any]:
    return {
        'id': row['id'],
        'name': row['name'],
        'email': row['email'],
        'role': row['role'],
        'assignedZone': row['assigned_zone'],
        'emailVerified': bool(row['email_verified']),
        'passwordChangedAt': row['password_changed_at'],
    }


def _sync_user_row(row: sqlite3.Row) -> None:
    try:
        upsert_user_profile(
            email=row['email'],
            name=row['name'],
            role=row['role'],
            assigned_zone=row['assigned_zone'],
            email_verified=bool(row['email_verified']),
            created_at=row['created_at'],
        )
    except Exception as exc:  # noqa: BLE001
        print(f'[auth] Firestore user sync skipped: {exc}', flush=True)


def _bearer_token() -> str | None:
    header = request.headers.get('Authorization', '')
    if header.startswith('Bearer '):
        token = header[7:].strip()
        return token or None
    return None


def _purge_expired(conn: sqlite3.Connection) -> None:
    now = _iso(_utcnow())
    conn.execute('DELETE FROM sessions WHERE expires_at <= ?', (now,))
    conn.execute(
        'DELETE FROM email_tokens WHERE used_at IS NOT NULL OR expires_at <= ?',
        (now,),
    )
    conn.commit()


def _session_user(conn: sqlite3.Connection) -> tuple[sqlite3.Row, sqlite3.Row] | None:
    token = _bearer_token()
    if not token:
        return None
    _purge_expired(conn)
    row = conn.execute(
        """
        SELECT s.id AS session_id, s.expires_at, s.last_seen_at, u.*
        FROM sessions s
        JOIN users u ON u.id = s.user_id
        WHERE s.token_hash = ?
        """,
        (hash_token(token),),
    ).fetchone()
    if row is None:
        return None
    now = _utcnow()
    last_seen = _parse_iso(row['last_seen_at'])
    expires = _parse_iso(row['expires_at'])
    if now >= expires or (now - last_seen).total_seconds() > SESSION_IDLE_SECONDS:
        conn.execute('DELETE FROM sessions WHERE id = ?', (row['session_id'],))
        conn.commit()
        return None
    conn.execute(
        'UPDATE sessions SET last_seen_at = ? WHERE id = ?',
        (_iso(now), row['session_id']),
    )
    conn.commit()
    return row, row


def _issue_session(conn: sqlite3.Connection, user_id: int) -> dict[str, Any]:
    token = new_token()
    now = _utcnow()
    expires = now + timedelta(seconds=SESSION_TTL_SECONDS)
    conn.execute(
        """
        INSERT INTO sessions (user_id, token_hash, created_at, expires_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (user_id, hash_token(token), _iso(now), _iso(expires), _iso(now)),
    )
    conn.commit()
    return {
        'token': token,
        'expiresAt': _iso(expires),
        'idleTimeoutSeconds': SESSION_IDLE_SECONDS,
    }


def _issue_email_token(
    conn: sqlite3.Connection, user_id: int, purpose: str, ttl: int, *, otp: bool = False
) -> str:
    # Keep recent unused OTP codes valid so an email the user already opened
    # still works after a resend. Reset links stay single-use.
    if not otp:
        conn.execute(
            "DELETE FROM email_tokens WHERE user_id = ? AND purpose = ? AND used_at IS NULL",
            (user_id, purpose),
        )
    token = new_otp_code() if otp else new_token()
    now = _utcnow()
    expires_at = _iso(now + timedelta(seconds=ttl))
    token_digest = hash_token(token)
    conn.execute(
        """
        INSERT INTO email_tokens (user_id, purpose, token_hash, expires_at, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        (user_id, purpose, token_digest, expires_at, _iso(now)),
    )
    conn.commit()
    email_row = conn.execute('SELECT email FROM users WHERE id = ?', (user_id,)).fetchone()
    if email_row is not None:
        write_verification_record(
            email_row['email'],
            code_hash=token_digest,
            expires_at=expires_at,
            purpose=purpose,
        )
    return token


def _public_base_url() -> str:
    return os.environ.get('AUTH_PUBLIC_BASE_URL', 'http://127.0.0.1:8000').rstrip('/')


def _smtp_configured() -> bool:
    if os.environ.get('AUTH_TESTING') == '1':
        return False
    return bool(os.environ.get('SMTP_HOST', '').strip() and os.environ.get('SMTP_PASSWORD', '').strip())


def _mail_result(smtp_message: str, outbox_message: str) -> dict[str, Any]:
    if _smtp_configured():
        return {'delivery': 'smtp', 'message': smtp_message}
    return {'delivery': 'outbox', 'message': outbox_message}


def _write_outbox(to_email: str, subject: str, body: str) -> None:
    _OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
    stamp = _utcnow().strftime('%Y%m%dT%H%M%S')
    safe = re.sub(r'[^a-zA-Z0-9_.-]', '_', to_email)
    path = _OUTBOX_DIR / f'{stamp}_{safe}.txt'
    path.write_text(
        f'To: {to_email}\nSubject: {subject}\nDate: {_iso(_utcnow())}\n\n{body}\n',
        encoding='utf-8',
    )
    print(f'[auth] Email queued for {to_email} ({subject}). Outbox: {path}', flush=True)


def _smtp_send(message: EmailMessage) -> None:
    host = os.environ.get('SMTP_HOST', '').strip()
    user = os.environ.get('SMTP_USER', '').strip()
    password = os.environ.get('SMTP_PASSWORD', '').replace(' ', '')
    errors: list[str] = []
    for port, use_ssl in ((587, False), (465, True)):
        try:
            if use_ssl:
                smtp: smtplib.SMTP = smtplib.SMTP_SSL(host, port, timeout=8)
            else:
                smtp = smtplib.SMTP(host, port, timeout=8)
                smtp.ehlo()
                smtp.starttls()
                smtp.ehlo()
            with smtp:
                if user:
                    smtp.login(user, password)
                smtp.send_message(message)
            return
        except Exception as exc:  # noqa: BLE001
            errors.append(f'{port}/{"ssl" if use_ssl else "starttls"}: {exc}')
    raise RuntimeError(' | '.join(errors))


def _code_email_html(code: str, minutes: int) -> str:
    safe = escape(code)
    return f'''<!DOCTYPE html>
<html>
<body style="margin:0;padding:0;background:#f3efe8;font-family:Arial,Helvetica,sans-serif">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f3efe8;padding:24px 12px">
    <tr><td align="center">
      <table role="presentation" width="480" cellspacing="0" cellpadding="0" style="max-width:480px;background:#ffffff;border-radius:16px;overflow:hidden;border:1px solid #e6ddd2">
        <tr>
          <td style="background:#271c15;padding:22px 28px">
            <p style="margin:0;color:#efb73e;font-size:12px;letter-spacing:2px;font-weight:700">EGG SYSTEM</p>
            <p style="margin:6px 0 0;color:#f6f1e7;font-size:20px;font-weight:700">Email verification</p>
          </td>
        </tr>
        <tr>
          <td style="padding:28px">
            <p style="margin:0 0 8px;color:#4b3c31;font-size:15px">Your verification code is</p>
            <p style="margin:0;text-align:center;font-size:36px;letter-spacing:10px;font-weight:800;color:#271c15">{safe}</p>
            <p style="margin:20px 0 0;color:#7a6a5c;font-size:14px;line-height:1.5">
              Enter this 6-digit code in the Egg System app. It expires in {minutes} minutes.
              If you did not create an account, you can ignore this email.
            </p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>'''


def _send_email(to_email: str, subject: str, body: str, html: str | None = None) -> bool:
    _write_outbox(to_email, subject, body)
    if not _smtp_configured():
        print(
            f'[auth] SMTP is not configured. No message was sent to {to_email}.',
            flush=True,
        )
        return False
    from_addr = (os.environ.get('SMTP_FROM') or os.environ.get('SMTP_USER', '')).strip()
    message = EmailMessage()
    message['From'] = formataddr(('Egg System', from_addr))
    message['To'] = to_email
    message['Subject'] = subject
    message['Reply-To'] = from_addr
    message['Message-ID'] = make_msgid(domain='gmail.com')
    message['X-Priority'] = '1'
    message['Priority'] = 'urgent'
    message['Importance'] = 'high'
    message.set_content(body)
    if html:
        message.add_alternative(html, subtype='html')
    try:
        _smtp_send(message)
    except Exception as exc:  # noqa: BLE001
        print(f'[auth] SMTP send failed for {to_email}: {exc}', flush=True)
        return False
    print(f'[auth] SMTP delivered {subject} to {to_email}', flush=True)
    return True


def _queue_verification(email: str, token: str) -> None:
    if os.environ.get('AUTH_TESTING') == '1':
        _send_verification(email, token)
        return
    threading.Thread(
        target=_send_verification,
        args=(email, token),
        daemon=True,
        name='egg-verify-mail',
    ).start()


def _otp_payload(email: str, token: str, *, created: bool) -> dict[str, Any]:
    minutes = max(1, VERIFY_TTL_SECONDS // 60)
    message = (
        f'Account created. Enter the 6-digit code shown in the app. '
        f'It expires in {minutes} minutes.'
        if created
        else f'Enter the 6-digit code shown in the app. It expires in {minutes} minutes.'
    )
    return {
        'ok': True,
        'email': email,
        'verificationCode': token,
        'delivery': 'app',
        'message': message,
    }


def _send_verification(email: str, token: str) -> bool:
    minutes = max(1, VERIFY_TTL_SECONDS // 60)
    body = (
        'Your Egg System verification code is:\n\n'
        f'{token}\n\n'
        f'Enter this 6-digit code in the app. It expires in {minutes} minutes. '
        'If you did not request this, ignore this email.\n'
    )
    return _send_email(
        email,
        f'Your Egg System verification code is {token}',
        body,
        html=_code_email_html(token, minutes),
    )


def _send_reset(email: str, token: str) -> None:
    link = f'{_public_base_url()}/auth/reset-form?token={token}'
    _send_email(
        email,
        'Reset your Egg System password',
        'Use this single-use link to choose a new password.\n\n'
        f'{link}\n\nThis link expires in 1 hour.\n',
    )


def _consume_email_token(
    conn: sqlite3.Connection, token: str, purpose: str
) -> sqlite3.Row | None:
    _purge_expired(conn)
    row = conn.execute(
        """
        SELECT t.id AS token_id, t.expires_at, t.used_at, u.*
        FROM email_tokens t
        JOIN users u ON u.id = t.user_id
        WHERE t.token_hash = ? AND t.purpose = ?
        """,
        (hash_token(token), purpose),
    ).fetchone()
    if row is None or row['used_at'] is not None:
        return None
    expires_at = _parse_iso(row['expires_at']) + timedelta(seconds=120)
    if _utcnow() >= expires_at:
        return None
    conn.execute(
        'UPDATE email_tokens SET used_at = ? WHERE id = ?',
        (_iso(_utcnow()), row['token_id']),
    )
    conn.commit()
    return row


def _html_page(title: str, message: str, ok: bool = True) -> str:
    color = '#1f7a3a' if ok else '#a33b2b'
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        f'<title>{escape(title)}</title>'
        '<style>body{font-family:sans-serif;background:#1d140f;color:#f6f1e7;'
        'display:flex;min-height:100vh;align-items:center;justify-content:center}'
        '.card{background:#2f2721;padding:32px;border-radius:16px;max-width:420px}'
        f'h1{{color:{color};font-size:22px}}</style></head><body><div class="card">'
        f'<h1>{escape(title)}</h1><p>{escape(message)}</p></div></body></html>'
    )


@auth_bp.post('/auth/signup')
def signup():
    limited, retry = _rate_limited(f'signup:ip:{_client_ip()}', SIGNUP_IP_LIMIT, SIGNUP_IP_WINDOW)
    if limited:
        return _json_error('Too many signup attempts. Try again later.', 429, 'rate_limited', retry)

    body = request.get_json(silent=True) or {}
    name = str(body.get('name') or '').strip()
    email = normalize_email(str(body.get('email') or ''))
    password = str(body.get('password') or '')
    if not name:
        return _json_error('Name is required', 400, 'invalid_request')
    if not EMAIL_RE.match(email):
        return _json_error('Enter a valid email', 400, 'invalid_request')
    password_error = validate_password(password)
    if password_error:
        return _json_error(password_error, 400, 'weak_password')
    if _is_fixed_admin(email):
        return _json_error(
            'The admin account is fixed. Workers can create their own one-time accounts.',
            403,
            'admin_fixed',
        )
    role = 'worker'

    created_new = True
    session_payload = None
    token = None
    with _db_lock:
        conn = db()
        existing = conn.execute('SELECT * FROM users WHERE email = ?', (email,)).fetchone()
        if existing is not None and existing['email_verified']:
            if int(existing['one_time'] or 0) == 1 and existing['consumed_at']:
                return _json_error(
                    'This account was already used. Create a new worker account.',
                    403,
                    'account_used',
                )
            if verify_password(password, existing['password_hash']):
                conn.execute(
                    'UPDATE users SET name = ?, role = ?, pending_name = NULL, '
                    'pending_password_hash = NULL, pending_role = NULL WHERE id = ?',
                    (name, role, int(existing['id'])),
                )
                conn.commit()
                fresh = conn.execute(
                    'SELECT * FROM users WHERE id = ?', (int(existing['id']),)
                ).fetchone()
                if fresh is not None:
                    _sync_user_row(fresh)
                    session_payload = {
                        'ok': True,
                        'alreadyVerified': True,
                        'user': _public_user(fresh),
                        'session': _issue_session(conn, int(fresh['id'])),
                        'message': 'This email is already verified. You are signed in.',
                    }
                    _consume_one_time(conn, fresh)
            else:
                created_new = False
                user_id = int(existing['id'])
                conn.execute(
                    """
                    UPDATE users
                    SET pending_name = ?, pending_password_hash = ?, pending_role = ?
                    WHERE id = ?
                    """,
                    (name, hash_password(password), role, user_id),
                )
                conn.commit()
                token = _issue_email_token(
                    conn, user_id, 'verify', VERIFY_TTL_SECONDS, otp=True
                )
                _record_gmail(conn, email, 'signup')
        elif existing is not None:
            created_new = False
            user_id = int(existing['id'])
            conn.execute(
                'UPDATE users SET name = ?, password_hash = ?, role = ? WHERE id = ?',
                (name, hash_password(password), role, user_id),
            )
            conn.commit()
            token = _issue_email_token(
                conn, user_id, 'verify', VERIFY_TTL_SECONDS, otp=True
            )
            _record_gmail(conn, email, 'signup')
            created = conn.execute('SELECT * FROM users WHERE id = ?', (user_id,)).fetchone()
            if created is not None:
                _sync_user_row(created)
        else:
            now = _iso(_utcnow())
            cursor = conn.execute(
                """
                INSERT INTO users (
                    name, email, password_hash, role, assigned_zone,
                    email_verified, created_at, password_changed_at, one_time
                ) VALUES (?, ?, ?, ?, 'Unassigned', 0, ?, NULL, 1)
                """,
                (name, email, hash_password(password), role, now),
            )
            user_id = int(cursor.lastrowid)
            token = _issue_email_token(
                conn, user_id, 'verify', VERIFY_TTL_SECONDS, otp=True
            )
            _record_gmail(conn, email, 'signup')
            created = conn.execute('SELECT * FROM users WHERE id = ?', (user_id,)).fetchone()
            if created is not None:
                _sync_user_row(created)

    if session_payload is not None:
        return jsonify(session_payload)
    if not token:
        return _json_error('Unable to create account', 500, 'signup_failed')
    _queue_verification(email, token)
    return jsonify(_otp_payload(email, token, created=created_new)), (
        201 if created_new else 200
    )


@auth_bp.post('/auth/login')
def login():
    ip = _client_ip()
    limited, retry = _too_many(f'login:ip:{ip}', LOGIN_IP_LIMIT, LOGIN_IP_WINDOW)
    if limited:
        return _json_error('Too many login attempts. Try again later.', 429, 'rate_limited', retry)

    body = request.get_json(silent=True) or {}
    email = normalize_email(str(body.get('email') or ''))
    password = str(body.get('password') or '')

    limited_email, retry_email = _too_many(
        f'login:email:{email or "unknown"}', LOGIN_EMAIL_LIMIT, LOGIN_EMAIL_WINDOW
    )
    if limited_email:
        return _json_error(
            'Too many login attempts for this account. Try again later.',
            429,
            'rate_limited',
            retry_email,
        )

    with _db_lock:
        conn = db()
        _record_gmail(conn, email, 'login')
        user = conn.execute('SELECT * FROM users WHERE email = ?', (email,)).fetchone()
        stored_hash = user['password_hash'] if user is not None else _dummy_password_hash
        password_ok = verify_password(password, stored_hash)
        if user is None or not password_ok:
            _record_hit(f'login:ip:{ip}')
            _record_hit(f'login:email:{email or "unknown"}')
            return _json_error('Invalid email or password', 401, 'invalid_credentials')
        if int(user['one_time'] or 0) == 1 and user['consumed_at']:
            return _json_error(
                'This account was already used. Create a new worker account.',
                403,
                'account_used',
            )
        if not user['email_verified']:
            token = _issue_email_token(
                conn, int(user['id']), 'verify', VERIFY_TTL_SECONDS, otp=True
            )
        else:
            token = None
            session = _issue_session(conn, int(user['id']))
            _consume_one_time(conn, user)
            payload = _public_user(user)

    if token:
        _queue_verification(email, token)
        notice = _otp_payload(email, token, created=False)
        return jsonify({
            'error': notice['message'],
            'code': 'unverified_email',
            'email': email,
            'verificationCode': token,
            'message': notice['message'],
        }), 403
    return jsonify({'user': payload, 'session': session})


@auth_bp.post('/auth/logout')
def logout():
    token = _bearer_token()
    if token:
        with _db_lock:
            conn = db()
            conn.execute('DELETE FROM sessions WHERE token_hash = ?', (hash_token(token),))
            conn.commit()
    return jsonify({'ok': True})


@auth_bp.get('/auth/me')
def me():
    with _db_lock:
        conn = db()
        pair = _session_user(conn)
        if pair is None:
            return _json_error('Session expired or invalid', 401, 'unauthorized')
        user, session_row = pair
        expires_at = session_row['expires_at']
    return jsonify({
        'user': _public_user(user),
        'session': {
            'expiresAt': expires_at,
            'idleTimeoutSeconds': SESSION_IDLE_SECONDS,
        },
    })


@auth_bp.get('/auth/health')
def auth_health():
    return jsonify({'ok': True, 'service': 'auth'})


@auth_bp.get('/farm/snapshot')
def farm_snapshot_get():
    with _db_lock:
        conn = db()
        pair = _session_user(conn)
        if pair is None:
            return _json_error('Session expired or invalid', 401, 'unauthorized')
        user, _session_row = pair
        row = conn.execute(
            'SELECT payload, updated_at FROM farm_snapshots WHERE user_id = ?',
            (user['id'],),
        ).fetchone()
    if row is None:
        return jsonify({'snapshot': None})
    try:
        payload = json.loads(row['payload'])
    except json.JSONDecodeError:
        payload = {}
    if isinstance(payload, dict) and 'updatedAt' not in payload:
        payload['updatedAt'] = row['updated_at']
    return jsonify({'snapshot': payload})


@auth_bp.post('/farm/snapshot')
def farm_snapshot_save():
    body = request.get_json(silent=True) or {}
    snapshot = body.get('snapshot')
    if not isinstance(snapshot, dict):
        return _json_error('Farm snapshot is required', 400, 'invalid_payload')
    updated_at = str(snapshot.get('updatedAt') or _iso(_utcnow()))
    snapshot['updatedAt'] = updated_at
    with _db_lock:
        conn = db()
        pair = _session_user(conn)
        if pair is None:
            return _json_error('Session expired or invalid', 401, 'unauthorized')
        user, _session_row = pair
        conn.execute(
            """
            INSERT INTO farm_snapshots (user_id, payload, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                payload = excluded.payload,
                updated_at = excluded.updated_at
            """,
            (user['id'], json.dumps(snapshot), updated_at),
        )
        conn.commit()
    return jsonify({'ok': True, 'updatedAt': updated_at})


@auth_bp.post('/auth/verify-email')
def verify_email():
    body = request.get_json(silent=True) or {}
    token = re.sub(r'\D', '', str(body.get('token') or ''))
    if not re.fullmatch(r'\d{6}', token):
        return _json_error('Enter the 6-digit verification code', 400, 'invalid_token')

    with _db_lock:
        conn = db()
        row = _consume_email_token(conn, token, 'verify')
        if row is None:
            return _json_error('This verification code is invalid or has expired.', 400, 'invalid_token')
        pending_hash = None
        pending_name = None
        pending_role = None
        keys = set(row.keys())
        if 'pending_password_hash' in keys:
            pending_hash = row['pending_password_hash']
            pending_name = row['pending_name']
            pending_role = row['pending_role']
        sets = ['email_verified = 1']
        params: list[Any] = []
        if pending_hash:
            sets.append('password_hash = ?')
            params.append(pending_hash)
            sets.append('password_changed_at = ?')
            params.append(_iso(_utcnow()))
        if pending_name:
            sets.append('name = ?')
            params.append(pending_name)
        if pending_role in ('admin', 'worker'):
            sets.append('role = ?')
            params.append(pending_role)
        sets.extend(
            [
                'pending_name = NULL',
                'pending_password_hash = NULL',
                'pending_role = NULL',
            ]
        )
        params.append(row['id'])
        conn.execute(
            f'UPDATE users SET {", ".join(sets)} WHERE id = ?',
            params,
        )
        conn.commit()
        verified_email = row['email']
        fresh = conn.execute('SELECT * FROM users WHERE id = ?', (row['id'],)).fetchone()
        if fresh is not None:
            _sync_user_row(fresh)

    mark_email_verified(verified_email)
    return jsonify({'ok': True, 'message': 'Email verified. You can now sign in.'})


@auth_bp.post('/auth/resend-verification')
def resend_verification():
    body = request.get_json(silent=True) or {}
    email = normalize_email(str(body.get('email') or ''))
    limited, retry = _rate_limited(
        f'resend:{email or _client_ip()}', RESEND_EMAIL_LIMIT, RESEND_EMAIL_WINDOW
    )
    if limited:
        return _json_error('Too many requests. Try again later.', 429, 'rate_limited', retry)

    token = None
    with _db_lock:
        conn = db()
        _record_gmail(conn, email, 'resend')
        user = conn.execute('SELECT * FROM users WHERE email = ?', (email,)).fetchone()
        if user is not None and not user['email_verified']:
            token = _issue_email_token(
                conn, int(user['id']), 'verify', VERIFY_TTL_SECONDS, otp=True
            )
        elif user is not None and user['email_verified']:
            return jsonify({
                'ok': True,
                'message': 'This email is already verified. You can sign in.',
            })
    if token:
        _queue_verification(email, token)
        return jsonify(_otp_payload(email, token, created=False))
    return jsonify({
        'ok': True,
        'message': 'This email is already verified. You can sign in.',
    })


@auth_bp.post('/auth/forgot-password')
def forgot_password():
    ip = _client_ip()
    limited, retry = _rate_limited(f'forgot:ip:{ip}', FORGOT_IP_LIMIT, FORGOT_IP_WINDOW)
    if limited:
        return _json_error('Too many reset requests. Try again later.', 429, 'rate_limited', retry)

    body = request.get_json(silent=True) or {}
    email = normalize_email(str(body.get('email') or ''))
    limited_email, retry_email = _rate_limited(
        f'forgot:email:{email or "unknown"}', FORGOT_EMAIL_LIMIT, FORGOT_EMAIL_WINDOW
    )
    if limited_email:
        return _json_error('Too many reset requests. Try again later.', 429, 'rate_limited', retry_email)

    token = None
    with _db_lock:
        conn = db()
        _record_gmail(conn, email, 'forgot')
        user = conn.execute('SELECT * FROM users WHERE email = ?', (email,)).fetchone()
        if user is not None and not _is_fixed_admin(email):
            token = _issue_email_token(conn, int(user['id']), 'reset', RESET_TTL_SECONDS)
    if token:
        _send_reset(email, token)
    notice = _mail_result(
        'If that email is registered, a password reset link has been sent.',
        'If that email is registered, a reset link was saved in backend/data/outbox. '
        'Nothing was emailed because SMTP is not configured.',
    )
    return jsonify({'ok': True, **notice})


@auth_bp.post('/auth/reset-password')
def reset_password():
    body = request.get_json(silent=True) or {}
    if not body and request.form:
        body = request.form
    token = str(body.get('token') or '')
    password = str(body.get('password') or '')
    password_error = validate_password(password)
    if password_error:
        return _json_error(password_error, 400, 'weak_password')
    if not token:
        return _json_error('Reset token is required', 400, 'invalid_token')

    with _db_lock:
        conn = db()
        row = _consume_email_token(conn, token, 'reset')
        if row is None:
            return _json_error('This reset link is invalid or has expired.', 400, 'invalid_token')
        owner = conn.execute('SELECT email FROM users WHERE id = ?', (row['id'],)).fetchone()
        if owner is not None and _is_fixed_admin(owner['email']):
            return _json_error('The admin password is fixed.', 403, 'admin_fixed')
        conn.execute(
            """
            UPDATE users
            SET password_hash = ?, password_changed_at = ?
            WHERE id = ?
            """,
            (hash_password(password), _iso(_utcnow()), row['id']),
        )
        conn.execute('DELETE FROM sessions WHERE user_id = ?', (row['id'],))
        conn.commit()
    return jsonify({'ok': True, 'message': 'Password updated. Sign in with your new password.'})


@auth_bp.get('/auth/reset-form')
def reset_form():
    token = str(request.args.get('token') or '')
    if not token:
        return _html_page('Reset failed', 'Missing token.', ok=False), 400
    token_js = json.dumps(token)
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Reset password</title>'
        '<style>body{font-family:sans-serif;background:#1d140f;color:#f6f1e7;'
        'display:flex;min-height:100vh;align-items:center;justify-content:center}'
        '.card{background:#2f2721;padding:32px;border-radius:16px;max-width:420px;width:100%}'
        'input,button{width:100%;padding:12px;margin:8px 0;border-radius:8px;border:0}'
        'button{background:#efb73e;font-weight:700;cursor:pointer}</style></head><body>'
        '<div class="card"><h1>Choose a new password</h1>'
        '<form id="reset-form">'
        '<input type="password" name="password" minlength="8" required '
        'placeholder="New password (8+ chars, letter and number)">'
        '<button type="submit">Update password</button>'
        '<p id="msg"></p></form></div>'
        '<script>'
        'document.getElementById("reset-form").addEventListener("submit",function(event){'
        'event.preventDefault();'
        f'var token={token_js};'
        'fetch("/auth/reset-password",{method:"POST",headers:{"Content-Type":"application/json"},'
        'body:JSON.stringify({token:token,password:this.password.value})})'
        '.then(function(r){return r.json()}).then(function(d){'
        'document.getElementById("msg").textContent=d.message||d.error||"Done";'
        '});'
        '});'
        '</script></body></html>'
    )


@auth_bp.post('/auth/change-password')
def change_password():
    body = request.get_json(silent=True) or {}
    current_password = str(body.get('currentPassword') or '')
    new_password = str(body.get('newPassword') or '')
    password_error = validate_password(new_password)
    if password_error:
        return _json_error(password_error, 400, 'weak_password')

    with _db_lock:
        conn = db()
        pair = _session_user(conn)
        if pair is None:
            return _json_error('Session expired or invalid', 401, 'unauthorized')
        user, session_row = pair
        if _is_fixed_admin(user['email']):
            return _json_error('The admin password is fixed.', 403, 'admin_fixed')
        if not verify_password(current_password, user['password_hash']):
            return _json_error('Current password is incorrect', 401, 'invalid_credentials')
        conn.execute(
            """
            UPDATE users
            SET password_hash = ?, password_changed_at = ?
            WHERE id = ?
            """,
            (hash_password(new_password), _iso(_utcnow()), user['id']),
        )
        conn.execute(
            'DELETE FROM sessions WHERE user_id = ? AND id != ?',
            (user['id'], session_row['session_id']),
        )
        conn.commit()
        fresh = conn.execute('SELECT * FROM users WHERE id = ?', (user['id'],)).fetchone()
    return jsonify({
        'ok': True,
        'message': 'Password updated.',
        'user': _public_user(fresh),
    })
