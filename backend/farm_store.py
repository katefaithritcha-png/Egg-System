"""Firebase Firestore storage for farm auth + ledger (no SQLite).

Collections:
  farm_users/{email}
  farm_sessions/{tokenHash}
  farm_email_tokens/{tokenHash}
  farm_shared/ledger
  farm_live/board

AUTH_TESTING=1 uses an in-memory store for unit tests.
All other environments require Firebase + a signed-in backend ID token.
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from copy import deepcopy
from typing import Any

_LOCK = threading.RLock()
_MEMORY: dict[str, Any] = {
    'users': {},  # email -> dict
    'sessions': {},  # token_hash -> dict
    'tokens': {},  # token_hash -> dict
    'farm_shared': None,
    'farm_live': None,
}

_ID_TOKEN: str | None = None
_ID_TOKEN_EXPIRES_AT = 0.0


def firestore_enabled() -> bool:
    if os.environ.get('AUTH_TESTING') == '1':
        return False
    return bool(
        os.environ.get('FIREBASE_PROJECT_ID', '').strip()
        and os.environ.get('FIREBASE_WEB_API_KEY', '').strip()
    )


def require_firebase_ready() -> None:
    """Ensure Firestore is configured and the backend has a Firebase Auth ID token."""
    if os.environ.get('AUTH_TESTING') == '1':
        return
    if not firestore_enabled():
        raise RuntimeError(
            'Firebase is required. Set FIREBASE_PROJECT_ID and FIREBASE_WEB_API_KEY.'
        )
    # Create backend Auth user if missing, then sign in for Firestore rules.
    try:
        from firebase_store import ensure_firebase_email_user
    except ImportError:
        ensure_firebase_email_user = None  # type: ignore[assignment]
    email, password = _backend_credentials()
    if ensure_firebase_email_user is not None and email and password:
        ensure_firebase_email_user(email, password)
    token = _sign_in_id_token()
    if not token:
        raise RuntimeError(
            'Firebase Auth sign-in failed for FIREBASE_BACKEND_EMAIL '
            '(or AUTH_ADMIN_EMAIL). Fix password / enable Email-Password Auth.'
        )
    print(f'[farm-store] Firebase Auth OK as {email} — Firestore writes enabled', flush=True)


def stable_user_id(email: str) -> int:
    digest = hashlib.sha256(email.strip().lower().encode('utf-8')).hexdigest()
    return int(digest[:8], 16)


def _s(value: str) -> dict[str, str]:
    return {'stringValue': str(value)}


def _b(value: bool) -> dict[str, bool]:
    return {'booleanValue': bool(value)}


def _i(value: int) -> dict[str, str]:
    return {'integerValue': str(int(value))}


def _encode_fields(data: dict[str, Any]) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    for key, value in data.items():
        if isinstance(value, bool):
            fields[key] = _b(value)
        elif isinstance(value, int) and not isinstance(value, bool):
            fields[key] = _i(value)
        elif isinstance(value, float):
            fields[key] = {'doubleValue': float(value)}
        elif isinstance(value, dict):
            fields[key] = {'stringValue': json.dumps(value)}
        elif value is None:
            fields[key] = {'nullValue': None}
        else:
            fields[key] = _s(str(value))
    fields['app'] = _s('egg_system')
    return fields


def _decode_fields(fields: dict[str, Any] | None) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if not fields:
        return out
    for key, wrapper in fields.items():
        if not isinstance(wrapper, dict):
            continue
        if 'stringValue' in wrapper:
            text = wrapper['stringValue']
            if key in ('payload',) or (text.startswith('{') or text.startswith('[')):
                try:
                    out[key] = json.loads(text)
                    continue
                except (TypeError, json.JSONDecodeError):
                    pass
            out[key] = text
        elif 'integerValue' in wrapper:
            out[key] = int(wrapper['integerValue'])
        elif 'doubleValue' in wrapper:
            out[key] = float(wrapper['doubleValue'])
        elif 'booleanValue' in wrapper:
            out[key] = bool(wrapper['booleanValue'])
        elif 'nullValue' in wrapper:
            out[key] = None
    return out


def _backend_credentials() -> tuple[str, str]:
    email = (
        os.environ.get('FIREBASE_BACKEND_EMAIL', '').strip()
        or os.environ.get('AUTH_ADMIN_EMAIL', '').strip()
    )
    password = (
        os.environ.get('FIREBASE_BACKEND_PASSWORD', '').strip()
        or os.environ.get('AUTH_ADMIN_PASSWORD', '').strip()
    )
    return email.lower(), password


def _sign_in_id_token() -> str | None:
    """Firebase Auth ID token for Firestore REST (rules use request.auth)."""
    global _ID_TOKEN, _ID_TOKEN_EXPIRES_AT
    now = time.time()
    if _ID_TOKEN and now < (_ID_TOKEN_EXPIRES_AT - 60):
        return _ID_TOKEN
    email, password = _backend_credentials()
    api_key = os.environ.get('FIREBASE_WEB_API_KEY', '').strip()
    if not email or not password or not api_key:
        print(
            '[farm-store] Missing FIREBASE_BACKEND_EMAIL/PASSWORD '
            '(or AUTH_ADMIN_*) — Firestore calls will be unauthenticated',
            flush=True,
        )
        return None
    url = (
        'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword'
        f'?key={urllib.parse.quote(api_key)}'
    )
    body = json.dumps({
        'email': email,
        'password': password,
        'returnSecureToken': True,
    }).encode('utf-8')
    request = urllib.request.Request(
        url,
        data=body,
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        detail = ''
        try:
            detail = exc.read().decode('utf-8', errors='replace')[:400]
        except Exception:
            detail = str(exc)
        print(f'[farm-store] Firebase sign-in failed: {exc.code} {detail}', flush=True)
        _ID_TOKEN = None
        _ID_TOKEN_EXPIRES_AT = 0.0
        return None
    except urllib.error.URLError as exc:
        print(f'[farm-store] Firebase sign-in skipped: {exc}', flush=True)
        return None
    token = str(payload.get('idToken') or '').strip()
    if not token:
        return None
    expires_in = int(payload.get('expiresIn') or 3600)
    _ID_TOKEN = token
    _ID_TOKEN_EXPIRES_AT = now + expires_in
    return token


def firestore_http_headers(*, content_type: bool = False) -> dict[str, str]:
    """Headers for Firestore REST — Bearer ID token when available."""
    headers: dict[str, str] = {}
    if content_type:
        headers['Content-Type'] = 'application/json'
    token = _sign_in_id_token()
    if token:
        headers['Authorization'] = f'Bearer {token}'
    return headers


def _doc_url(collection: str, doc_id: str) -> str:
    project = os.environ['FIREBASE_PROJECT_ID'].strip()
    key = os.environ['FIREBASE_WEB_API_KEY'].strip()
    encoded = urllib.parse.quote(doc_id, safe='')
    return (
        f'https://firestore.googleapis.com/v1/projects/{project}'
        f'/databases/(default)/documents/{collection}/{encoded}'
        f'?key={urllib.parse.quote(key)}'
    )


def _patch_doc(collection: str, doc_id: str, data: dict[str, Any]) -> bool:
    if not firestore_enabled():
        return False
    request = urllib.request.Request(
        _doc_url(collection, doc_id),
        data=json.dumps({'fields': _encode_fields(data)}).encode('utf-8'),
        headers=firestore_http_headers(content_type=True),
        method='PATCH',
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            response.read()
        return True
    except urllib.error.HTTPError as exc:
        detail = ''
        try:
            detail = exc.read().decode('utf-8', errors='replace')[:300]
        except Exception:
            detail = str(exc)
        # Retry once after forcing a fresh ID token (expired / revoked).
        if exc.code in (401, 403):
            global _ID_TOKEN, _ID_TOKEN_EXPIRES_AT
            _ID_TOKEN = None
            _ID_TOKEN_EXPIRES_AT = 0.0
            retry = urllib.request.Request(
                _doc_url(collection, doc_id),
                data=json.dumps({'fields': _encode_fields(data)}).encode('utf-8'),
                headers=firestore_http_headers(content_type=True),
                method='PATCH',
            )
            try:
                with urllib.request.urlopen(retry, timeout=15) as response:
                    response.read()
                return True
            except Exception as retry_exc:  # noqa: BLE001
                print(
                    f'[farm-store] PATCH {collection}/{doc_id} failed: '
                    f'{exc.code} {detail} (retry: {retry_exc})',
                    flush=True,
                )
                return False
        print(f'[farm-store] PATCH {collection}/{doc_id} failed: {exc.code} {detail}', flush=True)
        return False
    except urllib.error.URLError as exc:
        print(f'[farm-store] PATCH {collection}/{doc_id} skipped: {exc}', flush=True)
        return False


def _get_doc(collection: str, doc_id: str) -> dict[str, Any] | None:
    if not firestore_enabled():
        return None
    request = urllib.request.Request(
        _doc_url(collection, doc_id),
        headers=firestore_http_headers(),
        method='GET',
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode('utf-8'))
        return _decode_fields(payload.get('fields'))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        print(f'[farm-store] GET {collection}/{doc_id} failed: {exc.code}', flush=True)
        return None
    except urllib.error.URLError as exc:
        print(f'[farm-store] GET {collection}/{doc_id} skipped: {exc}', flush=True)
        return None


def _delete_doc(collection: str, doc_id: str) -> bool:
    if not firestore_enabled():
        return False
    request = urllib.request.Request(
        _doc_url(collection, doc_id),
        headers=firestore_http_headers(),
        method='DELETE',
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            response.read()
        return True
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return True
        print(f'[farm-store] DELETE {collection}/{doc_id} failed: {exc.code}', flush=True)
        return False
    except urllib.error.URLError as exc:
        print(f'[farm-store] DELETE {collection}/{doc_id} skipped: {exc}', flush=True)
        return False


def _list_docs(collection: str, page_size: int = 200) -> list[dict[str, Any]]:
    if not firestore_enabled():
        return []
    project = os.environ['FIREBASE_PROJECT_ID'].strip()
    key = os.environ['FIREBASE_WEB_API_KEY'].strip()
    url = (
        f'https://firestore.googleapis.com/v1/projects/{project}'
        f'/databases/(default)/documents/{collection}'
        f'?pageSize={page_size}&key={urllib.parse.quote(key)}'
    )
    request = urllib.request.Request(
        url,
        headers=firestore_http_headers(),
        method='GET',
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        print(f'[farm-store] LIST {collection} skipped: HTTP Error {exc.code}', flush=True)
        return []
    except urllib.error.URLError as exc:
        print(f'[farm-store] LIST {collection} skipped: {exc}', flush=True)
        return []
    rows: list[dict[str, Any]] = []
    for doc in payload.get('documents') or []:
        decoded = _decode_fields(doc.get('fields'))
        name = str(doc.get('name') or '')
        decoded['_docId'] = name.rsplit('/', 1)[-1]
        rows.append(decoded)
    return rows


def reset_memory_for_tests() -> None:
    with _LOCK:
        _MEMORY['users'] = {}
        _MEMORY['sessions'] = {}
        _MEMORY['tokens'] = {}
        _MEMORY['farm_shared'] = None


# ---- Users ----

def save_user(user: dict[str, Any]) -> dict[str, Any]:
    email = str(user['email']).strip().lower()
    row = dict(user)
    row['email'] = email
    row['id'] = int(row.get('id') or stable_user_id(email))
    if firestore_enabled():
        ok = _patch_doc('farm_users', email, row)
        if not ok:
            raise RuntimeError(f'Firestore save failed for farm_users/{email}')
        return row
    with _LOCK:
        _MEMORY['users'][email] = deepcopy(row)
    return row


def get_user_by_email(email: str) -> dict[str, Any] | None:
    normalized = email.strip().lower()
    if not normalized:
        return None
    if firestore_enabled():
        return _get_doc('farm_users', normalized)
    with _LOCK:
        found = _MEMORY['users'].get(normalized)
        return deepcopy(found) if found else None


def get_user_by_id(user_id: int) -> dict[str, Any] | None:
    if firestore_enabled():
        for row in _list_docs('farm_users'):
            if int(row.get('id') or 0) == int(user_id):
                return row
        return None
    with _LOCK:
        for row in _MEMORY['users'].values():
            if int(row.get('id') or 0) == int(user_id):
                return deepcopy(row)
    return None


def list_users() -> list[dict[str, Any]]:
    if firestore_enabled():
        return _list_docs('farm_users')
    with _LOCK:
        return [deepcopy(row) for row in _MEMORY['users'].values()]


# ---- Sessions ----

def save_session(session: dict[str, Any]) -> None:
    token_hash = str(session['token_hash'])
    if firestore_enabled():
        if not _patch_doc('farm_sessions', token_hash, session):
            raise RuntimeError('Firestore save failed for farm_sessions')
        return
    with _LOCK:
        _MEMORY['sessions'][token_hash] = deepcopy(session)


def get_session(token_hash: str) -> dict[str, Any] | None:
    if firestore_enabled():
        return _get_doc('farm_sessions', token_hash)
    with _LOCK:
        found = _MEMORY['sessions'].get(token_hash)
        return deepcopy(found) if found else None


def delete_session(token_hash: str) -> None:
    if firestore_enabled():
        _delete_doc('farm_sessions', token_hash)
        return
    with _LOCK:
        _MEMORY['sessions'].pop(token_hash, None)


def delete_sessions_for_user(user_id: int) -> None:
    if firestore_enabled():
        for row in _list_docs('farm_sessions'):
            if int(row.get('user_id') or 0) == int(user_id):
                doc_id = str(row.get('token_hash') or row.get('_docId') or '')
                if doc_id:
                    _delete_doc('farm_sessions', doc_id)
        return
    with _LOCK:
        drop = [
            key for key, row in _MEMORY['sessions'].items()
            if int(row.get('user_id') or 0) == int(user_id)
        ]
        for key in drop:
            _MEMORY['sessions'].pop(key, None)


# ---- Email tokens ----

def save_email_token(token: dict[str, Any]) -> None:
    token_hash = str(token['token_hash'])
    if firestore_enabled():
        if not _patch_doc('farm_email_tokens', token_hash, token):
            raise RuntimeError('Firestore save failed for farm_email_tokens')
        return
    with _LOCK:
        _MEMORY['tokens'][token_hash] = deepcopy(token)


def get_email_token(token_hash: str) -> dict[str, Any] | None:
    if firestore_enabled():
        return _get_doc('farm_email_tokens', token_hash)
    with _LOCK:
        found = _MEMORY['tokens'].get(token_hash)
        return deepcopy(found) if found else None


def delete_email_token(token_hash: str) -> None:
    if firestore_enabled():
        _delete_doc('farm_email_tokens', token_hash)
        return
    with _LOCK:
        _MEMORY['tokens'].pop(token_hash, None)


def delete_email_tokens_for_user(user_id: int, purpose: str | None = None) -> None:
    if firestore_enabled():
        for row in _list_docs('farm_email_tokens'):
            if int(row.get('user_id') or 0) != int(user_id):
                continue
            if purpose and str(row.get('purpose') or '') != purpose:
                continue
            doc_id = str(row.get('token_hash') or row.get('_docId') or '')
            if doc_id:
                _delete_doc('farm_email_tokens', doc_id)
        return
    with _LOCK:
        drop = []
        for key, row in _MEMORY['tokens'].items():
            if int(row.get('user_id') or 0) != int(user_id):
                continue
            if purpose and str(row.get('purpose') or '') != purpose:
                continue
            drop.append(key)
        for key in drop:
            _MEMORY['tokens'].pop(key, None)


# ---- Farm shared ledger ----

def load_farm_shared() -> dict[str, Any] | None:
    if firestore_enabled():
        row = _get_doc('farm_shared', 'ledger')
        if not row:
            return None
        payload = row.get('payload')
        return payload if isinstance(payload, dict) else None
    with _LOCK:
        shared = _MEMORY['farm_shared']
        return deepcopy(shared) if isinstance(shared, dict) else None


def save_farm_shared(payload: dict[str, Any], updated_at: str) -> None:
    if firestore_enabled():
        ok = _patch_doc(
            'farm_shared',
            'ledger',
            {
                'updated_at': updated_at,
                'payload': json.dumps(payload),
            },
        )
        if not ok:
            raise RuntimeError('Firestore save failed for farm_shared/ledger')
        return
    with _LOCK:
        _MEMORY['farm_shared'] = deepcopy(payload)


def load_farm_shared_decoded() -> dict[str, Any] | None:
    """Load farm shared and decode payload string if needed."""
    if firestore_enabled():
        row = _get_doc('farm_shared', 'ledger')
        if not row:
            return None
        payload = row.get('payload')
        if isinstance(payload, dict):
            return payload
        if isinstance(payload, str):
            try:
                parsed = json.loads(payload)
            except (TypeError, json.JSONDecodeError):
                return None
            return parsed if isinstance(parsed, dict) else None
        return None
    return load_farm_shared()


# ---- Live inspection board ----

def save_live_board(payload: dict[str, Any]) -> None:
    """Persist Live Inspection metrics + records to Firestore (source of truth)."""
    if firestore_enabled():
        ok = _patch_doc(
            'farm_live',
            'board',
            {
                'updated_at': str(payload.get('savedAt') or ''),
                'payload': json.dumps(payload),
            },
        )
        if not ok:
            raise RuntimeError('Firestore save failed for farm_live/board')
        return
    with _LOCK:
        _MEMORY['farm_live'] = deepcopy(payload)


def load_live_board() -> dict[str, Any] | None:
    if firestore_enabled():
        row = _get_doc('farm_live', 'board')
        if not row:
            return None
        payload = row.get('payload')
        if isinstance(payload, dict):
            return payload
        if isinstance(payload, str):
            try:
                parsed = json.loads(payload)
            except (TypeError, json.JSONDecodeError):
                return None
            return parsed if isinstance(parsed, dict) else None
        return None
    with _LOCK:
        live = _MEMORY.get('farm_live')
        return deepcopy(live) if isinstance(live, dict) else None
