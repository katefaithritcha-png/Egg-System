"""HTTP defense helpers: headers, CORS allowlist, farm device + session gates."""

from __future__ import annotations

import hmac
import ipaddress
import os
import time
from collections import defaultdict, deque
from typing import Callable

from flask import Flask, Request, jsonify, request

_limiter_lock = __import__('threading').Lock()
_hits: dict[str, deque[float]] = defaultdict(deque)


def apply_security_headers(response):
    origin = request.headers.get('Origin', '')
    if origin.startswith('http://127.0.0.1') or origin.startswith('http://localhost'):
        response.headers['Access-Control-Allow-Origin'] = origin
        response.headers['Access-Control-Allow-Headers'] = (
            'Authorization, Content-Type, X-Farm-Device-Token, X-Device-Token'
        )
        response.headers['Access-Control-Allow-Methods'] = (
            'GET, POST, PUT, PATCH, DELETE, OPTIONS'
        )
        response.headers['Vary'] = 'Origin'
    response.headers.setdefault('X-Frame-Options', 'DENY')
    response.headers.setdefault('X-Content-Type-Options', 'nosniff')
    response.headers.setdefault('Referrer-Policy', 'no-referrer')
    response.headers.setdefault('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
    response.headers.setdefault(
        'Content-Security-Policy',
        "default-src 'self'; img-src 'self' blob: data:; "
        "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'self'",
    )
    # HSTS only meaningful behind HTTPS terminators
    if os.environ.get('AUTH_PUBLIC_BASE_URL', '').startswith('https://'):
        response.headers.setdefault(
            'Strict-Transport-Security', 'max-age=31536000; includeSubDomains'
        )
    return response


def cors_origins() -> list[str] | str:
    raw = os.environ.get('CORS_ALLOW_ORIGINS', '').strip()
    if not raw or raw == '*':
        # Cloudflare-only — UI Worker + farm tunnel. No localhost / LAN.
        return [
            'https://egg-system.paghasianjustine.workers.dev',
            'https://egg-farm.eggsorting.site',
        ]
    return [o.strip() for o in raw.split(',') if o.strip()]


def _client_ip() -> str:
    forwarded = request.headers.get('X-Forwarded-For', '').split(',')[0].strip()
    return forwarded or (request.remote_addr or 'unknown')


def _is_private_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip.split('%')[0])
        return bool(addr.is_private or addr.is_loopback)
    except ValueError:
        return False


def _rate_limited(key: str, limit: int, window_s: int) -> tuple[bool, int]:
    now = time.monotonic()
    with _limiter_lock:
        bucket = _hits[key]
        cutoff = now - window_s
        while bucket and bucket[0] < cutoff:
            bucket.popleft()
        if len(bucket) >= limit:
            retry = int(window_s - (now - bucket[0])) + 1
            return True, max(retry, 1)
        bucket.append(now)
        return False, 0


def farm_device_token() -> str:
    return os.environ.get('FARM_DEVICE_TOKEN', '').strip()


def device_token_ok(req: Request | None = None) -> bool:
    req = req or request
    expected = farm_device_token()
    got = (
        req.headers.get('X-Farm-Device-Token', '')
        or req.headers.get('X-Device-Token', '')
        or ''
    ).strip()
    if expected:
        return bool(got) and hmac.compare_digest(got, expected)
    # Dev fallback: LAN, or Cloudflare Tunnel/Worker when no token is set.
    ip = _client_ip()
    if _is_private_ip(ip):
        return True
    # Mirror FastAPI gate: CF headers mean the request came through the tunnel.
    return bool(
        (req.headers.get('Cf-Connecting-Ip') if req else None)
        or (req.headers.get('CF-Ray') if req else None)
        or (req.headers.get('cf-connecting-ip') if req else None)
        or (req.headers.get('cf-ray') if req else None)
    )


