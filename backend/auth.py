"""Farm accounts, sessions, and farm ledger — Firebase Firestore only.

Collection layout lives in farm_store.py. No SQLite auth store.
AUTH_TESTING=1 uses an in-memory store so unit tests need no cloud project.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import smtplib
import time
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from pathlib import Path

from flask import Flask, jsonify, request

import farm_store
from firebase_store import (
    ensure_firebase_email_user,
    firebase_email_is_verified,
    firebase_password_ok,
    lookup_firebase_id_token,
    mark_email_verified,
    record_backend_email,
    send_firebase_email_verification,
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


def reset_store_for_tests() -> None:
    """Clear in-memory farm store (AUTH_TESTING) and rate limits."""
    _login_hits.clear()
    farm_store.reset_memory_for_tests()


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


def _is_real_gmail(email: str) -> bool:
    """Only real Gmail addresses may use the farm system (reject .local / other hosts)."""
    normalized = (email or '').strip().lower()
    if not normalized or ' ' in normalized or normalized.count('@') != 1:
        return False
    local, _, domain = normalized.partition('@')
    if not local or local.startswith('.') or local.endswith('.') or '..' in local:
        return False
    # Accept gmail.com and the legacy googlemail.com alias only.
    return domain in ('gmail.com', 'googlemail.com')


def _require_gmail(email: str):
    """Return a Flask error response when email is not a real Gmail address."""
    if _is_real_gmail(email):
        return None
    return _json_error(
        'Use a real Gmail account (@gmail.com). Local emails are not allowed.',
        403,
        'gmail_required',
    )


def _sole_admin_email() -> str:
    """Only this Gmail may hold the admin role."""
    configured = os.environ.get('AUTH_ADMIN_EMAIL', 'katefaithr@gmail.com').strip().lower()
    return configured if _is_real_gmail(configured) else 'katefaithr@gmail.com'


def _is_sole_admin_email(email: str) -> bool:
    return (email or '').strip().lower() == _sole_admin_email()


def _effective_role(email: str, stored_role: str | None) -> str:
    """Map stored role to the only roles that email is allowed to use."""
    role = (stored_role or 'worker').strip().lower()
    if _is_sole_admin_email(email):
        return 'admin'
    if role == 'admin':
        return 'worker'
    if role == 'sales':
        return 'sales'
    return 'worker'


def _apply_effective_role(row: dict) -> dict:
    """Return a copy with enforced role; persist demotion/promotion when needed."""
    user = dict(row)
    email = str(user.get('email') or '').strip().lower()
    stored = str(user.get('role') or 'worker')
    effective = _effective_role(email, stored)
    user['role'] = effective
    if stored != effective and email:
        try:
            farm_store.save_user({**user, 'email': email, 'role': effective})
            print(f'[auth] Role corrected for {email}: {stored} → {effective}')
        except Exception as exc:  # noqa: BLE001
            print(f'[auth] Role correct failed for {email}: {exc}')
    return user


def _require_admin_session():
    """Admin API gate: signed-in + sole admin Gmail only."""
    row = _session_user()
    if row is None:
        return None, _json_error('Sign in again.', 401, 'unauthorized')
    email = str(row.get('email') or '').strip().lower()
    if not _is_sole_admin_email(email) or str(row.get('role') or '') != 'admin':
        return None, _json_error('Admin access required.', 403, 'forbidden')
    return row, None


def _reconcile_account_roles() -> None:
    """Ensure only the sole admin Gmail is admin; others stay worker/sales."""
    if not farm_store.firestore_enabled() and os.environ.get('AUTH_TESTING') != '1':
        return
    try:
        users = farm_store.list_users()
    except Exception as exc:  # noqa: BLE001
        print(f'[auth] Role reconcile skipped: {exc}')
        return
    for row in users:
        email = str(row.get('email') or '').strip().lower()
        if not email:
            continue
        _apply_effective_role(row)


def _seed() -> None:
    seeds = (
        (
            os.environ.get('AUTH_ADMIN_EMAIL', ''),
            os.environ.get('AUTH_ADMIN_PASSWORD', ''),
            'Farm Admin',
            'admin',
        ),
        (
            os.environ.get('AUTH_WORKER_EMAIL', ''),
            os.environ.get('AUTH_WORKER_PASSWORD', ''),
            'Farm Worker',
            'worker',
        ),
        (
            os.environ.get('AUTH_SALES_EMAIL', ''),
            os.environ.get('AUTH_SALES_PASSWORD', ''),
            'Farm Seller',
            'sales',
        ),
    )
    now = _iso(_utcnow())
    for email, password, name, role in seeds:
        normalized = (email or '').strip().lower()
        if not normalized or not password:
            continue
        if not _is_real_gmail(normalized):
            print(f'[auth] Skip seed {normalized!r}: not a real Gmail address')
            continue
        if role == 'admin' and not _is_sole_admin_email(normalized):
            print(f'[auth] Skip admin seed {normalized!r}: not the sole admin Gmail')
            continue
        if role != 'admin' and _is_sole_admin_email(normalized):
            role = 'admin'
        existing = farm_store.get_user_by_email(normalized)
        if existing is not None:
            _apply_effective_role(existing)
            # Keep sole admin login in sync with AUTH_ADMIN_PASSWORD in .env.
            if _is_sole_admin_email(normalized) and password:
                stored = str(existing.get('password_hash') or '')
                if not _password_ok(password, stored):
                    existing['password_hash'] = _hash_password(password)
                    existing['pending_password_hash'] = ''
                    existing['email_verified'] = True
                    existing['disabled'] = False
                    existing['role'] = 'admin'
                    existing['password_changed_at'] = now
                    farm_store.save_user(existing)
                    print(f'[auth] Synced sole admin password for {normalized}')
                ensure_firebase_email_user(normalized, password)
            continue
        farm_store.save_user({
            'id': farm_store.stable_user_id(normalized),
            'email': normalized,
            'name': name,
            'role': _effective_role(normalized, role),
            'password_hash': _hash_password(password),
            'pending_password_hash': '',
            'email_verified': True,
            'assigned_zone': 'Farm',
            'created_at': now,
            'password_changed_at': now,
        })
        ensure_firebase_email_user(normalized, password)


def _purge_legacy_sqlite() -> None:
    """Accounts live in Firebase only — delete leftover auth.sqlite if present."""
    db_path = Path(os.environ.get('AUTH_DB_PATH', str(_DATA_DIR / 'auth.sqlite')))
    if not db_path.is_file():
        return
    try:
        db_path.unlink()
        print(f'[auth] Removed legacy SQLite auth file {db_path}')
    except OSError as exc:
        print(f'[auth] Could not remove legacy SQLite {db_path}: {exc}')


def _user_by_email(email: str) -> dict | None:
    return farm_store.get_user_by_email(email)


def _public_user(row: dict) -> dict:
    email = str(row.get('email') or '').strip().lower()
    return {
        'id': int(row['id']),
        'name': row['name'],
        'email': email or row.get('email'),
        'role': _effective_role(email, str(row.get('role') or 'worker')),
        'assignedZone': row.get('assigned_zone') or row.get('assignedZone') or 'Farm',
        'emailVerified': bool(row.get('email_verified')),
        'disabled': bool(row.get('disabled')),
        'passwordChangedAt': row.get('password_changed_at') or None,
    }


def _sync_profile(row: dict) -> None:
    upsert_user_profile(
        email=row['email'],
        name=row['name'],
        role=row['role'],
        assigned_zone=str(row.get('assigned_zone') or 'Farm'),
        email_verified=bool(row.get('email_verified')),
        created_at=str(row.get('created_at') or _iso(_utcnow())),
        password_hash=str(row.get('password_hash') or ''),
    )


def _issue_session(user_id: int) -> dict:
    token = secrets.token_urlsafe(32)
    now = _utcnow()
    expires = _iso(now + timedelta(seconds=_SESSION_TTL))
    seen = _iso(now)
    farm_store.save_session({
        'token_hash': hash_token(token),
        'user_id': int(user_id),
        'created_at': seen,
        'expires_at': expires,
        'last_seen_at': seen,
    })
    return {
        'token': token,
        'expiresAt': expires,
        'idleTimeoutSeconds': _SESSION_IDLE,
    }


def _session_user_from_token(token: str) -> dict | None:
    if not token:
        return None
    session = farm_store.get_session(hash_token(token))
    if session is None:
        return None
    now = _utcnow()
    try:
        if _parse_iso(str(session['expires_at'])) <= now:
            return None
        if _parse_iso(str(session['last_seen_at'])) + timedelta(seconds=_SESSION_IDLE) <= now:
            return None
    except Exception:
        return None
    user = farm_store.get_user_by_id(int(session['user_id']))
    if user is None:
        return None
    session['last_seen_at'] = _iso(now)
    farm_store.save_session(session)
    user = _apply_effective_role(user)
    if bool(user.get('disabled')):
        farm_store.delete_session(hash_token(token))
        return None
    user['session_expires'] = session['expires_at']
    user['session_seen'] = session['last_seen_at']
    return user


def _session_user() -> dict | None:
    header = request.headers.get('Authorization', '')
    if not header.lower().startswith('bearer '):
        return None
    token = header.split(' ', 1)[1].strip()
    return _session_user_from_token(token)


def get_request_user():
    row = _session_user()
    return _public_user(row) if row else None


def get_user_from_authorization(authorization: str | None):
    header = (authorization or '').strip()
    if not header.lower().startswith('bearer '):
        return None
    token = header.split(' ', 1)[1].strip()
    row = _session_user_from_token(token)
    return _public_user(row) if row else None


def _revoke_sessions(user_id: int) -> None:
    farm_store.delete_sessions_for_user(user_id)


def _smtp_send(host: str, user: str, password: str, message: EmailMessage) -> None:
    import ssl

    configured = int(os.environ.get('SMTP_PORT', '587') or '587')
    ports = [configured] + [port for port in (587, 465) if port != configured]
    last_error: Exception | None = None
    ctx = ssl.create_default_context()
    for port in ports:
        try:
            if port == 465:
                with smtplib.SMTP_SSL(
                    host,
                    port,
                    timeout=30,
                    context=ctx,
                    local_hostname='localhost',
                ) as smtp:
                    smtp.ehlo()
                    smtp.login(user, password)
                    smtp.send_message(message)
                return
            with smtplib.SMTP(host, port, timeout=30, local_hostname='localhost') as smtp:
                smtp.ehlo()
                smtp.starttls(context=ctx)
                smtp.ehlo()
                smtp.login(user, password)
                smtp.send_message(message)
            return
        except Exception as exc:  # noqa: BLE001
            last_error = exc
    if last_error is not None:
        raise last_error


def _deliver_code(email: str, purpose: str, code: str) -> bool:
    """Send the 6-digit code to a real Gmail inbox. Returns True when SMTP accepted it."""
    _OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
    safe = email.replace('@', '_at_').replace('.', '_')
    stamp = _utcnow().strftime('%Y%m%d%H%M%S%f')
    path = _OUTBOX_DIR / f'{stamp}-{safe}-{purpose}.txt'
    subject = (
        'Egg System verification code'
        if purpose != 'reset'
        else 'Egg System password reset'
    )
    body = (
        f'To: {email}\n'
        f'Subject: {subject}\n\n'
        f'Your code is {code}\n'
        f'token={code}\n'
    )
    path.write_text(body, encoding='utf-8')
    if os.environ.get('AUTH_TESTING') == '1':
        print(f'[auth] verification code stored in outbox for {email}')
        return True
    host = os.environ.get('SMTP_HOST', '').strip()
    user = os.environ.get('SMTP_USER', '').strip()
    password = os.environ.get('SMTP_PASSWORD', '').replace(' ', '')
    sender = (os.environ.get('SMTP_FROM') or user).strip()
    if not (host and user and password and sender):
        print(f'[auth] SMTP not configured — code only in outbox for {email}')
        return False
    message = EmailMessage()
    message['Subject'] = subject
    message['From'] = sender
    message['To'] = email
    message.set_content(
        'Egg System\n\n'
        f'Your verification code is: {code}\n\n'
        'Enter this 6-digit code in the app to finish registration.\n'
        'It expires in one hour.\n\n'
        'If you did not create an Egg System account, ignore this email.\n'
    )
    message.add_alternative(
        (
            '<html><body style="font-family:Arial,sans-serif;line-height:1.5">'
            '<p>Egg System</p>'
            f'<p>Your verification code is:</p>'
            f'<p style="font-size:28px;letter-spacing:6px;font-weight:bold">{code}</p>'
            '<p>Enter this code in the app to finish registration. '
            'It expires in one hour.</p>'
            '<p style="color:#666">If you did not create an Egg System account, '
            'ignore this email.</p>'
            '</body></html>'
        ),
        subtype='html',
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
        return True
    except Exception as exc:  # noqa: BLE001
        print(f'[auth] SMTP send failed for {email}: {exc}')
        return False


def _issue_code(
    user_id: int,
    email: str,
    purpose: str,
    *,
    replace: bool = True,
    account_password: str | None = None,
) -> tuple[str, bool]:
    """Create a code, email it to Gmail (SMTP + Firebase link). Returns (code, emailed)."""
    code = f'{secrets.randbelow(1_000_000):06d}'
    ttl = _RESET_TTL if purpose == 'reset' else _VERIFY_TTL
    expires = _iso(_utcnow() + timedelta(seconds=ttl))
    if replace:
        farm_store.delete_email_tokens_for_user(user_id, purpose)
    farm_store.save_email_token({
        'token_hash': hash_token(code),
        'user_id': int(user_id),
        'purpose': purpose,
        'expires_at': expires,
        'created_at': _iso(_utcnow()),
        'user_email': email.strip().lower(),
    })
    write_verification_record(email, code_hash=hash_token(code), expires_at=expires, purpose=purpose)
    smtp_ok = _deliver_code(email, purpose, code)
    firebase_ok = False
    if purpose == 'verify' and account_password:
        # Firebase emails a verification link to the real Gmail over HTTPS
        # (works even when Gmail SMTP app passwords are rejected).
        firebase_ok = send_firebase_email_verification(
            email,
            account_password,
        )
    emailed = smtp_ok or firebase_ok
    if not emailed and purpose == 'verify':
        print(
            f'[auth] WARNING: no email reached {email} '
            f'(SMTP={smtp_ok}, Firebase={firebase_ok})',
        )
    return code, emailed


def _signup_mail_payload(message: str, code: str, emailed: bool) -> dict:
    """Codes go to Gmail. Only echo them back for tests / explicit debug."""
    payload: dict = {
        'message': message,
        'emailSent': emailed,
    }
    expose = (
        os.environ.get('AUTH_TESTING') == '1'
        or os.environ.get('AUTH_EXPOSE_CODES', '').strip() == '1'
    )
    if expose:
        payload['verificationCode'] = code
    return payload


def _json_error(message: str, status: int, code: str, **extra):
    payload = {'error': message, 'code': code}
    payload.update(extra)
    return jsonify(payload), status


def _password_policy(password: str) -> str | None:
    if len(password) < 8 or not any(ch.isalpha() for ch in password) or not any(ch.isdigit() for ch in password):
        return 'Password must be at least 8 characters and include a letter and a number.'
    return None


def _role_from_request(body: dict, *, default: str = 'worker') -> str:
    role = str(body.get('role') or default).strip().lower()
    if role in ('worker', 'sales'):
        return role
    return default


def _merge_farm_payload(existing: dict | None, incoming: dict) -> dict:
    if not existing:
        return dict(incoming)
    merged = dict(existing)
    for key, value in incoming.items():
        if key in ('eggSales', 'movements', 'detectionRecords', 'deletedEggSaleIds'):
            continue
        merged[key] = value

    def _by_id(rows: list, id_key: str = 'id') -> dict[str, dict]:
        out: dict[str, dict] = {}
        for row in rows:
            if isinstance(row, dict):
                rid = str(row.get(id_key) or '').strip()
                if rid:
                    out[rid] = row
        return out

    def _id_set(raw) -> set[str]:
        if not isinstance(raw, list):
            return set()
        return {str(item).strip() for item in raw if str(item).strip()}

    deleted_ids = _id_set(existing.get('deletedEggSaleIds')) | _id_set(
        incoming.get('deletedEggSaleIds')
    )
    merged['deletedEggSaleIds'] = sorted(deleted_ids)[-500:]

    old_sales = existing.get('eggSales') if isinstance(existing.get('eggSales'), list) else []
    new_sales = incoming.get('eggSales') if isinstance(incoming.get('eggSales'), list) else []
    sales_map = _by_id([*old_sales, *new_sales])
    for sale_id in deleted_ids:
        sales_map.pop(sale_id, None)
    merged['eggSales'] = sorted(
        sales_map.values(),
        key=lambda row: str(row.get('createdAt') or ''),
        reverse=True,
    )

    old_moves = existing.get('movements') if isinstance(existing.get('movements'), list) else []
    new_moves = incoming.get('movements') if isinstance(incoming.get('movements'), list) else []
    move_map = _by_id([*old_moves, *new_moves])
    merged['movements'] = sorted(
        move_map.values(),
        key=lambda row: str(row.get('timestamp') or ''),
        reverse=True,
    )[:500]

    old_det = existing.get('detectionRecords') if isinstance(existing.get('detectionRecords'), list) else []
    new_det = incoming.get('detectionRecords') if isinstance(incoming.get('detectionRecords'), list) else []
    det_map = _by_id([*old_det, *new_det])
    merged['detectionRecords'] = list(det_map.values())[:400]

    old_ts = str(existing.get('updatedAt') or '')
    new_ts = str(incoming.get('updatedAt') or '')
    if new_ts >= old_ts and isinstance(incoming.get('inventory'), list):
        merged['inventory'] = incoming['inventory']
    elif isinstance(existing.get('inventory'), list):
        merged['inventory'] = existing['inventory']

    merged['updatedAt'] = max(old_ts, new_ts) or _iso(_utcnow())
    return merged


def put_shared_farm_snapshot(user_id: int, payload: dict) -> dict:
    _ = user_id
    existing = farm_store.load_farm_shared_decoded()
    merged = _merge_farm_payload(existing, payload)
    farm_store.save_farm_shared(merged, _iso(_utcnow()))
    return merged


def get_shared_farm_snapshot(user_id: int) -> dict | None:
    _ = user_id
    return farm_store.load_farm_shared_decoded()


def _find_token(token: str, purpose: str | None):
    if not token:
        return None
    token_row = farm_store.get_email_token(hash_token(token))
    if token_row is None:
        return None
    if purpose and str(token_row.get('purpose') or '') != purpose:
        return None
    try:
        if _parse_iso(str(token_row['expires_at'])) <= _utcnow():
            return None
    except Exception:
        return None
    user = farm_store.get_user_by_id(int(token_row['user_id']))
    if user is None:
        return None
    return token_row, user


def _consume_code(token: str, *, apply_pending: bool, sign_in: bool = False):
    found = _find_token(token, None if sign_in else 'verify')
    if found is None and not sign_in:
        found = _find_token(token, 'verify')
    if found is None:
        return _json_error('That code is invalid or expired.', 400, 'invalid_token')
    token_row, user = found
    if token_row.get('purpose') == 'reset' and not sign_in:
        return _json_error('That code is invalid or expired.', 400, 'invalid_token')
    now = _iso(_utcnow())
    pending = user.get('pending_password_hash') if apply_pending else None
    updated = dict(user)
    updated['email_verified'] = True
    if pending:
        updated['password_hash'] = pending
        updated['pending_password_hash'] = ''
        updated['password_changed_at'] = now
    farm_store.save_user(updated)
    farm_store.delete_email_token(str(token_row['token_hash']))
    fresh = _user_by_email(user['email'])
    assert fresh is not None
    mark_email_verified(fresh['email'])
    _sync_profile(fresh)
    if sign_in:
        session = _issue_session(int(fresh['id']))
        return jsonify({
            'message': 'Email verified.',
            'user': _public_user(fresh),
            'session': session,
        })
    return jsonify({'message': 'Email verified.'})


def init_auth(app: Flask) -> None:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    if os.environ.get('AUTH_TESTING') != '1':
        # Accounts + farm ledger must live in Firebase — no SQLite / memory fallback.
        farm_store.require_firebase_ready()
        # Mirror seed Gmail accounts into Firebase Auth so console shows them.
        # Skip quietly on Auth quota / network errors so live CAM stays up.
        for env_email, env_pass in (
            ('AUTH_ADMIN_EMAIL', 'AUTH_ADMIN_PASSWORD'),
            ('AUTH_WORKER_EMAIL', 'AUTH_WORKER_PASSWORD'),
            ('AUTH_SALES_EMAIL', 'AUTH_SALES_PASSWORD'),
        ):
            em = (os.environ.get(env_email) or '').strip()
            pw = (os.environ.get(env_pass) or '').strip()
            if em and pw and _is_real_gmail(em):
                try:
                    ensure_firebase_email_user(em, pw)
                except Exception as exc:  # noqa: BLE001
                    print(f'[auth] seed Auth skip {em}: {exc}', flush=True)
    _seed()
    _purge_legacy_sqlite()
    _reconcile_account_roles()
    if farm_store.firestore_enabled():
        print(
            f'[auth] Storage: Firebase Firestore | sole admin: {_sole_admin_email()}'
        )
    else:
        print('[auth] Storage backend: in-memory (AUTH_TESTING only)')
    if os.environ.get('AUTH_TESTING') != '1':
        sync_mail_config()

    @app.get('/auth/health')
    def auth_health():
        return jsonify({
            'ok': True,
            'service': 'egg-system-auth',
            'storage': 'firestore' if farm_store.firestore_enabled() else 'memory',
            'sqlite': False,
            'soleAdmin': _sole_admin_email(),
        })

    @app.post('/auth/signup')
    def signup():
        body = request.get_json(silent=True) or {}
        name = str(body.get('name') or '').strip()
        email = str(body.get('email') or '').strip().lower()
        password = str(body.get('password') or '')
        role = _role_from_request(body)
        if not name or '@' not in email:
            return _json_error('Enter a name and email.', 400, 'invalid_request')
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        policy = _password_policy(password)
        if policy:
            return _json_error(policy, 400, 'weak_password')
        existing = _user_by_email(email)
        now = _iso(_utcnow())
        if existing is None:
            row = farm_store.save_user({
                'id': farm_store.stable_user_id(email),
                'email': email,
                'name': name,
                'role': _effective_role(email, role),
                'password_hash': _hash_password(password),
                'pending_password_hash': '',
                'email_verified': False,
                'assigned_zone': 'Farm',
                'created_at': now,
                'password_changed_at': '',
            })
            code, emailed = _issue_code(
                int(row['id']), email, 'verify', account_password=password,
            )
            ensure_firebase_email_user(email, password)
            _sync_profile(row)
            if not emailed:
                return _json_error(
                    'Account saved, but we could not email your Gmail. '
                    'Fix SMTP_PASSWORD (Gmail App Password) on the farm server, then tap Resend.',
                    503,
                    'email_delivery_failed',
                )
            return jsonify(_signup_mail_payload(
                'Account created. Enter the 6-digit code we sent to your Gmail.',
                code,
                emailed,
            )), 201
        if not existing.get('email_verified'):
            updated = dict(existing)
            updated['name'] = name
            # Keep assigned role (admin create) unless this is the sole admin Gmail.
            updated['role'] = _effective_role(
                email,
                'admin' if _is_sole_admin_email(email) else (existing.get('role') or role),
            )
            password_matches = _password_ok(
                password, str(existing.get('password_hash') or ''),
            )
            if not password_matches:
                updated['password_hash'] = _hash_password(password)
            farm_store.save_user(updated)
            ensure_firebase_email_user(email, password)
            # Same password as admin-created account → keep existing codes valid
            # (admin may have already shared the authentication code).
            code, emailed = _issue_code(
                int(existing['id']),
                email,
                'verify',
                replace=not password_matches,
                account_password=password,
            )
            if not emailed:
                return _json_error(
                    'Could not email your Gmail. Fix the farm SMTP App Password, then tap Resend.',
                    503,
                    'email_delivery_failed',
                    verificationCode=code if (
                        os.environ.get('AUTH_TESTING') == '1'
                        or os.environ.get('AUTH_EXPOSE_CODES', '').strip() == '1'
                    ) else None,
                )
            return jsonify(_signup_mail_payload(
                'Enter the 6-digit authentication code from your Gmail to finish registering.',
                code,
                emailed,
            )), 200
        if _password_ok(password, str(existing.get('password_hash') or '')):
            # Never let signup escalate/demote away from assigned roles except
            # the sole admin Gmail (always admin).
            existing = _apply_effective_role(existing)
            assert existing is not None
            session = _issue_session(int(existing['id']))
            return jsonify({
                'message': 'Signed in.',
                'user': _public_user(existing),
                'session': session,
            }), 200
        updated = dict(existing)
        updated['pending_password_hash'] = _hash_password(password)
        farm_store.save_user(updated)
        code, emailed = _issue_code(
            int(existing['id']), email, 'verify', account_password=password,
        )
        if not emailed:
            return _json_error(
                'Could not email your Gmail. Fix the farm SMTP App Password, then tap Resend.',
                503,
                'email_delivery_failed',
            )
        return jsonify(_signup_mail_payload(
            'Confirm the code we sent to your Gmail to update this account.',
            code,
            emailed,
        )), 200

    @app.post('/auth/login')
    def login():
        body = request.get_json(silent=True) or {}
        email = str(body.get('email') or '').strip().lower()
        password = str(body.get('password') or '')
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        if _rate_limited(email):
            return _json_error('Too many sign-in attempts. Try again later.', 429, 'rate_limited')
        row = _user_by_email(email)
        if row is None and firebase_password_ok(email, password):
            now = _iso(_utcnow())
            row = farm_store.save_user({
                'id': farm_store.stable_user_id(email),
                'email': email,
                'name': email.split('@')[0],
                'role': _effective_role(email, 'worker'),
                'password_hash': _hash_password(password),
                'pending_password_hash': '',
                'email_verified': True,
                'assigned_zone': 'Farm',
                'created_at': now,
                'password_changed_at': now,
            })
        if row is None or not _password_ok(password, str(row.get('password_hash') or '')):
            if row is not None and firebase_password_ok(email, password):
                # Firebase Auth accepted — sync farm hash so future logins match.
                row['password_hash'] = _hash_password(password)
                row['pending_password_hash'] = ''
                row['password_changed_at'] = _iso(_utcnow())
                farm_store.save_user(row)
            else:
                return _json_error('Wrong email or password.', 401, 'invalid_credentials')
        row = _apply_effective_role(row)
        if bool(row.get('disabled')):
            return _json_error(
                'This account has been disabled. Contact the farm admin.',
                403,
                'account_disabled',
            )
        if not row.get('email_verified'):
            code, emailed = _issue_code(
                int(row['id']),
                email,
                'verify',
                replace=False,
                account_password=password,
            )
            extra = {'emailSent': emailed}
            if (
                os.environ.get('AUTH_TESTING') == '1'
                or os.environ.get('AUTH_EXPOSE_CODES', '').strip() == '1'
            ):
                extra['verificationCode'] = code
            return _json_error(
                'Verify your email before signing in. Check your Gmail for the code.',
                403,
                'unverified_email',
                **extra,
            )
        _clear_rate(email)
        session = _issue_session(int(row['id']))
        return jsonify({'user': _public_user(row), 'session': session})

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
        password = str(body.get('password') or '')
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        row = _user_by_email(email)
        if row is not None and not row.get('email_verified'):
            code, emailed = _issue_code(
                int(row['id']),
                email,
                'verify',
                account_password=password or None,
            )
            if not emailed:
                return _json_error(
                    'Could not email your Gmail inbox. Try again in a minute.',
                    503,
                    'email_delivery_failed',
                )
            return jsonify(_signup_mail_payload(
                'A new verification code was sent to your Gmail.',
                code,
                emailed,
            ))
        return jsonify({
            'message': 'If the account is unverified, a new code was sent to Gmail.',
            'emailSent': True,
        })

    @app.post('/auth/confirm-firebase-email')
    def confirm_firebase_email():
        """After the user opens Firebase's Gmail verification link, sync farm account."""
        body = request.get_json(silent=True) or {}
        email = str(body.get('email') or '').strip().lower()
        password = str(body.get('password') or '')
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        if not password:
            return _json_error('Password is required.', 400, 'invalid_request')
        row = _user_by_email(email)
        if row is None:
            return _json_error('Account not found.', 404, 'not_found')
        if row.get('email_verified'):
            session = _issue_session(int(row['id']))
            return jsonify({
                'message': 'Email already verified.',
                'user': _public_user(row),
                'session': session,
            })
        if not firebase_email_is_verified(email, password):
            return _json_error(
                'Open the verification link in your Gmail first, then try again.',
                403,
                'firebase_unverified',
            )
        now = _iso(_utcnow())
        updated = dict(row)
        updated['email_verified'] = True
        pending = str(updated.get('pending_password_hash') or '')
        if pending:
            updated['password_hash'] = pending
            updated['pending_password_hash'] = ''
            updated['password_changed_at'] = now
        farm_store.save_user(updated)
        mark_email_verified(email)
        fresh = _user_by_email(email)
        assert fresh is not None
        session = _issue_session(int(fresh['id']))
        return jsonify({
            'message': 'Gmail verified.',
            'user': _public_user(fresh),
            'session': session,
        })

    @app.get('/auth/code-hint')
    def code_hint():
        """Landing page after Firebase email link — shows the 6-digit code."""
        code = str(request.args.get('c') or '').strip()
        digits = ''.join(ch for ch in code if ch.isdigit())[:6]
        if len(digits) != 6:
            return (
                '<!doctype html><html><body style="font-family:sans-serif">'
                '<h2>Egg System</h2><p>Open the app and enter the code from your Gmail.'
                '</p></body></html>'
            ), 200, {'Content-Type': 'text/html; charset=utf-8'}
        html = (
            '<!doctype html><html><body style="font-family:Arial,sans-serif;'
            'text-align:center;padding:48px">'
            '<h2>Egg System</h2>'
            '<p>Your verification code is</p>'
            f'<p style="font-size:36px;letter-spacing:8px;font-weight:700">{digits}</p>'
            '<p>Enter this code in the Egg System app.</p>'
            '</body></html>'
        )
        return html, 200, {'Content-Type': 'text/html; charset=utf-8'}

    @app.post('/auth/forgot-password')
    def forgot_password():
        body = request.get_json(silent=True) or {}
        email = str(body.get('email') or '').strip().lower()
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        row = _user_by_email(email)
        if row is not None:
            _issue_code(int(row['id']), email, 'reset')
        return jsonify({'message': _FORGOT_MESSAGE})

    @app.post('/auth/reset-password')
    def reset_password():
        body = request.get_json(silent=True) or {}
        token = str(body.get('token') or '').strip()
        password = str(body.get('password') or '')
        policy = _password_policy(password)
        if policy:
            return _json_error(policy, 400, 'weak_password')
        found = _find_token(token, 'reset')
        if found is None:
            return _json_error('That code is invalid or expired.', 400, 'invalid_token')
        token_row, user = found
        now = _iso(_utcnow())
        updated = dict(user)
        updated['password_hash'] = _hash_password(password)
        updated['pending_password_hash'] = ''
        updated['password_changed_at'] = now
        farm_store.save_user(updated)
        farm_store.delete_email_token(str(token_row['token_hash']))
        _revoke_sessions(int(user['id']))
        return jsonify({'message': 'Password updated.'})

    @app.post('/auth/change-password')
    def change_password():
        body = request.get_json(silent=True) or {}
        current = str(body.get('currentPassword') or '')
        new_password = str(body.get('newPassword') or '')
        policy = _password_policy(new_password)
        if policy:
            return _json_error(policy, 400, 'weak_password')
        row = _session_user()
        if row is None:
            return _json_error('Sign in again.', 401, 'unauthorized')
        if not _password_ok(current, str(row.get('password_hash') or '')):
            return _json_error('Current password is wrong.', 401, 'invalid_credentials')
        now = _iso(_utcnow())
        updated = dict(row)
        updated['password_hash'] = _hash_password(new_password)
        updated['password_changed_at'] = now
        farm_store.save_user(updated)
        fresh = _user_by_email(row['email'])
        assert fresh is not None
        return jsonify({'message': 'Password updated.', 'user': _public_user(fresh)})

    @app.get('/auth/me')
    def me():
        row = _session_user()
        if row is None:
            return _json_error('Sign in again.', 401, 'unauthorized')
        header = request.headers.get('Authorization', '')
        token = header.split(' ', 1)[1].strip() if ' ' in header else ''
        return jsonify({
            'user': _public_user(row),
            'session': {
                'token': token,
                'expiresAt': row.get('session_expires'),
                'idleTimeoutSeconds': _SESSION_IDLE,
            },
        })

    @app.get('/auth/users')
    def list_accounts():
        """Admin-only directory of real Gmail farm accounts."""
        _admin, err = _require_admin_session()
        if err is not None:
            return err
        users = []
        for item in farm_store.list_users():
            email = str(item.get('email') or '').strip().lower()
            if not _is_real_gmail(email):
                continue
            users.append(_public_user(_apply_effective_role(item)))
        users.sort(
            key=lambda u: (
                {'admin': 0, 'worker': 1, 'sales': 2}.get(str(u.get('role')), 9),
                str(u.get('name') or '').lower(),
                str(u.get('email') or '').lower(),
            )
        )
        return jsonify({'users': users, 'count': len(users)})

    @app.post('/auth/admin/create-user')
    def admin_create_user():
        """Sole admin creates a worker/seller in Firebase and emails a verification code.

        The new person still registers by entering that code (Sign up / Verify).
        The code is also returned here so the admin can share it if Gmail is slow.
        """
        _admin, err = _require_admin_session()
        if err is not None:
            return err

        body = request.get_json(silent=True) or {}
        name = str(body.get('name') or '').strip()
        email = str(body.get('email') or '').strip().lower()
        password = str(body.get('password') or '')
        role = _role_from_request(body, default='worker')
        if role not in ('worker', 'sales'):
            role = 'worker'
        if _is_sole_admin_email(email):
            return _json_error(
                'That Gmail is reserved for the farm admin account.',
                400,
                'admin_reserved',
            )
        if not name or '@' not in email:
            return _json_error('Enter a name and Gmail.', 400, 'invalid_request')
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        policy = _password_policy(password)
        if policy:
            return _json_error(policy, 400, 'weak_password')

        existing = _user_by_email(email)
        now = _iso(_utcnow())
        if existing is not None and existing.get('email_verified'):
            # Keep role aligned if admin re-creates a verified seller/worker.
            if str(existing.get('role') or '') != role:
                updated = dict(existing)
                updated['role'] = role
                updated['name'] = name or updated.get('name') or name
                farm_store.save_user(updated)
                existing = _user_by_email(email)
            return jsonify({
                'message': (
                    f'That Gmail is already registered as {existing.get("role")}. '
                    'They can sign in with their password.'
                ),
                'emailSent': False,
                'alreadyRegistered': True,
                'user': _public_user(existing),
            }), 200

        if existing is None:
            row = farm_store.save_user({
                'id': farm_store.stable_user_id(email),
                'email': email,
                'name': name,
                'role': role,
                'password_hash': _hash_password(password),
                'pending_password_hash': '',
                'email_verified': False,
                'disabled': False,
                'assigned_zone': 'Farm',
                'created_at': now,
                'password_changed_at': '',
            })
        else:
            row = dict(existing)
            row['name'] = name
            row['role'] = role
            row['password_hash'] = _hash_password(password)
            row['pending_password_hash'] = ''
            row['email_verified'] = False
            row['disabled'] = bool(row.get('disabled'))
            farm_store.save_user(row)

        ensure_firebase_email_user(email, password)
        _sync_profile(row)
        code, emailed = _issue_code(
            int(row['id']), email, 'verify', account_password=password,
        )
        role_label = 'seller' if role == 'sales' else 'worker'
        if emailed:
            message = (
                f'{role_label.capitalize()} account created for {email}. '
                f'A verification code was emailed to that Gmail. '
                f'They Sign in with this password, then enter the code to finish registering.'
            )
        else:
            message = (
                f'{role_label.capitalize()} account created for {email}, but the email '
                f'could not be delivered. Share the authentication code below — they Sign in, '
                f'then enter it to finish registering.'
            )
        return jsonify({
            'message': message,
            'emailSent': emailed,
            'verificationCode': code,
            'alreadyRegistered': False,
            'user': _public_user(row),
        }), 201

    @app.post('/auth/admin/update-user')
    def admin_update_user():
        """Sole admin: change worker/seller role and/or disable the account."""
        _admin, err = _require_admin_session()
        if err is not None:
            return err
        body = request.get_json(silent=True) or {}
        email = str(body.get('email') or '').strip().lower()
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        if _is_sole_admin_email(email):
            return _json_error(
                'The farm admin account cannot be disabled or reassigned.',
                400,
                'admin_protected',
            )
        row = _user_by_email(email)
        if row is None:
            return _json_error('Account not found.', 404, 'not_found')
        updated = dict(row)
        changed = False
        if 'role' in body:
            role = str(body.get('role') or '').strip().lower()
            if role not in ('worker', 'sales'):
                return _json_error(
                    'Role must be worker or seller (sales).',
                    400,
                    'invalid_role',
                )
            if str(updated.get('role') or '') != role:
                updated['role'] = role
                changed = True
        if 'disabled' in body:
            disabled = bool(body.get('disabled'))
            if bool(updated.get('disabled')) != disabled:
                updated['disabled'] = disabled
                changed = True
                if disabled:
                    farm_store.delete_sessions_for_user(int(updated['id']))
        if not changed:
            return jsonify({
                'message': 'No changes.',
                'user': _public_user(updated),
            })
        farm_store.save_user(updated)
        fresh = _apply_effective_role(_user_by_email(email) or updated)
        _sync_profile(fresh)
        action = []
        if 'role' in body:
            action.append(f"role={fresh.get('role')}")
        if 'disabled' in body:
            action.append('disabled' if fresh.get('disabled') else 'enabled')
        return jsonify({
            'message': f'Updated {email} ({", ".join(action)}).',
            'user': _public_user(fresh),
        })

    @app.post('/auth/logout')
    def logout():
        header = request.headers.get('Authorization', '')
        token = header.split(' ', 1)[1].strip() if header.lower().startswith('bearer ') else ''
        if token:
            farm_store.delete_session(hash_token(token))
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
        blocked = _require_gmail(email)
        if blocked is not None:
            return blocked
        requested = str(body.get('role') or 'worker').strip().lower()
        requested = requested if body.get('setRole') and requested in ('worker', 'sales') else 'worker'
        name = str(record.get('displayName') or email.split('@')[0])
        row = _user_by_email(email)
        now = _iso(_utcnow())
        if row is None:
            row = farm_store.save_user({
                'id': farm_store.stable_user_id(email),
                'email': email,
                'name': name,
                'role': _effective_role(email, requested),
                'password_hash': _hash_password(secrets.token_urlsafe(24)),
                'pending_password_hash': '',
                'email_verified': True,
                'assigned_zone': 'Farm',
                'created_at': now,
                'password_changed_at': '',
            })
        else:
            row = _apply_effective_role(row)
        session = _issue_session(int(row['id']))
        return jsonify({'user': _public_user(row), 'session': session})

    @app.put('/farm/snapshot')
    def save_farm_snapshot():
        row_user = get_user_from_authorization(request.headers.get('Authorization'))
        if row_user is None:
            return _json_error('Sign in again.', 401, 'unauthorized')
        payload = request.get_json(silent=True) or {}
        if not isinstance(payload, dict):
            return _json_error('Invalid farm snapshot.', 400, 'invalid_request')
        try:
            merged = put_shared_farm_snapshot(int(row_user['id']), payload)
        except Exception as exc:  # noqa: BLE001
            return _json_error(str(exc) or 'Unable to save farm.', 500, 'farm_save_failed')
        return jsonify({'ok': True, 'snapshot': merged})

    @app.get('/farm/snapshot')
    def load_farm_snapshot():
        row_user = get_user_from_authorization(request.headers.get('Authorization'))
        if row_user is None:
            return _json_error('Sign in again.', 401, 'unauthorized')
        shared = get_shared_farm_snapshot(int(row_user['id']))
        if shared is None:
            return jsonify({'snapshot': None}), 404
        return jsonify({'snapshot': shared})
