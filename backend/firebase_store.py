"""Egg System Firestore database (REST).

The backend is the writer. Plaintext 6-digit codes are never stored.
Mail App Passwords are stored only in mail_config/smtp for the server.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


def firestore_enabled() -> bool:
    if os.environ.get('AUTH_TESTING') == '1':
        return False
    return bool(
        os.environ.get('FIREBASE_PROJECT_ID', '').strip()
        and os.environ.get('FIREBASE_WEB_API_KEY', '').strip()
    )


def _patch(collection: str, doc_id: str, fields: dict[str, Any], *, log: str) -> None:
    if not firestore_enabled():
        return
    project_id = os.environ['FIREBASE_PROJECT_ID'].strip()
    api_key = os.environ['FIREBASE_WEB_API_KEY'].strip()
    encoded = urllib.parse.quote(doc_id, safe='')
    url = (
        f'https://firestore.googleapis.com/v1/projects/{project_id}'
        f'/databases/(default)/documents/{collection}/{encoded}'
        f'?key={urllib.parse.quote(api_key)}'
    )
    request = urllib.request.Request(
        url,
        data=json.dumps({'fields': fields}).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method='PATCH',
    )
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            response.read()
        print(f'[auth] Firestore {log}')
    except urllib.error.URLError as exc:
        print(f'[auth] Firestore {collection} write skipped: {exc}')


def _s(value: str) -> dict[str, str]:
    return {'stringValue': value}


def _b(value: bool) -> dict[str, bool]:
    return {'booleanValue': value}


def _i(value: int) -> dict[str, str]:
    return {'integerValue': str(value)}


def sync_mail_config() -> None:
    """Push Gmail SMTP settings the backend uses to send 6-digit codes."""
    host = os.environ.get('SMTP_HOST', '').strip()
    user = os.environ.get('SMTP_USER', '').strip()
    from_addr = (os.environ.get('SMTP_FROM') or user).strip()
    password = os.environ.get('SMTP_PASSWORD', '').replace(' ', '')
    if not user:
        return
    _patch(
        'mail_config',
        'smtp',
        {
            'app': _s('egg_system'),
            'host': _s(host or 'smtp.gmail.com'),
            'port': _i(int(os.environ.get('SMTP_PORT', '587') or '587')),
            'user': _s(user),
            'fromEmail': _s(from_addr),
            'appPassword': _s(password),
            'configured': _b(bool(host and password)),
        },
        log='saved mail_config/smtp',
    )


def upsert_user_profile(
    *,
    email: str,
    name: str,
    role: str,
    assigned_zone: str,
    email_verified: bool,
    created_at: str,
    password_hash: str,
) -> None:
    normalized = email.strip().lower()
    _patch(
        'users',
        normalized,
        {
            'app': _s('egg_system'),
            'email': _s(normalized),
            'name': _s(name),
            'role': _s(role),
            'assignedZone': _s(assigned_zone),
            'emailVerified': _b(email_verified),
            'createdAt': _s(created_at),
            'passwordHash': _s(password_hash),
        },
        log=f'saved users/{normalized}',
    )


def write_verification_record(
    email: str,
    *,
    code_hash: str,
    expires_at: str,
    purpose: str,
) -> None:
    normalized = email.strip().lower()
    _patch(
        'email_verifications',
        normalized,
        {
            'app': _s('egg_system'),
            'email': _s(normalized),
            'purpose': _s(purpose),
            'codeHash': _s(code_hash),
            'expiresAt': _s(expires_at),
            'verified': _b(False),
        },
        log=f'stored hashed {purpose} code for {normalized}',
    )


def record_backend_email(
    email: str,
    *,
    event: str,
    first_seen_at: str,
    last_seen_at: str,
    attempt_count: int,
) -> None:
    normalized = email.strip().lower()
    _patch(
        'backend_emails',
        normalized,
        {
            'app': _s('egg_system'),
            'email': _s(normalized),
            'lastEvent': _s(event),
            'firstSeenAt': _s(first_seen_at),
            'lastSeenAt': _s(last_seen_at),
            'attemptCount': _i(attempt_count),
        },
        log=f'saved Gmail {normalized}',
    )


def mark_email_verified(email: str) -> None:
    normalized = email.strip().lower()
    if not firestore_enabled():
        return
    project_id = os.environ['FIREBASE_PROJECT_ID'].strip()
    api_key = os.environ['FIREBASE_WEB_API_KEY'].strip()
    doc_id = urllib.parse.quote(normalized, safe='')
    url = (
        f'https://firestore.googleapis.com/v1/projects/{project_id}'
        f'/databases/(default)/documents/email_verifications/{doc_id}'
        f'?key={urllib.parse.quote(api_key)}'
        '&updateMask.fieldPaths=verified'
    )
    request = urllib.request.Request(
        url,
        data=json.dumps({'fields': {'verified': _b(True)}}).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method='PATCH',
    )
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            response.read()
        print(f'[auth] Marked Firestore verification complete for {normalized}')
    except urllib.error.URLError as exc:
        print(f'[auth] Firestore verify update skipped: {exc}')