def allow_local_browser(app: Flask) -> None:
    """Run before Flask-CORS so this header is applied last for Flutter web."""

    @app.after_request
    def _local_origin(response):
        origin = request.headers.get('Origin', '')
        if origin.startswith('http://127.0.0.1') or origin.startswith('http://localhost'):
            response.headers['Access-Control-Allow-Origin'] = origin
            response.headers['Access-Control-Allow-Headers'] = (
                'Authorization, Content-Type, X-Farm-Device-Token, X-Device-Token'
            )
            response.headers['Access-Control-Allow-Methods'] = (
                'GET, POST, PUT, PATCH, DELETE, OPTIONS'
            )
            response.headers['Vary'] = 'Origin'
        return response


def register_http_security(app: Flask) -> None:
    @app.after_request
    def _sec_headers(response):
        return apply_security_headers(response)

    app.config['MAX_CONTENT_LENGTH'] = int(
        os.environ.get('MAX_CONTENT_LENGTH', str(2 * 1024 * 1024))
    )


def json_error(message: str, status: int, code: str, retry_after: int | None = None):
    response = jsonify({'error': message, 'code': code})
    if retry_after is not None:
        response.headers['Retry-After'] = str(retry_after)
    return response, status


def gate_farm_routes(
    *,
    session_user_fn: Callable[[], object | None],
) -> Callable:
    """Flask before_request: protect inspection/control surfaces."""

    public_exact = {
        '/',
        '/health',
        '/auth/health',
        '/auth/reset-form',
        '/live.jpg',
        '/live.jpgg',
        '/live',
        '/camera',
        '/stream',
        '/watch',
        '/live-status',
    }
    public_prefix = (
        '/auth/signup',
        '/auth/login',
        '/auth/verify-login',
        '/auth/firebase-login',
        '/auth/verify-email',
        '/auth/resend-verification',
        '/auth/forgot-password',
        '/auth/reset-password',
    )
    # ESP32 / scale — device token (or private IP if token unset)
    device_paths = {
        '/weight',
        '/frame',
        '/api/frame',
        '/api/status',
        '/status',
        '/api/inspect',  # station: IR stop → ask AI → servo reject
        '/api/servo-test',  # queue one servo push via heartbeat
    }
    # Staff session required
    session_paths = {
        '/metrics',
        '/records',
        '/debug',
        '/reset',
        '/stream',
        '/farm/snapshot',
        '/api/egg-records',
        '/api/egg-sync',
    }

    def _before():
        path = request.path or '/'
        if request.method == 'OPTIONS':
            return None
        if path in public_exact or any(path.startswith(p) for p in public_prefix):
            return None
        if path.startswith('/auth/'):
            return None

        # Camera JPEGs must not share the dashboard rate bucket.
        if path not in ('/frame', '/api/frame', '/api/inspect', '/weight'):
            limited, retry = _rate_limited(
                f'farm:ip:{_client_ip()}',
                int(os.environ.get('FARM_IP_RATE_LIMIT', '400')),
                int(os.environ.get('FARM_IP_RATE_WINDOW', '60')),
            )
        else:
            limited, retry = False, 0
        if limited:
            return json_error(
                'Too many requests. Try again later.',
                429,
                'rate_limited',
                retry,
            )

        if path in device_paths:
            if request.method == 'GET' and path in ('/status', '/api/status'):
                # Read-only status: session OR device
                if session_user_fn() is not None or device_token_ok():
                    return None
                return json_error('Authentication required', 401, 'unauthorized')
            if path == '/api/inspect':
                if session_user_fn() is not None or device_token_ok():
                    return None
                return json_error(
                    'Device or session auth required for inspect',
                    401,
                    'unauthorized',
                )
            if not device_token_ok():
                return json_error(
                    'Device token required (X-Farm-Device-Token)',
                    401,
                    'device_unauthorized',
                )
            return None

        if path in session_paths or path.startswith('/farm/'):
            user = session_user_fn()
            if user is None:
                return json_error('Authentication required', 401, 'unauthorized')
            if path in ('/reset', '/debug'):
                role = None
                if user is not None:
                    try:
                        role = user['role']
                    except Exception:  # noqa: BLE001
                        role = getattr(user, 'role', None)
                if role != 'admin':
                    return json_error('Admin role required', 403, 'forbidden')
            return None

        # Deny unknown API surfaces by default (except static-ish)
        if path.startswith('/api/') or path.startswith('/auth/'):
            return json_error('Not found', 404, 'not_found')
        return None

    return _before
