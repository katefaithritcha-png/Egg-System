"""One-shot: sync sole admin password in farm_users (+ Firebase Auth if possible)."""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from dotenv import load_dotenv

load_dotenv(ROOT / '.env')

import farm_store  # noqa: E402
from auth import _hash_password, _iso, _password_ok, _utcnow  # noqa: E402
from firebase_store import ensure_firebase_email_user, firebase_password_ok  # noqa: E402


def main() -> int:
    email = (os.environ.get('AUTH_ADMIN_EMAIL') or 'katefaithr@gmail.com').strip().lower()
    password = os.environ.get('AUTH_ADMIN_PASSWORD') or 'Admin123@'
    print(f'email={email}')
    row = farm_store.get_user_by_email(email)
    print(f'farm_user={"FOUND" if row else "MISSING"}')
    if row:
        print(
            'verified=',
            row.get('email_verified'),
            'disabled=',
            row.get('disabled'),
            'role=',
            row.get('role'),
        )
        print(
            'hash_ok_before=',
            _password_ok(password, str(row.get('password_hash') or '')),
        )
    print('firebase_ok_before=', firebase_password_ok(email, password))

    now = _iso(_utcnow())
    if row is None:
        row = {
            'id': farm_store.stable_user_id(email),
            'email': email,
            'name': 'Farm Admin',
            'role': 'admin',
            'email_verified': True,
            'assigned_zone': 'Farm',
            'created_at': now,
            'disabled': False,
        }
    row['password_hash'] = _hash_password(password)
    row['pending_password_hash'] = ''
    row['email_verified'] = True
    row['disabled'] = False
    row['role'] = 'admin'
    row['password_changed_at'] = now
    farm_store.save_user(row)
    refreshed = farm_store.get_user_by_email(email) or {}
    print(
        'hash_ok_after=',
        _password_ok(password, str(refreshed.get('password_hash') or '')),
    )

    token = ensure_firebase_email_user(email, password)
    print('firebase_ensure=', bool(token))
    print('firebase_ok_after=', firebase_password_ok(email, password))
    print('done')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
