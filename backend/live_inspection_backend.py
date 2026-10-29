from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hmac
import ipaddress
import json
import os
import random
import sys
import threading
import time

from dotenv import load_dotenv

# Load backend/.env before auth/Firebase imports. Ignore a leaked AUTH_TESTING=1
# from a parent test shell unless .env intentionally enables it.
_BACKEND_DIR_BOOT = Path(__file__).resolve().parent
_ENV_PATH = _BACKEND_DIR_BOOT / '.env'
_testing_in_dotenv = False
if _ENV_PATH.is_file():
    for _line in _ENV_PATH.read_text(encoding='utf-8').splitlines():
        _stripped = _line.strip()
        if _stripped and not _stripped.startswith('#') and _stripped.startswith('AUTH_TESTING='):
            _testing_in_dotenv = _stripped.split('=', 1)[1].strip().strip('"\'') == '1'
            break
load_dotenv(_ENV_PATH)
if not _testing_in_dotenv:
    os.environ.pop('AUTH_TESTING', None)

import cv2
import numpy as np
import requests
from a2wsgi import WSGIMiddleware
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from flask import Flask
from requests.adapters import HTTPAdapter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from auth import (
    get_shared_farm_snapshot,
    get_user_from_authorization,
    init_auth,
    put_shared_farm_snapshot,
)
from egg_sync import (
    attach_weight_to_egg,
    delete_eggs_for_utc_day,
    get_store,
    ingest_body,
    remember_sorted_egg,
    sorting_result_for,
)
import uuid
from roboflow_egg import infer_bgr_frame
from security_http import cors_origins, farm_device_token

# ESP32-CAM serves still JPEGs on port 82 (/jpg). Port 81 is mjpeg/HTML only.
ESP32_STREAM_URL = os.environ.get('ESP32_STREAM_URL', 'http://192.168.11.237:82/jpg')
# Hybrid models: YOLO TFLite = crack/dirty only; SavedModel = Empty + Clean stay.
_BACKEND_DIR = Path(__file__).resolve().parent
_PROJECT_ROOT = _BACKEND_DIR.parent
CRACK_TFLITE = _PROJECT_ROOT / 'models' / 'crackegg.tflite'
DIRTY_TFLITE = _PROJECT_ROOT / 'models' / 'dirty.tflite'
SAVEDMODEL_DIR = _PROJECT_ROOT / 'models' / 'savedmodel'
LABELS_PATH = _PROJECT_ROOT / 'models' / 'labels.txt'
# Kept for older call sites that still print MODEL_DIR.
MODEL_DIR = SAVEDMODEL_DIR

CONFIDENCE_THRESHOLD = 55.0
CRACK_SCORE_MIN = float(os.environ.get('CRACK_SCORE_MIN', '45.0'))
DIRTY_SCORE_MIN = float(os.environ.get('DIRTY_SCORE_MIN', '45.0'))
REJECT_MARGIN = 8.0
YOLO_IMG_SIZE = 640
YOLO_CONF_MIN = float(os.environ.get('YOLO_CONF_MIN', '0.35'))
INSPECT_WINDOW_SEC = 2.5
# Short camera watch, then commit Clean/Crack. Early-exit when votes are clear
# so a moving egg is not stuck on DETECTING while it leaves the FOV.
# Weight stays pending until the same egg (Clean/Crack/Dirty) hits the HX711.
# Full camera watch before Clean / Crack / Dirty is locked.
SCAN_SEC = float(os.environ.get('SCAN_SEC', '5.0'))
# Do not early-exit before SCAN_SEC unless explicitly configured lower.
SCAN_EARLY_SEC = float(os.environ.get('SCAN_EARLY_SEC', '5.0'))
INSPECT_GIVE_UP_SEC = 6.0
ROBOFLOW_TIMEOUT_SEC = 1.0
# 0 = off for live speed. Roboflow was stacking with /jpg pulls and lagging the CAM.
ROBOFLOW_EVERY_N = int(os.environ.get('ROBOFLOW_EVERY_N', '0'))
GRAB_SLEEP_SEC = 0.01
# Vision ticks must stay near-zero sleep — any pause here delays tracker vs live.
CLASSIFY_SLEEP_SEC = float(os.environ.get('CLASSIFY_SLEEP_SEC', '0.02'))
CLASSIFY_HEAVY_SLEEP_SEC = float(os.environ.get('CLASSIFY_HEAVY_SLEEP_SEC', '0.40'))
# Crack/Dirty YOLO TFLite — needed so dirty/crack eggs are not labeled Clean.
# Set CLASSIFY_TF=0 only for live-debug (vision/track only).
CLASSIFY_TF = os.environ.get('CLASSIFY_TF', '1').strip().lower() not in (
    '0', 'false', 'no',
)
# Clear sticky Clean→scale wait so the next egg can detect (was 120s).
AWAIT_WEIGHT_TIMEOUT_SEC = float(os.environ.get('AWAIT_WEIGHT_TIMEOUT_SEC', '8'))

# How many recent detection records to keep for the /records endpoint.
MAX_RECORDS = 200

app = FastAPI(title='Egg System', docs_url='/docs', redoc_url=None)
_auth_flask = Flask('egg-auth')
init_auth(_auth_flask)


class _PrependAuthPath:
    """Starlette strips /auth on mount; Flask routes still expect /auth/..."""

    def __init__(self, wsgi_app):
        self.wsgi_app = wsgi_app

    def __call__(self, environ, start_response):
        path = environ.get('PATH_INFO') or ''
        if not path.startswith('/auth'):
            environ['PATH_INFO'] = '/auth' + (path if path.startswith('/') else '/' + path)
        return self.wsgi_app(environ, start_response)


_cors = cors_origins()
_cors_list = [o for o in _cors if not o.startswith('r\'') and '*' not in o] if isinstance(_cors, list) else ['*']
# Regex origins from security_http are for flask-cors; FastAPI wants plain strings.
_cors_list = [
    'https://egg-system.paghasianjustine.workers.dev',
    'https://egg-farm.eggsorting.site',
]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_list,
    # LAN farm IP + Cloudflare tunnels + workers.dev hosted Flutter web.
    allow_origin_regex=(
        r'https?://(192\.168\.\d+\.\d+)(:\d+)?'
        r'|https://([a-z0-9-]+\.)*(trycloudflare\.com|cloudflare\.com|workers\.dev|eggsorting\.site|eggsorting\.com)'
    ),
    allow_credentials=False,
    allow_methods=['*'],
    allow_headers=[
        'Authorization',
        'Content-Type',
        'X-Farm-Device-Token',
        'X-Device-Token',
        'Cache-Control',
        'Pragma',
    ],
    expose_headers=[
        'X-Egg-Frame',
        'X-Frame-Age-Ms',
    ],
)


def _client_ip(request: Request) -> str:
    forwarded = (request.headers.get('x-forwarded-for') or '').split(',')[0].strip()
    if forwarded:
        return forwarded
    if request.client:
        return request.client.host or 'unknown'
    return 'unknown'


def _is_private_ip(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip.split('%')[0])
        return bool(addr.is_private or addr.is_loopback)
    except ValueError:
        return False


def _from_cloudflare(request: Request) -> bool:
    """True when the request was proxied by Cloudflare (Worker / Tunnel)."""
    return bool(
        request.headers.get('cf-connecting-ip')
        or request.headers.get('cf-ray')
        or request.headers.get('cf-visitor')
    )


def _device_token_ok(request: Request) -> bool:
    expected = farm_device_token()
    got = (
        request.headers.get('x-farm-device-token')
        or request.headers.get('x-device-token')
        or ''
    ).strip()
    if expected:
        return bool(got) and hmac.compare_digest(got, expected)
    # No token configured: allow LAN, or Cloudflare Tunnel (extender isolation path).
    return _is_private_ip(_client_ip(request)) or _from_cloudflare(request)


@app.middleware('http')
async def farm_gate(request: Request, call_next):
    path = request.url.path or '/'
    if request.method == 'OPTIONS' or path.startswith('/auth') or path in {
        '/', '/health', '/live.jpg', '/live.jpgg', '/live', '/camera', '/stream',
        '/watch', '/live-status', '/docs', '/openapi.json',
    }:
        return await call_next(request)

    device_paths = {
        '/weight', '/frame', '/api/frame', '/api/status', '/status',
        '/api/inspect', '/api/servo-test', '/api/station-selftest',
    }
    session_paths = {
        '/metrics', '/records', '/records/restore', '/debug', '/reset',
        '/api/egg-records', '/api/egg-sync',
    }
    user = get_user_from_authorization(request.headers.get('authorization'))

    if path in device_paths:
        if request.method == 'GET' and path in ('/status', '/api/status'):
            if user is not None or _device_token_ok(request):
                return await call_next(request)
            return JSONResponse({'error': 'Authentication required', 'code': 'unauthorized'}, status_code=401)
        if path == '/api/inspect':
            if user is not None or _device_token_ok(request):
                return await call_next(request)
            return JSONResponse(
                {'error': 'Device or session auth required for inspect', 'code': 'unauthorized'},
                status_code=401,
            )
        if not _device_token_ok(request):
            return JSONResponse(
                {'error': 'Device token required (X-Farm-Device-Token)', 'code': 'device_unauthorized'},
                status_code=401,
            )
        return await call_next(request)

    if path in session_paths or path.startswith('/farm/'):
        # Live board must stay readable through Worker → Tunnel even when
        # X-Forwarded-For is a public IP and CF headers were rewritten.
        if user is None:
            if path in ('/metrics', '/records', '/api/egg-sync') and request.method == 'GET':
                return await call_next(request)
            # Browser hard-refresh rehydrate: push cached Live Egg Records back to farm.
            if path == '/records/restore' and request.method == 'POST':
                return await call_next(request)
            return JSONResponse({'error': 'Authentication required', 'code': 'unauthorized'}, status_code=401)
        if path in ('/reset', '/debug'):
            role = None
            try:
                role = user['role']
            except Exception:
                role = getattr(user, 'role', None)
            if role != 'admin':
                return JSONResponse({'error': 'Admin role required', 'code': 'forbidden'}, status_code=403)
        return await call_next(request)

    return await call_next(request)

metrics = {
    'goodEggs': 0,
    'crackedEggs': 0,
    'dirtyEggs': 0,
    'status': 'Running — waiting for ESP32-CAM',
    'lastLabel': 'N/A',
    'lastConfidence': 0.0,
    'lastWeightGrams': 0.0,
    'lastSizeClass': 'N/A',
    'lastMeasurementStatus': 'uncalibrated',
    'connected': False,
}

# Chronological log of every confirmed detection (egg present, above threshold).
# Each entry: { timestamp, label, confidence, category, weightGrams, sizeClass }
detection_records: deque = deque(maxlen=MAX_RECORDS)
_RECORDS_LOCK = threading.Lock()
_RECORDS_PATH = _BACKEND_DIR / 'data' / 'live_detections.json'


_force_empty_records_save = False  # True only during POST /reset


def _save_live_detections() -> None:
    """Persist Live Inspection rows to Firebase (source of truth)."""
    global _force_empty_records_save
    with _RECORDS_LOCK:
        try:
            import farm_store
            # Never clobber a non-empty Firebase board with an empty in-memory board
            # (restart race / bg save). Only Reset may write empty on purpose.
            if not detection_records and not _force_empty_records_save:
                try:
                    remote = farm_store.load_live_board()
                    if remote and remote.get('records'):
                        print(
                            '[records] skip empty save — Firebase still has '
                            f'{len(remote.get("records") or [])} row(s)',
                            flush=True,
                        )
                        return
                except Exception:
                    pass
            payload = {
                'goodEggs': int(metrics.get('goodEggs') or 0),
                'crackedEggs': int(metrics.get('crackedEggs') or 0),
                'dirtyEggs': int(metrics.get('dirtyEggs') or 0),
                'records': list(detection_records),
                'savedAt': time.strftime('%Y-%m-%dT%H:%M:%S'),
            }
            farm_store.save_live_board(payload)
        except Exception as exc:
            print(f'[records] Firebase save failed: {exc}', flush=True)
        finally:
            _force_empty_records_save = False


def _save_live_detections_bg() -> None:
    """Firebase save off the classify path so /records updates feel instant after the 5s scan."""
    threading.Thread(target=_save_live_detections, daemon=True, name='save-live').start()


def _apply_live_board_payload(data: dict) -> None:
    rows = data.get('records') or []
    detection_records.clear()
    for row in rows:
        if isinstance(row, dict) and row.get('id'):
            detection_records.append(row)
    metrics['goodEggs'] = int(data.get('goodEggs') or 0)
    metrics['crackedEggs'] = int(data.get('crackedEggs') or 0)
    metrics['dirtyEggs'] = int(data.get('dirtyEggs') or 0)
    good_n = 0
    crack_n = 0
    dirty_n = 0
    for row in detection_records:
        cat = str(row.get('category') or '').lower()
        lab = str(row.get('label') or '').lower()
        if cat == 'crackedeggs' or ('crack' in lab and 'no crack' not in lab):
            crack_n += 1
        elif cat == 'dirtyeggs' or 'dirty' in lab or 'soil' in lab or 'stain' in lab:
            dirty_n += 1
        else:
            good_n += 1
    if good_n > int(metrics.get('goodEggs') or 0):
        metrics['goodEggs'] = good_n
    if crack_n > int(metrics.get('crackedEggs') or 0):
        metrics['crackedEggs'] = crack_n
    if dirty_n > int(metrics.get('dirtyEggs') or 0):
        metrics['dirtyEggs'] = dirty_n
    if detection_records:
        last = detection_records[-1]
        lab = str(last.get('label') or '')
        if lab:
            metrics['lastLabel'] = (
                lab if 'egg' in lab.lower() else f'{lab} Egg'
            )
        try:
            metrics['lastConfidence'] = float(last.get('confidence') or 0)
        except (TypeError, ValueError):
            pass
        if last.get('awaitingWeight'):
            metrics['status'] = f'{lab or "Clean"} recorded — waiting for weight'
            metrics['lastSizeClass'] = 'pending'
            metrics['lastWeightGrams'] = 0.0
        elif isinstance(last.get('weightGrams'), (int, float)):
            metrics['lastWeightGrams'] = float(last['weightGrams'])
            metrics['lastSizeClass'] = str(last.get('sizeClass') or 'N/A')
            metrics['status'] = 'Running'


def _load_live_detections() -> None:
    """Restore today's live board from Firebase after process restart."""
    try:
        import farm_store
        data = farm_store.load_live_board()
        if not data:
            # One-time migrate from legacy local JSON if present.
            if _RECORDS_PATH.exists():
                legacy = json.loads(_RECORDS_PATH.read_text(encoding='utf-8'))
                if legacy.get('records'):
                    _apply_live_board_payload(legacy)
                    farm_store.save_live_board({
                        'goodEggs': int(metrics.get('goodEggs') or 0),
                        'crackedEggs': int(metrics.get('crackedEggs') or 0),
                        'dirtyEggs': int(metrics.get('dirtyEggs') or 0),
                        'records': list(detection_records),
                        'savedAt': time.strftime('%Y-%m-%dT%H:%M:%S'),
                    })
                    print(
                        f'[records] migrated {len(detection_records)} '
                        'detection(s) from disk → Firebase',
                        flush=True,
                    )
                    try:
                        _RECORDS_PATH.unlink(missing_ok=True)
                    except Exception:
                        pass
            return
        _apply_live_board_payload(data)
        print(
            f'[records] restored {len(detection_records)} detection(s) from Firebase',
            flush=True,
        )
    except Exception as exc:
        print(f'[records] Firebase load failed: {exc}', flush=True)


_load_live_detections()
# Ensure Firebase board doc exists even when empty (refresh-safe).
if not detection_records:
    try:
        import farm_store
        if farm_store.load_live_board() is None:
            _save_live_detections()
    except Exception:
        pass

labels = []
signature = None
input_name = None
input_shape = (224, 224, 3)
_thread_started = False
_thread_lock = threading.Lock()

debug_info = {
    'rawScores': [],
    'topClasses': [],
    'lastFrameTimestamp': '',
    'frameCount': 0,
}

# ── Weight state ───────────────────────────────────────────────────────────
# Holds the most recent weight pushed by a physical scale via POST /weight.
# If no scale is connected the stream_worker simulates a plausible value.
_weight_lock = threading.Lock()
_pending_weight: float | None = None   # set by POST /weight, consumed once
_last_live_weight_at = 0.0  # monotonic time of last non-empty scale reading
_LIVE_WEIGHT_HOLD_SEC = 0.4  # drop stale grams fast so empty belt is not an egg

# One camera egg → one system record. Clean/Crack/Dirty all wait for the same egg on the scale.
_egg_pipe_lock = threading.Lock()
_egg_pipe = {
    'id': '',
    'camera': '',          # Clean | Crack | Dirty
    'category': '',        # goodEggs | crackedEggs | dirtyEggs
    'awaiting_weight': False,
    'weighed': False,
    'opened_at': 0.0,
}

_heartbeat_lock = threading.Lock()
_esp32_last_seen = 0.0
_clean_hold_until = 0.0
_reject_hold_until = 0.0

# ESP32 stops the belt at the IR, then asks for one decision on this egg.
_inspect_lock = threading.RLock()
_inspect = {
    'waiting': False,
    'ready': False,
    'reject': False,
    'label': '',
    'asked_at': 0.0,
    'best_good': 0.0,
    'best_crack': 0.0,
    'best_dirty': 0.0,
}
_esp32_device = 'ESP32-CAM'
_stream_url_lock = threading.Lock()
_stream_url_epoch = 0
HEARTBEAT_TTL_SECONDS = 30.0  # tolerate brief Wi‑Fi blips — CAM keep-alive recovers
_pending_servo_test = False
_pending_servo_lock = threading.Lock()
_jpeg_lock = threading.Lock()
_last_jpeg = b''
_last_jpeg_at = 0.0
_raw_lock = threading.Lock()
_last_raw = b''
_last_raw_at = 0.0
_raw_seq = 0
_preview = b''
_preview_at = 0.0
_src_wh = (640, 480)
# Instant /watch cache: always the newest JPEG (raw or lightly painted). Never queues.
_view_lock = threading.Lock()
_view_jpeg = b''
_view_seq = 0
_ann_at = 0.0
_ann_jpeg = b''
_classify_n = 0
_live_lock = threading.Lock()
_live = {'label': '', 'good': 0.0, 'crack': 0.0, 'dirty': 0.0}
_rf_pool = ThreadPoolExecutor(max_workers=1)
_rf_tick = 0
_rf_busy = False
_rf_busy_lock = threading.Lock()
_rf_last = None
_rf_last_lock = threading.Lock()


def _hardware_online() -> bool:
    with _heartbeat_lock:
        if _esp32_last_seen <= 0:
            return False
        return (time.monotonic() - _esp32_last_seen) < HEARTBEAT_TTL_SECONDS


def _quick_jpg_alive(jpg_url: str) -> bool:
    """True only if the URL returns a real JPEG (rejects DevKit 'nojpeg' stubs)."""
    try:
        r = _jpg_session.get(
            jpg_url, timeout=(0.35, 0.8), headers={'Connection': 'close'},
        )
        ok = (
            r.status_code == 200
            and len(r.content) >= 500
            and r.content[:2] == b'\xff\xd8'
        )
        r.close()
        return ok
    except Exception:
        return False


def _adopt_cam_jpg(jpg: str, reason: str = '') -> bool:
    """Switch the puller to jpg only when it actually serves frames."""
    global ESP32_STREAM_URL, _stream_url_epoch, _cam_pick, _direct_jpg
    jpg = _jpg_url((jpg or '').strip())
    if not jpg.startswith('http') or ':8000' in jpg or '127.0.0.1' in jpg:
        return False
    with _stream_url_lock:
        cur = _direct_jpg or ESP32_STREAM_URL
    if cur == jpg:
        return True
    # Trust CAM heartbeats for URL changes — probing :82 here fought the puller
    # and left /watch stuck on "waiting for JPEG".
    with _stream_url_lock:
        ESP32_STREAM_URL = jpg
        _direct_jpg = jpg
        _stream_url_epoch += 1
        _cam_pick = 0
    print(f'[heartbeat] camera JPEG set to {jpg}{(" (" + reason + ")") if reason else ""}', flush=True)
    return True


_cam_hb_jpg = -1  # last JPEG byte count reported by CAM heartbeat (-1 = unknown)
_cam_hb_jpg_lock = threading.Lock()
_hb_pull_lock = threading.Lock()
_hb_pull_busy = False


def _note_heartbeat(device: str, stream_url: str = '') -> None:
    global _esp32_last_seen, _esp32_device
    name = (device or 'ESP32-CAM').strip() or 'ESP32-CAM'
    with _heartbeat_lock:
        _esp32_last_seen = time.monotonic()
        # Prefer remembering the real station name; don't let a mis-flashed
        # DevKit (reporting as ESP32-CAM) erase DevKit presence forever.
        if 'devkit' in name.lower() or 'cam' in name.lower():
            _esp32_device = name
    # Camera URL adoption happens in /api/status after a live JPEG probe.
    print(f'[heartbeat] {name} ONLINE', flush=True)


def _pull_once_from_url(jpg_url: str) -> bool:
    """One short :82 pull — backup when CAM push is stalled on this Wi‑Fi."""
    jpg_url = _jpg_url((jpg_url or '').strip())
    if not jpg_url.startswith('http'):
        return False
    try:
        r = _jpg_session.get(
            jpg_url, timeout=(0.4, 1.0), headers={'Connection': 'close'},
        )
        body = r.content or b''
        r.close()
        if r.status_code == 200 and len(body) >= 200 and body[:2] == b'\xff\xd8':
            _store_live_jpeg(body)
            print(f'[live] HB-pull JPEG {len(body)}B from {jpg_url}', flush=True)
            return True
    except Exception as exc:
        print(f'[live] HB-pull miss: {exc}', flush=True)
    return False


def _maybe_pull_on_heartbeat(jpg_url: str, cam_jpg: int) -> None:
    """If CAM says it has a picture but laptop has none, try pull immediately."""
    global _hb_pull_busy
    with _raw_lock:
        raw_age = (time.monotonic() - _last_raw_at) if _last_raw_at else 999.0
    # Known zero encode → don't waste pulls. Unknown (-1, old flash) still try.
    if 0 <= cam_jpg < 200:
        return
    if raw_age < 1.2:
        return
    if not jpg_url:
        with _stream_url_lock:
            jpg_url = _direct_jpg or ESP32_STREAM_URL
    if not jpg_url:
        return
    with _hb_pull_lock:
        if _hb_pull_busy:
            return
        _hb_pull_busy = True

    def _run() -> None:
        global _hb_pull_busy
        try:
            _pull_once_from_url(jpg_url)
        finally:
            with _hb_pull_lock:
                _hb_pull_busy = False

    threading.Thread(target=_run, name='hb-pull', daemon=True).start()


def _latest_pending_detection() -> dict | None:
    """Newest camera record still waiting for scale grams."""
    for rec in reversed(list(detection_records)):
        if rec.get('awaitingWeight'):
            return rec
    return None


def _label_from_camera(cam: str) -> str:
    low = (cam or '').lower()
    if 'crack' in low and 'no crack' not in low:
        return 'Crack Egg'
    if 'dirty' in low or 'soil' in low or 'stain' in low:
        return 'Dirty Egg'
    if 'clean' in low or 'good' in low or 'no crack' in low:
        return 'Clean Egg'
    if cam and 'egg' in low:
        return cam
    return f'{cam} Egg' if cam else 'Clean Egg'


def _restore_pipe_from_pending() -> None:
    """Keep scale pipe aligned with camera records (pending vs weighed)."""
    with _egg_pipe_lock:
        rid = str(_egg_pipe.get('id') or '')
        awaiting = bool(_egg_pipe.get('awaiting_weight'))
    if rid and awaiting:
        for rec in detection_records:
            if str(rec.get('id') or '') != rid:
                continue
            # Weight already attached — clear sticky awaiting so UI leaves pending.
            if not rec.get('awaitingWeight'):
                with _egg_pipe_lock:
                    if str(_egg_pipe.get('id') or '') == rid:
                        _egg_pipe['awaiting_weight'] = False
                        _egg_pipe['weighed'] = True
                return
            return
    rec = _latest_pending_detection()
    if not rec:
        return
    new_id = str(rec.get('id') or '')
    if not new_id:
        return
    with _egg_pipe_lock:
        if _egg_pipe.get('awaiting_weight') and _egg_pipe.get('id'):
            return
        cam = str(rec.get('label') or 'Clean')
        cat = str(rec.get('category') or 'goodEggs')
        _egg_pipe['id'] = new_id
        _egg_pipe['camera'] = cam if cam in ('Clean', 'Crack', 'Dirty') else (
            'Dirty' if 'dirty' in cam.lower() else (
                'Crack' if 'crack' in cam.lower() else 'Clean'
            )
        )
        _egg_pipe['category'] = cat
        _egg_pipe['awaiting_weight'] = True
        _egg_pipe['weighed'] = False
        _egg_pipe['opened_at'] = time.monotonic()


def _public_metrics() -> dict:
    hardware = _hardware_online()
    # Re-arm weigh pipe from orphan pending camera rows (timeout / FOV clear).
    _restore_pipe_from_pending()
    payload = dict(metrics)
    with _raw_lock:
        raw_at = _last_raw_at
        has_raw = bool(_last_raw)
    frame_age = (time.monotonic() - raw_at) if raw_at else 999.0
    frame_live = bool(has_raw and frame_age <= LIVE_VIEW_MAX_AGE_SEC)
    payload['hardwareOnline'] = hardware
    payload['hardwareDevice'] = _esp32_device
    # connected / LIVE = fresh JPEG only — never heartbeat-only (that made the
    # UI show green LIVE over "Connecting camera…").
    payload['connected'] = frame_live
    payload['cameraConnected'] = frame_live
    payload['frameLive'] = frame_live
    payload['frameAgeMs'] = int(round(min(frame_age, 99.0) * 1000))
    metrics['connected'] = frame_live
    if hardware and not frame_live:
        payload['status'] = (
            f'{_esp32_device} on Wi-Fi — waiting for internet camera frames'
        )
    elif not hardware and not frame_live:
        payload['status'] = 'Running — waiting for ESP32-CAM'
    with _egg_pipe_lock:
        awaiting = bool(_egg_pipe.get('awaiting_weight'))
        pipe_cam = str(_egg_pipe.get('camera') or '')
        pending_id = str(_egg_pipe.get('id') or '')
    pending_rec = None if awaiting else _latest_pending_detection()
    if pending_rec is not None:
        awaiting = True
        pipe_cam = str(pending_rec.get('label') or pipe_cam or 'Clean')
        pending_id = str(pending_rec.get('id') or pending_id)
    payload['awaitingWeight'] = awaiting
    payload['pendingEggId'] = pending_id
    payload['pipeCamera'] = pipe_cam
    # Keep Clean/Crack visible in Live Inspection while waiting for scale grams.
    if awaiting and pipe_cam:
        lab = str(payload.get('lastLabel') or '')
        low = lab.lower()
        if not lab or lab in ('N/A', 'Empty Model') or low in ('scanning', 'egg', 'detecting'):
            payload['lastLabel'] = _label_from_camera(pipe_cam)
        if float(payload.get('lastConfidence') or 0) < 1.0:
            conf = 80.0
            if pending_rec is not None:
                try:
                    conf = float(pending_rec.get('confidence') or 80.0)
                except (TypeError, ValueError):
                    conf = 80.0
            payload['lastConfidence'] = conf
        payload['status'] = f'{pipe_cam} recorded — waiting for weight'
        if str(payload.get('lastSizeClass') or 'N/A') in ('N/A', '', 'pending'):
            payload['lastSizeClass'] = 'pending'
        if float(payload.get('lastWeightGrams') or 0) < 5.0:
            payload['lastWeightGrams'] = 0.0
    # Embed board rows in /metrics so the UI updates instantly on one poll
    # (no second /records round-trip that can lag or get cached).
    rows = list(detection_records)
    payload['recordsCount'] = len(rows)
    payload['recentRecords'] = list(reversed(rows))[:80]
    if rows:
        payload['latestRecordId'] = str(rows[-1].get('id') or '')
    else:
        payload['latestRecordId'] = ''
    return payload


def correct_scale_grams(grams: float) -> float:
    """Soft correction for a mis-factored HX711. Keep inaccurate-but-usable grams.

    Legacy factor-400 firmware reported ~128 g for a medium egg. Corrected
    firmware stays under ~90 g and is left alone. Very high junk (>400 g) is
    scaled once; mid-range inaccurate values still pass through for SORT.
    """
    if grams > 400.0:
        grams = grams * (400.0 / 1010.0)
    elif grams > 120.0:
        # Mild shrink so SORT still gets a lane without inventing precision.
        grams = grams * 0.55
    return round(max(0.0, grams), 1)


def classify_size(grams: float) -> str:
    """
    Map a weight in grams to a size-class string matching the Flutter enum.
        small   <= 47.0 g
        medium  <= 54.0 g
        large   <= 61.3 g
        jumbo   > 61.3 g
    """
    if grams <= 47.0:
        return 'small'
    if grams <= 54.0:
        return 'medium'
    if grams <= 61.3:
        return 'large'
    return 'jumbo'


def _simulate_weight() -> float:
    """
    Produce a realistic random egg weight when no physical scale is connected.
    Weights are sampled from a normal distribution centred on 54 g (Large)
    with a std-dev of 10 g, clamped to the plausible 30–85 g range.
    """
    return round(max(30.0, min(85.0, random.gauss(54.0, 10.0))), 1)


def _consume_pending_weight() -> float | None:
    """Take pending scale grams only when actually counting an egg."""
    global _pending_weight
    with _weight_lock:
        if _pending_weight is None:
            return None
        w = _pending_weight
        _pending_weight = None
        return w


def _peek_pending_weight() -> float | None:
    with _weight_lock:
        return _pending_weight


def _egg_on_scale(max_age: float = 1.2) -> bool:
    """True only when the load cell just reported a real egg. Camera alone is not enough."""
    try:
        grams = float(metrics.get('lastWeightGrams') or 0)
    except (TypeError, ValueError):
        grams = 0.0
    if grams < 15.0:
        return False
    if _last_live_weight_at <= 0:
        return False
    return (time.monotonic() - _last_live_weight_at) <= max_age


def load_labels(path: Path):
    if not path.exists():
        raise FileNotFoundError(f'Labels file not found: {path}')
    with path.open('r', encoding='utf-8') as f:
        # Strip leading index numbers if present, e.g. "0 Empty Model" → "Empty Model"
        result = []
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                result.append(parts[1])
            else:
                result.append(line)
        return result


# TFLite YOLO = crack/dirty only. SavedModel = Empty + No Crack (Clean) stay.
_crack_it = None
_dirty_it = None
_crack_in = None
_crack_out = None
_dirty_in = None
_dirty_out = None
_tflite_lock = threading.Lock()
signature = None
input_name = 'images'
input_shape = (224, 224, 3)  # Teachable Machine Empty/Clean


def _make_tflite(path: Path):
    import tensorflow as tf  # lazy
    if not path.is_file():
        raise FileNotFoundError(f'TFLite model missing: {path}')
    it = tf.lite.Interpreter(model_path=str(path), num_threads=2)
    it.allocate_tensors()
    return it, it.get_input_details()[0], it.get_output_details()[0]


def load_model():
    """Load new crack/dirty YOLO TFLite + keep Empty/Clean Teachable Machine SavedModel."""
    global _crack_it, _dirty_it, _crack_in, _crack_out, _dirty_in, _dirty_out
    global signature, input_name, input_shape
    import tensorflow as tf  # lazy

    _crack_it, _crack_in, _crack_out = _make_tflite(CRACK_TFLITE)
    _dirty_it, _dirty_in, _dirty_out = _make_tflite(DIRTY_TFLITE)
    print(
        f'[model] crack/dirty TFLite ready '
        f'({CRACK_TFLITE.name}, {DIRTY_TFLITE.name})',
        flush=True,
    )

    if not SAVEDMODEL_DIR.is_dir():
        raise FileNotFoundError(
            f'Empty/Clean SavedModel missing: {SAVEDMODEL_DIR}'
        )
    model = tf.saved_model.load(str(SAVEDMODEL_DIR))
    signatures = getattr(model, 'signatures', None)
    if signatures is None or 'serving_default' not in signatures:
        raise RuntimeError('SavedModel missing serving_default signature')
    signature = signatures['serving_default']
    input_signature = signature.structured_input_signature[1]
    if not input_signature:
        raise RuntimeError('SavedModel serving_default has no inputs')
    input_name, input_spec = next(iter(input_signature.items()))
    input_shape = tuple(input_spec.shape[1:])
    if len(input_shape) != 3:
        raise RuntimeError(f'Unsupported SavedModel input shape: {input_shape}')
    print(
        f'[model] Empty/Clean SavedModel ready shape={input_shape}',
        flush=True,
    )


def _letterbox_bgr(frame, size: int = YOLO_IMG_SIZE):
    h, w = frame.shape[:2]
    r = min(size / float(h), size / float(w))
    nh, nw = max(1, int(round(h * r))), max(1, int(round(w * r)))
    resized = cv2.resize(frame, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((size, size, 3), 114, dtype=np.uint8)
    top = (size - nh) // 2
    left = (size - nw) // 2
    canvas[top:top + nh, left:left + nw] = resized
    return canvas, r, left, top


def _yolo_nchw(frame_bgr, focus=None):
    source = frame_bgr
    if focus is not None and frame_bgr is not None and getattr(frame_bgr, 'size', 0):
        h, w = frame_bgr.shape[:2]
        x1, y1, x2, y2 = [int(round(v)) for v in focus]
        bw = max(8, x2 - x1)
        bh = max(8, y2 - y1)
        pad_x = int(bw * 0.12)
        pad_y = int(bh * 0.12)
        x1 = max(0, min(w - 2, x1 - pad_x))
        y1 = max(0, min(h - 2, y1 - pad_y))
        x2 = max(x1 + 2, min(w, x2 + pad_x))
        y2 = max(y1 + 2, min(h, y2 + pad_y))
        crop = frame_bgr[y1:y2, x1:x2]
        if crop.size > 0:
            source = crop
    canvas, _, _, _ = _letterbox_bgr(source, YOLO_IMG_SIZE)
    rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0
    # NCHW for Ultralytics TFLite export.
    return np.expand_dims(np.transpose(rgb, (2, 0, 1)), axis=0)


def _yolo_max_score(interpreter, in_detail, out_detail, nchw: np.ndarray) -> float:
    """Return best objectness/class score 0..100 from YOLO TFLite [1,5,N] output."""
    interpreter.set_tensor(in_detail['index'], nchw)
    interpreter.invoke()
    out = interpreter.get_tensor(out_detail['index'])
    arr = np.squeeze(out)
    if arr.ndim != 2:
        return 0.0
    # Ultralytics export is usually (5, N) or (4+nc, N). Take last row(s) as score.
    if arr.shape[0] in (5, 6) or arr.shape[0] < arr.shape[1]:
        scores = arr[4:].max(axis=0)
    else:
        # (N, 5)
        scores = arr[:, 4:].max(axis=1) if arr.shape[1] >= 5 else arr.max(axis=1)
    if scores.size == 0:
        return 0.0
    best = float(np.max(scores))
    # Some exports are already 0..1; rare exports use logits — clamp.
    if best > 1.5:
        best = 1.0 / (1.0 + np.exp(-min(best, 20.0)))
    return max(0.0, min(100.0, best * 100.0))


def preprocess_frame(frame):
    """Teachable Machine NHWC crop for Empty/Clean SavedModel."""
    h, w = frame.shape[:2]
    ch, cw = max(int(h * 0.84), 32), max(int(w * 0.84), 32)
    y0 = max((h - ch) // 2, 0)
    x0 = max((w - cw) // 2, 0)
    crop = frame[y0:y0 + ch, x0:x0 + cw]
    resized = cv2.resize(crop, (input_shape[1], input_shape[0]))
    rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    arr = rgb.astype(np.float32) / 255.0
    return np.expand_dims(arr, axis=0)


def _tensor_from_bgr(bgr):
    resized = cv2.resize(bgr, (input_shape[1], input_shape[0]))
    rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    arr = rgb.astype(np.float32) / 255.0
    return np.expand_dims(arr, axis=0)


def _empty_clean_from_savedmodel(frame, focus=None) -> tuple[float, float]:
    """Return (empty_pct, clean_pct) from the kept Teachable Machine SavedModel."""
    if signature is None:
        # Fallback if SavedModel failed to load — egg focus ⇒ clean-ish.
        if focus is not None:
            return 10.0, 70.0
        return 80.0, 20.0
    source = frame
    if focus is not None and frame is not None and getattr(frame, 'size', 0):
        h, w = frame.shape[:2]
        x1, y1, x2, y2 = [int(round(v)) for v in focus]
        bw = max(8, x2 - x1)
        bh = max(8, y2 - y1)
        pad_x = int(bw * 0.12)
        pad_y = int(bh * 0.12)
        x1 = max(0, min(w - 2, x1 - pad_x))
        y1 = max(0, min(h - 2, y1 - pad_y))
        x2 = max(x1 + 2, min(w, x2 + pad_x))
        y2 = max(y1 + 2, min(h, y2 + pad_y))
        crop = frame[y1:y2, x1:x2]
        if crop.size > 0:
            source = crop
    if source is frame:
        input_data = preprocess_frame(frame)
    else:
        input_data = _tensor_from_bgr(source)
    import tensorflow as tf
    outputs = signature(**{input_name: tf.constant(input_data)})
    predictions = next(iter(outputs.values())).numpy()
    if predictions.ndim == 2 and predictions.shape[0] == 1:
        predictions = predictions[0]
    # 0 Empty | 1 No Crack (Clean) | 2 Crack | 3 Dirty — only keep 0 and 1.
    empty = float(predictions[0]) * 100.0 if len(predictions) > 0 else 0.0
    clean = float(predictions[1]) * 100.0 if len(predictions) > 1 else 0.0
    return empty, clean


_yolo_flip = 0


_sm_live_tick = 0


def _local_classify(frame, focus=None):
    """Crack/dirty from YOLO TFLite; Empty/Clean from shell path (+ rare SavedModel).

    Runs only ONE YOLO net per call. Skips SavedModel on most ticks so CAM
    push is not GIL-starved (that was freezing /live.jpg and dropping tracks).
    """
    global _yolo_flip, _sm_live_tick
    crack = 0.0
    dirty = 0.0
    if _crack_it is not None and _dirty_it is not None:
        nchw = _yolo_nchw(frame, focus)
        with _tflite_lock:
            _yolo_flip += 1
            if _yolo_flip % 2 == 1:
                crack = _yolo_max_score(_crack_it, _crack_in, _crack_out, nchw)
            else:
                dirty = _yolo_max_score(_dirty_it, _dirty_in, _dirty_out, nchw)

    # New models win for defects — skip SavedModel on this tick (saves latency).
    if crack >= CRACK_SCORE_MIN and crack >= dirty + REJECT_MARGIN * 0.5:
        scores = {
            'Empty Model': 0.0,
            'No Crack Egg': max(0.0, 100.0 - crack),
            'Crack Egg': crack,
            'Dirty Egg': dirty,
        }
        return 'Crack Egg', crack, scores
    if dirty >= DIRTY_SCORE_MIN and dirty >= crack:
        scores = {
            'Empty Model': 0.0,
            'No Crack Egg': max(0.0, 100.0 - dirty),
            'Crack Egg': crack,
            'Dirty Egg': dirty,
        }
        return 'Dirty Egg', dirty, scores

    # Live path never runs SavedModel — TF predict holds the GIL and stalls
    # CAM HTTPS /api/frame (laggy live + broken tracker). Shell vision in
    # _ingest_jpeg owns Empty/Clean; YOLO above owns Crack/Dirty.
    _sm_live_tick += 1
    empty, clean = 5.0, max(55.0, 100.0 - max(crack, dirty))
    scores = {
        'Empty Model': empty,
        'No Crack Egg': clean,
        'Crack Egg': crack,
        'Dirty Egg': dirty,
    }
    if focus is not None:
        return 'No Crack Egg', clean, scores
    if clean >= empty and clean >= CONFIDENCE_THRESHOLD:
        return 'No Crack Egg', clean, scores
    if empty >= CONFIDENCE_THRESHOLD:
        return 'Empty Model', empty, scores
    return 'Empty Model', empty, scores


def _merge_scores(base: dict, extra: dict | None) -> dict:
    out = dict(base or {})
    for key, val in (extra or {}).items():
        out[key] = max(float(out.get(key, 0.0)), float(val))
    return out


def _submit_roboflow(frame) -> None:
    global _rf_busy
    with _rf_busy_lock:
        if _rf_busy:
            return
        _rf_busy = True

    def _job(img):
        global _rf_busy, _rf_last
        try:
            result = infer_bgr_frame(img)
            if result is not None:
                with _rf_last_lock:
                    _rf_last = result
        except Exception as exc:
            print(f'[roboflow] infer failed: {exc}', flush=True)
        finally:
            with _rf_busy_lock:
                _rf_busy = False

    try:
        _rf_pool.submit(_job, frame.copy())
    except Exception:
        with _rf_busy_lock:
            _rf_busy = False


def classify_frame(frame, focus=None):
    """Local model is always used (fast). Roboflow runs in background for boxes."""
    global debug_info, _rf_tick
    label, confidence, scores = _local_classify(frame, focus)
    boxes: list[tuple[int, int, int, int]] = []

    _rf_tick += 1
    if ROBOFLOW_EVERY_N > 0 and _rf_tick % ROBOFLOW_EVERY_N == 0:
        _submit_roboflow(frame)

    with _rf_last_lock:
        rf = _rf_last
    if rf is not None:
        rf_label, rf_conf, rf_scores = rf[0], rf[1], rf[2]
        if len(rf) > 3:
            boxes = list(rf[3] or [])
        scores = _merge_scores(scores, rf_scores)
        # Prefer Roboflow when it names Crack/Dirty more clearly.
        rf_cat = counting_category(rf_label)
        loc_cat = counting_category(label)
        if rf_cat == 'crackedEggs' and rf_conf >= 45.0:
            label, confidence = rf_label, rf_conf
        elif loc_cat is None and rf_cat == 'goodEggs':
            label, confidence = rf_label, rf_conf

    debug_info['rawScores'] = [scores.get(lab, 0.0) for lab in labels] if labels else []
    debug_info['topClasses'] = [
        {'index': i, 'label': lab, 'score': scores.get(lab, 0.0)}
        for i, lab in enumerate(
            sorted(scores, key=lambda k: scores[k], reverse=True)[:3]
        )
    ]
    debug_info['lastFrameTimestamp'] = time.strftime('%Y-%m-%d %H:%M:%S')
    debug_info['frameCount'] += 1
    return label, confidence, scores, boxes


def counting_category(label: str):
    """
    Map a model label to a metrics bucket.

        0 Empty Model  → skip (no egg present)
        1 No Crack Egg → goodEggs
        2 Crack Egg    → crackedEggs
        3 Dirty Egg    → dirtyEggs
    """
    s = label.lower()

    # Must check "no crack" BEFORE "crack" so we don't misclassify good eggs.
    if 'no crack' in s or 'uncrack' in s:
        return 'goodEggs'
    if 'crack' in s or 'broken' in s:
        return 'crackedEggs'
    if 'dirty' in s or 'soiled' in s or 'stain' in s or 'dirt' in s:
        return 'dirtyEggs'
    if 'good' in s or 'ok' in s or 'healthy' in s or 'clean' in s:
        return 'goodEggs'

    # Anything that looks like "empty" / "no egg" / "background" is skipped.
    return None


def _score_buckets(scores: dict) -> tuple[float, float, float]:
    good = crack = dirty = 0.0
    for lab, sc in scores.items():
        cat = counting_category(str(lab))
        val = float(sc)
        if cat == 'goodEggs':
            good = max(good, val)
        elif cat == 'crackedEggs':
            crack = max(crack, val)
        elif cat == 'dirtyEggs':
            dirty = max(dirty, val)
    return good, crack, dirty


def _log(msg: str) -> None:
    """Serial-style log. A closed console must not turn the camera check into HTTP 500."""
    try:
        print(msg, flush=True)
    except Exception:
        pass


def _finish_inspect(reject: bool, label: str) -> None:
    _inspect['ready'] = True
    _inspect['waiting'] = False
    _inspect['reject'] = reject
    _inspect['label'] = label
    _log(f'[inspect] {"REJECT" if reject else "KEEP"} label={label!r}')


def _note_live(label: str, scores: dict | None, confidence: float) -> tuple[float, float, float]:
    good, crack, dirty = _score_buckets(scores or {label: confidence})
    with _live_lock:
        _live['label'] = label
        _live['good'] = good
        _live['crack'] = crack
        _live['dirty'] = dirty
    return good, crack, dirty


def _seed_inspect_from_live() -> None:
    with _live_lock:
        crack = _live['crack']
        dirty = _live['dirty']
        good = _live['good']
        label = _live['label']
    if not _egg_in_view:
        _inspect['best_crack'] = 0.0
        _inspect['best_dirty'] = 0.0
        _inspect['best_good'] = 0.0
        return
    _inspect['best_crack'] = crack
    _inspect['best_dirty'] = dirty
    _inspect['best_good'] = good
    picked, _ = pick_quality({
        'No Crack Egg': good,
        'Crack Egg': crack,
        'Dirty Egg': dirty,
    }, seen_egg=_last_seen_egg, model_label=label)
    if is_empty_frame(picked) or not _egg_on_scale() or not _last_seen_egg:
        return
    cat = counting_category(picked)
    if cat in ('crackedEggs', 'dirtyEggs'):
        _finish_inspect(True, picked)
        _log(f'[inspect] detect+weight -> REJECT {picked}')
    elif cat == 'goodEggs':
        _finish_inspect(False, 'No Crack Egg')
        _log('[inspect] detect+weight -> KEEP')


def _decide_after_weight(grams: float) -> None:
    """Live camera already classified. After the scale reading, lock the servo decision."""
    if grams < 15.0:
        return
    with _live_lock:
        crack = _live['crack']
        dirty = _live['dirty']
        good = _live['good']
        live_label = str(_live.get('label') or '')
    picked, _ = pick_quality({
        'No Crack Egg': good,
        'Crack Egg': crack,
        'Dirty Egg': dirty,
    }, seen_egg=_last_seen_egg, model_label=live_label)
    with _inspect_lock:
        if not _inspect['waiting'] or _inspect['ready']:
            return
        cat = counting_category(picked)
        if cat in ('crackedEggs', 'dirtyEggs'):
            _finish_inspect(True, picked)
            print(f'[weight] {grams}g after detect -> REJECT {picked}', flush=True)
        elif cat == 'goodEggs':
            _finish_inspect(False, 'No Crack Egg')
            print(f'[weight] {grams}g after detect -> KEEP', flush=True)


def _apply_inspect_frame(label: str, confidence: float, scores: dict | None = None) -> None:
    good, crack, dirty = _note_live(label, scores, confidence)
    with _inspect_lock:
        if not _inspect['waiting'] or _inspect['ready']:
            return
        if not _egg_in_view or is_empty_frame(label):
            return
        _inspect['saw_egg'] = True
        _inspect['best_good'] = max(_inspect['best_good'], good)
        _inspect['best_crack'] = max(_inspect['best_crack'], crack)
        _inspect['best_dirty'] = max(_inspect['best_dirty'], dirty)
        print(
            f'[inspect] frame good={good:.0f} crack={crack:.0f} dirty={dirty:.0f} '
            f'top={label!r} {confidence:.0f}%',
            flush=True,
        )
        voted = _vote_station(label)
        elapsed = time.time() - _inspect['asked_at']
        if voted is None and elapsed < INSPECT_WINDOW_SEC:
            return
        if voted is None:
            if _inspect['best_crack'] >= CRACK_SCORE_MIN:
                voted = 'Crack Egg'
            elif _inspect['best_dirty'] >= DIRTY_SCORE_MIN:
                voted = 'Dirty Egg'
            elif _inspect['best_good'] >= 45.0:
                voted = 'No Crack Egg'
            else:
                return
        cat = counting_category(voted)
        if cat == 'crackedEggs' and _inspect['best_crack'] > 0.0:
            _finish_inspect(True, 'Crack Egg')
            return
        if cat == 'dirtyEggs' and _inspect['best_dirty'] >= DIRTY_SCORE_MIN:
            _finish_inspect(True, 'Dirty Egg')
            return
        if cat == 'goodEggs' and (
            _inspect['best_good'] >= 50.0
            or elapsed >= INSPECT_WINDOW_SEC
        ):
            _finish_inspect(False, 'No Crack Egg')


def is_empty_frame(label: str) -> bool:
    """Return True when the model says there is no egg in the frame."""
    s = (label or '').strip().lower()
    if 'no crack' in s or 'uncrack' in s or 'clean' in s:
        return False
    return (
        s == 'empty model'
        or s.startswith('empty')
        or 'no egg' in s
        or 'background' in s
        or s in ('none', 'n/a')
    )


def _empty_score(scores: dict | None) -> float:
    best = 0.0
    for lab, sc in (scores or {}).items():
        if is_empty_frame(str(lab)):
            best = max(best, float(sc))
    return best


def _is_clear_reject(crack: float, dirty: float, good: float) -> bool:
    if crack > 0.0:
        return True
    if dirty >= DIRTY_SCORE_MIN and dirty >= good + REJECT_MARGIN and dirty >= crack:
        return True
    return False


_empty_dirty_ema = 0.0
_empty_dirty_lock = threading.Lock()
_station_vote: deque = deque(maxlen=3)


def _vote_station(label: str) -> str | None:
    if is_empty_frame(label):
        return None
    _station_vote.append(label)
    counts: dict[str, int] = {}
    for item in _station_vote:
        counts[item] = counts.get(item, 0) + 1
    winner = max(counts, key=counts.get)
    if counts[winner] >= 2:
        return winner
    return None


_egg_seen_streak = 0

# The camera crops its own sensor to zoom in. It reports the zoom in each heartbeat.
# The wood post and servo rules below are written for the full view, so move them with the zoom.
_cam_zoom = 1.0


def _set_cam_zoom(value) -> None:
    global _cam_zoom
    try:
        z = float(value)
    except (TypeError, ValueError):
        return
    z = max(1.0, min(2.0, z))
    if abs(z - _cam_zoom) > 0.01:
        _cam_zoom = z
        print(f'[camera] sensor zoom {z:.2f}x', flush=True)


def _zoom_u(u: float) -> float:
    """Where a spot at fraction u of the full view sits in the zoomed (centered) view."""
    z = _cam_zoom
    if z <= 1.001:
        return u
    return min(1.0, max(0.0, (u - (1.0 - 1.0 / z) / 2.0) * z))
_track_lock = threading.RLock()  # RLock: _update_tracker → _pick_track_box nests
# Sticky egg tracker: follows one oval on the belt across frames.
_track = {
    'id': 0,
    'box': None,
    'miss': 0,
    'vx': 0.0,
    'vy': 0.0,
    'confirmed': False,
}
TRACK_MISS_MAX = 10          # tunnel gaps ~1–2s; keep coast so lock does not blink
TRACK_MATCH_PX = 260.0       # eggs move on belt — not giant jumps to fixtures
TRACK_SEARCH_PAD = 0.70
TRACK_COAST_DECAY = 0.85


def _egg_color_mask(crop, wood_cols: int = 0):
    """Bright shell only — must sit well above the dark belt (no flood fill)."""
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    value = hsv[:, :, 2]
    sat = hsv[:, :, 1]
    median = float(np.median(value))
    p85 = float(np.percentile(value, 85))
    p90 = float(np.percentile(value, 90))
    # Shell is a highlight on a dark belt — jump above median, but don't
    # require near-white (overexposed eggs clip at 255 and raise p85).
    bright = int(min(175, max(85, median + 38, min(p85 - 20, 160))))
    white = cv2.inRange(hsv, (0, 0, bright), (180, 110, 255))
    brown = cv2.inRange(hsv, (4, 20, max(70, int(median + 30))), (36, 190, 245))
    # Low-sat bright core (classic white egg) + blown-out glare core.
    core = cv2.bitwise_and(
        cv2.inRange(value, np.array(bright), np.array(255)),
        cv2.inRange(sat, 0, 100),
    )
    glare = cv2.inRange(value, np.array(max(bright, 200)), np.array(255))
    mask = cv2.bitwise_or(white, brown)
    mask = cv2.bitwise_or(mask, core)
    mask = cv2.bitwise_or(mask, glare)
    if wood_cols > 0:
        mask[:, :wood_cols] = cv2.bitwise_and(
            mask[:, :wood_cols],
            cv2.inRange(hsv[:, :wood_cols], (0, 0, max(bright, 150)), (180, 50, 255)),
        )
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    # Close a bit harder so a dark wire across the egg does not split the blob.
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel, iterations=1)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=3)
    return mask


def _contour_is_egg(contour, crop_w: int, crop_h: int) -> bool:
    """Oval shell only — rejects thin metal rails and belt glare streaks."""
    area = cv2.contourArea(contour)
    crop_area = float(max(crop_w * crop_h, 1))
    if area < max(400.0, 0.012 * crop_area) or area > 0.85 * crop_area:
        return False
    x, y, bw, bh = cv2.boundingRect(contour)
    short = float(min(bw, bh))
    long = float(max(bw, bh))
    # Metal post glare is tiny/narrow; eggs need real width + height.
    if short < 22 or long < 28:
        return False
    aspect = long / short
    # Close-up eggs often look nearly round (aspect ~1.0) — still eggs.
    if aspect < 1.0 or aspect > 2.35:
        return False
    # Tall thin vertical rail (the false CRACK on metal).
    if bh >= 1.55 * bw and bw < 0.18 * crop_w:
        return False
    # Long thin belt seam / stitch.
    if bw >= 1.55 * bh and bh < 0.14 * crop_h:
        return False
    peri = cv2.arcLength(contour, True)
    if peri <= 0:
        return False
    circ = (4.0 * np.pi * area) / (peri * peri)
    hull = cv2.convexHull(contour)
    hperi = cv2.arcLength(hull, True)
    harea = cv2.contourArea(hull)
    hcirc = (4.0 * np.pi * harea) / (hperi * hperi) if hperi > 0 else 0.0
    # Eggs are blobby; metal highlights are skinny → low circularity.
    if max(circ, hcirc) < 0.28 or circ > 0.995:
        return False
    extent = area / float(max(bw * bh, 1))
    if extent < 0.35 or extent > 0.97:
        return False
    if len(contour) >= 5:
        try:
            (_, _), (ew, eh), _ = cv2.fitEllipse(contour)
        except cv2.error:
            return True
        e_short = float(min(ew, eh))
        e_long = float(max(ew, eh))
        if e_short < 1:
            return False
        e_asp = e_long / e_short
        if e_asp < 1.0 or e_asp > 2.45:
            return False
    return True


def _box_is_metal_or_belt(frame, box) -> bool:
    """True for fixture rails, specular metal, belt seams — never track these."""
    if frame is None or box is None:
        return True
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w - 1, x2), min(h - 1, y2)
    bw, bh = x2 - x1, y2 - y1
    if bw < 18 or bh < 18:
        return True
    frac = (bw * bh) / float(max(w * h, 1))
    if frac < 0.02 or frac > 0.80:
        return True
    # Vertical metal bar / horn shaft.
    if bh > 1.45 * bw and bw < 0.16 * w:
        return True
    if bw > 1.45 * bh and bh < 0.12 * h:
        return True
    crop = frame[y1:y2, x1:x2]
    if crop.size == 0:
        return True
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    mean_v = float(np.mean(gray))
    std_v = float(np.std(gray))
    # Specular metal flash: tiny bright spike on otherwise dark patch.
    p95 = float(np.percentile(gray, 95))
    if mean_v < 95.0 and p95 > mean_v + 50.0 and std_v > 40.0:
        return True
    # Mostly dark = belt/fixture, not pale shell.
    if mean_v < 85.0:
        return True
    # Gray metal / chrome: low chroma, not cream/brown shell.
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    sat_m = float(np.mean(hsv[:, :, 1]))
    if sat_m < 28.0 and mean_v < 160.0 and (bh > 1.25 * bw or bw > 1.25 * bh):
        return True
    return False


def _belt_roi(frame) -> tuple[int, int, int, int]:
    """Belt pad — keep top open so close-up eggs are not clipped square."""
    h, w = frame.shape[:2]
    return (
        int(w * 0.04),
        int(h * 0.06),
        int(w * 0.94),
        int(h * 0.98),
    )


def _detect_egg_boxes_in_roi(frame, x0, y0, x1, y1) -> list[tuple[int, int, int, int]]:
    if frame is None or getattr(frame, 'size', 0) == 0:
        return []
    h, w = frame.shape[:2]
    x0 = max(0, min(w - 2, int(x0)))
    y0 = max(0, min(h - 2, int(y0)))
    x1 = max(x0 + 2, min(w, int(x1)))
    y1 = max(y0 + 2, min(h, int(y1)))
    crop = frame[y0:y1, x0:x1]
    if crop.size == 0:
        return []
    mask = _egg_color_mask(crop, wood_cols=max(0, int(0.10 * (x1 - x0))))
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    ch, cw = crop.shape[:2]
    scored: list[tuple[float, tuple[int, int, int, int]]] = []
    for contour in contours:
        if not _contour_is_egg(contour, cw, ch):
            continue
        x, y, bw, bh = cv2.boundingRect(contour)
        box = (x0 + x, y0 + y, x0 + x + bw, y0 + y + bh)
        if _box_is_metal_or_belt(frame, box):
            continue
        # Soft JPEG over tunnel is blurry — shell fill must stay loose or lock never starts.
        if not _box_is_egg_shell(frame, box, min_shell=0.14):
            continue
        if not _box_looks_like_egg(frame, box):
            continue
        area = float((box[2] - box[0]) * (box[3] - box[1]))
        # Ignore debris; allow close-up eggs that fill most of the FOV.
        frame_area = float(max(w * h, 1))
        # Allow smaller / edge-entry eggs so lock starts as soon as it enters FOV.
        if area < 0.008 * frame_area or area > 0.88 * frame_area:
            continue
        if _box_is_wood_board(frame, box):
            continue
        roi = frame[max(0, box[1]):min(h, box[3]), max(0, box[0]):min(w, box[2])]
        glow = float(np.mean(cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY))) if roi.size else 0.0
        if glow < 55.0:
            continue  # pale shell vs dark empty pad
        scored.append((area * (1.0 + glow / 255.0), box))
    scored.sort(key=lambda t: t[0], reverse=True)
    return [scored[0][1]] if scored else []


def _detect_egg_boxes(frame) -> list[tuple[int, int, int, int]]:
    """Belt ROI only — at most one real egg (never metal/belt)."""
    if frame is None or getattr(frame, 'size', 0) == 0:
        return []
    x0, y0, x1, y1 = _belt_roi(frame)
    return _detect_egg_boxes_in_roi(frame, x0, y0, x1, y1)[:1]


def _search_egg_near(frame, prev_box) -> list[tuple[int, int, int, int]]:
    """Re-find a moving egg around the predicted next box (last box + velocity)."""
    if frame is None or prev_box is None:
        return []
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = [float(v) for v in prev_box]
    with _track_lock:
        vx = float(_track.get('vx') or 0.0)
        vy = float(_track.get('vy') or 0.0)
    # Search where the egg is going, not only where it was.
    x1, x2 = x1 + vx, x2 + vx
    y1, y2 = y1 + vy, y2 + vy
    bw = max(20.0, x2 - x1)
    bh = max(20.0, y2 - y1)
    # Extra pad grows with speed so fast belt motion still hits.
    speed = (vx * vx + vy * vy) ** 0.5
    pad_scale = TRACK_SEARCH_PAD + min(0.8, speed / 80.0)
    pad_x = bw * pad_scale + abs(vx) * 1.5
    pad_y = bh * pad_scale + abs(vy) * 1.5
    sx0 = max(0, int(x1 - pad_x))
    sy0 = max(int(h * 0.22), int(y1 - pad_y))
    sx1 = min(w, int(x2 + pad_x))
    sy1 = min(h, int(y2 + pad_y))
    return _detect_egg_boxes_in_roi(frame, sx0, sy0, sx1, sy1)


def _merge_track_candidates(fresh, near) -> list:
    """Combine full-ROI and near-search boxes; prefer near matches for a live track."""
    merged: list = []
    seen = []
    for box in list(near) + list(fresh):
        cx, cy = _box_center(box)
        dup = False
        for sx, sy in seen:
            if (cx - sx) ** 2 + (cy - sy) ** 2 < 28.0 ** 2:
                dup = True
                break
        if dup:
            continue
        seen.append((cx, cy))
        merged.append(box)
    return merged[:4]


def _box_is_wood_board(frame, box) -> bool:
    """True for empty wooden/metal deck fill — grainy flat field, not a smooth egg."""
    if frame is None or box is None:
        return True
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w - 1, x2), min(h - 1, y2)
    bw, bh = x2 - x1, y2 - y1
    if bw < 16 or bh < 16:
        return True
    frac = (bw * bh) / float(max(w * h, 1))
    # Whole-board fill only — close-up eggs can be large in frame.
    if frac > 0.78:
        return True
    crop = frame[y1:y2, x1:x2]
    if crop.size == 0:
        return True
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    blur = cv2.GaussianBlur(gray, (3, 3), 0)
    lap = float(cv2.Laplacian(blur, cv2.CV_64F).var())
    # Egg on dark belt: pale oval, darker surround. Flat board: same tone outside.
    pad = int(max(8, 0.22 * max(bw, bh)))
    sx0, sy0 = max(0, x1 - pad), max(0, y1 - pad)
    sx1, sy1 = min(w, x2 + pad), min(h, y2 + pad)
    ring = frame[sy0:sy1, sx0:sx1]
    if ring.size == 0:
        return True
    ring_g = cv2.cvtColor(ring, cv2.COLOR_BGR2GRAY)
    mask = np.ones(ring_g.shape, np.uint8)
    mask[y1 - sy0:y2 - sy0, x1 - sx0:x2 - sx0] = 0
    if int(mask.sum()) < 80:
        return False
    inside_m = float(np.mean(gray))
    ring_m = float(np.mean(ring_g[mask > 0]))
    contrast = inside_m - ring_m
    if contrast < 22.0:
        return True  # no bright-on-dark egg contrast → empty pad / board
    # Soft JPEG egg is smooth; pad wrinkles and wood grain are busy.
    if lap > 70.0 and contrast < 55.0:
        return True
    if lap > 140.0 and contrast < 85.0:
        return True
    return False


def _box_looks_like_egg(frame, box) -> bool:
    """Confirm a detector box is an egg oval — reject metal posts / wood / tools."""
    if frame is None or box is None:
        return False
    if _box_is_wood_board(frame, box):
        return False
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    x1 = max(0, min(w - 2, x1))
    y1 = max(0, min(h - 2, y1))
    x2 = max(x1 + 2, min(w - 1, x2))
    y2 = max(y1 + 2, min(h - 1, y2))
    bw = x2 - x1
    bh = y2 - y1
    frac = (bw * bh) / float(max(w * h, 1))
    if frac < 0.018 or frac > 0.72:
        return False
    aspect = max(bw, bh) / float(max(min(bw, bh), 1))
    # Near-round close-up eggs (aspect ~1.0) must still count.
    if aspect < 1.0 or aspect > 2.45:
        return False
    roi = frame[y1:y2, x1:x2]
    if roi.size == 0:
        return False
    mean_v = float(np.mean(cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)))
    if mean_v < 70.0:
        return False  # egg shell is bright vs dark empty pad
    mask = _egg_color_mask(roi)
    egg_px = cv2.countNonZero(mask)
    # Soft JPEG: shell fill looks thinner — keep loose so tracker can lock.
    if egg_px < 0.10 * roi.shape[0] * roi.shape[1]:
        return False
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return False
    best = max(contours, key=cv2.contourArea)
    return _contour_is_egg(best, roi.shape[1], roi.shape[0])


def _box_is_egg_shell(frame, box, min_shell: float = 0.20) -> bool:
    """True for pale/brown egg shell — not wood, metal, or belt glare."""
    if frame is None or box is None:
        return False
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w - 1, x2), min(h - 1, y2)
    if x2 - x1 < 12 or y2 - y1 < 12:
        return False
    cx = (x1 + x2) / 2.0
    cy = (y1 + y2) / 2.0
    if cx < w * _zoom_u(0.04) or cx > w * _zoom_u(0.98) or cy < h * 0.05:
        return False
    frac = ((x2 - x1) * (y2 - y1)) / float(max(w * h, 1))
    if frac < 0.008 or frac > 0.88:
        return False
    if _box_is_wood_board(frame, box):
        return False
    crop = frame[y1:y2, x1:x2]
    if crop.size == 0:
        return False
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    if float(np.mean(gray)) < 60.0:
        return False  # must be bright shell, not dark empty pad
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    mask = _egg_color_mask(crop)
    erode_k = 3 if min(y2 - y1, x2 - x1) < 48 else 5
    inside = cv2.erode(mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (erode_k, erode_k))) > 0
    if int(inside.sum()) < 20:
        inside = mask > 0
        if int(inside.sum()) < 40:
            return False
    hh = hsv[:, :, 0][inside]
    ss = hsv[:, :, 1][inside].astype(np.float32)
    vv = hsv[:, :, 2][inside].astype(np.float32)
    pale = float(((ss < 130.0) & (vv > 90.0)).mean())
    brown = float(((hh >= 3) & (hh <= 38) & (ss > 12.0) & (ss < 210.0) & (vv > 50.0)).mean())
    red = float((((hh < 8) | (hh > 165)) & (ss > 120.0)).mean())
    wood = float(((hh >= 8) & (hh <= 40) & (ss > 55.0) & (vv > 60.0) & (vv < 200.0)).mean())
    if red > 0.18 or wood > 0.35:
        return False
    return (pale + brown) >= min_shell


def _box_center(box) -> tuple[float, float]:
    return ((box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0)


def _iou(a, b) -> float:
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0:
        return 0.0
    area_a = max(1.0, (ax2 - ax1) * (ay2 - ay1))
    area_b = max(1.0, (bx2 - bx1) * (by2 - by1))
    return inter / (area_a + area_b - inter)


def _pick_track_box(cands, prev):
    if not cands:
        return None
    if prev is None:
        return max(cands, key=lambda b: (b[2] - b[0]) * (b[3] - b[1]))
    px, py = _box_center(prev)
    # Predict next center from last velocity so a moving egg stays locked.
    with _track_lock:
        pred_x = px + float(_track.get('vx') or 0.0)
        pred_y = py + float(_track.get('vy') or 0.0)
    best = None
    best_score = 1e18
    for box in cands:
        cx, cy = _box_center(box)
        dist = (cx - pred_x) ** 2 + (cy - pred_y) ** 2
        iou = _iou(prev, box)
        # Moving eggs: accept larger jumps if IoU still overlaps predicted path.
        if dist > TRACK_MATCH_PX ** 2 and iou < 0.03:
            continue
        score = dist - 5500.0 * iou
        if score < best_score:
            best_score = score
            best = box
    return best


def _update_tracker(cands, keep: bool = False, frame=None):
    """Follow one egg. keep=True coasts the box when the detector briefly misses."""
    with _track_lock:
        prev = _track['box']
        # Drop a stuck metal/belt track immediately.
        if prev is not None and frame is not None and _box_is_metal_or_belt(frame, prev):
            _track['box'] = None
            _track['confirmed'] = False
            _track['miss'] = 0
            _track['vx'] = _track['vy'] = 0.0
            prev = None
        # Never adopt metal/belt candidates.
        cands = [
            b for b in (cands or [])
            if frame is None or not _box_is_metal_or_belt(frame, b)
        ]
        picked = _pick_track_box(cands, prev)
        if picked is None:
            _track['miss'] += 1
            if keep and prev is not None and _track['miss'] <= TRACK_MISS_MAX:
                # Coast only briefly — metal glare must not stick around.
                if _track['miss'] > 8:
                    _track['box'] = None
                    _track['confirmed'] = False
                    _track['vx'] = _track['vy'] = 0.0
                    return None, _track['id']
                vx = float(_track.get('vx') or 0.0) * TRACK_COAST_DECAY
                vy = float(_track.get('vy') or 0.0) * TRACK_COAST_DECAY
                _track['vx'], _track['vy'] = vx, vy
                _track['box'] = (
                    prev[0] + vx, prev[1] + vy,
                    prev[2] + vx, prev[3] + vy,
                )
                return _track['box'], _track['id']
            if _track['miss'] >= TRACK_MISS_MAX:
                _track['box'] = None
                _track['confirmed'] = False
                _track['vx'] = _track['vy'] = 0.0
            return _track['box'], _track['id']
        if prev is None:
            _track['id'] += 1
            _track['box'] = tuple(float(v) for v in picked)
            _track['vx'] = _track['vy'] = 0.0
            _track['confirmed'] = True
        else:
            pcx, pcy = _box_center(prev)
            ncx, ncy = _box_center(picked)
            # Follow motion faster so the box stays on a rolling egg.
            _track['vx'] = 0.45 * float(_track.get('vx') or 0.0) + 0.55 * (ncx - pcx)
            _track['vy'] = 0.45 * float(_track.get('vy') or 0.0) + 0.55 * (ncy - pcy)
            # Almost snap to new box — heavy smoothing made the box chase behind the egg.
            alpha = 0.08
            _track['box'] = tuple(
                alpha * old + (1.0 - alpha) * new
                for old, new in zip(prev, picked)
            )
            _track['confirmed'] = True
        _track['miss'] = 0
        return _track['box'], _track['id']


def _clear_tracker() -> None:
    with _track_lock:
        _track['box'] = None
        _track['miss'] = 0
        _track['vx'] = _track['vy'] = 0.0
        _track['confirmed'] = False


def _draw_tracker(vis, box, color) -> None:
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    cv2.rectangle(vis, (x1, y1), (x2, y2), color, 2)
    length = max(16, min(x2 - x1, y2 - y1) // 5)
    thick = 3
    segs = (
        ((x1, y1), (x1 + length, y1)), ((x1, y1), (x1, y1 + length)),
        ((x2, y1), (x2 - length, y1)), ((x2, y1), (x2, y1 + length)),
        ((x1, y2), (x1 + length, y2)), ((x1, y2), (x1, y2 - length)),
        ((x2, y2), (x2 - length, y2)), ((x2, y2), (x2, y2 - length)),
    )
    for start, end in segs:
        cv2.line(vis, start, end, color, thick, cv2.LINE_AA)
    cx = (x1 + x2) // 2
    cy = (y1 + y2) // 2
    cv2.drawMarker(vis, (cx, cy), color, cv2.MARKER_CROSS, 16, 2)


def _frame_looks_like_egg(frame) -> bool:
    return bool(_detect_egg_boxes(frame))


def frame_has_egg(frame) -> bool:
    global _egg_seen_streak
    if _frame_looks_like_egg(frame):
        _egg_seen_streak = min(4, _egg_seen_streak + 1)
    else:
        _egg_seen_streak = max(0, _egg_seen_streak - 1)
    return _egg_seen_streak >= 2


def _model_says_egg(scores: dict | None, model_label: str) -> bool:
    """True when the classifier names an egg class (Clean/Crack/Dirty)."""
    scores = scores or {}
    good, crack, dirty = _score_buckets(scores)
    egg_best = max(good, crack, dirty)
    empty = _empty_score(scores)
    cat = counting_category(model_label)
    if empty >= egg_best + 20.0 and empty >= 60.0:
        return False
    if cat in ('goodEggs', 'crackedEggs', 'dirtyEggs'):
        return True
    return egg_best >= 48.0 and egg_best >= empty + 5.0


def _usable_boxes(boxes, frame) -> list[tuple[int, int, int, int]]:
    if frame is None or getattr(frame, 'size', 0) == 0:
        return []
    h, w = frame.shape[:2]
    area = float(max(w * h, 1))
    out: list[tuple[int, int, int, int]] = []
    for box in boxes or []:
        x1, y1, x2, y2 = (int(box[0]), int(box[1]), int(box[2]), int(box[3]))
        bw = max(0, x2 - x1)
        bh = max(0, y2 - y1)
        frac = (bw * bh) / area
        if frac < 0.02 or frac > 0.55:
            continue
        cand = (x1, y1, x2, y2)
        if not _box_looks_like_egg(frame, cand):
            continue
        out.append(cand)
    return out


def _fallback_track_box(frame) -> tuple[int, int, int, int]:
    h, w = frame.shape[:2]
    return (int(w * 0.30), int(h * 0.22), int(w * 0.70), int(h * 0.78))


def egg_is_present(frame, scores: dict | None, boxes, model_label: str, shaped=None) -> bool:
    """Real egg oval on the belt only — never weight, servo, wood, or hands."""
    shape_ok = bool(shaped) if shaped is not None else bool(_detect_egg_boxes(frame))
    rf_ok = any(
        _box_looks_like_egg(frame, box) and _box_is_egg_shell(frame, box)
        for box in (boxes or [])
    )
    model_ok = _model_says_egg(scores, model_label)
    if not model_ok:
        return False
    return shape_ok or rf_ok


def pick_quality(
    scores: dict | None,
    seen_egg: bool = True,
    model_label: str = '',
) -> tuple[str, float]:
    """Camera: Crack / Dirty / Clean when an egg is confirmed. Else Empty."""
    global _empty_dirty_ema
    scores = scores or {}
    good, crack, dirty = _score_buckets(scores)
    empty = _empty_score(scores)
    cat = counting_category(model_label)

    if not seen_egg:
        with _empty_dirty_lock:
            _empty_dirty_ema = (0.85 * _empty_dirty_ema) + (0.15 * dirty)
        return 'Empty Model', 0.0

    # If Empty wins clearly, do not invent Clean on a non-egg.
    if empty >= max(good, crack, dirty) + 15.0 and empty >= 55.0:
        return 'Empty Model', 0.0

    # Prefer explicit model label when it already named a defect.
    if cat == 'crackedEggs' and crack >= CRACK_SCORE_MIN:
        return 'Crack Egg', crack
    if cat == 'dirtyEggs' and dirty >= DIRTY_SCORE_MIN:
        return 'Dirty Egg', dirty

    # Crack / Dirty must beat Clean — never fold Dirty into Clean.
    if crack >= CRACK_SCORE_MIN and crack >= dirty and crack >= good + 8.0:
        return 'Crack Egg', crack
    if dirty >= DIRTY_SCORE_MIN and dirty >= crack and dirty >= good + 8.0:
        return 'Dirty Egg', dirty
    if good >= 55.0 and good >= crack + 8.0 and good >= dirty + 8.0:
        return 'Clean Egg', good
    return 'Empty Model', 0.0


_last_count_at = 0.0
_last_seen_egg = False
_egg_in_view = False
# Lock on first solid oval — waiting 2+ frames made moving eggs look late.
EGG_CONFIRM_FRAMES = 1
_classify_tick = 0
# After that, this many missed frames in a row still count as the same egg.
# Tunnel gaps ~1–2s — allow more miss frames so a moving egg stays locked.
EGG_LOST_GRACE = 8
_egg_streak = 0
_egg_lost = 0
_scan_lock = threading.Lock()
_scan = {
    'start': 0.0,
    'crack': 0.0,
    'dirty': 0.0,
    'good': 0.0,
    'crack_hit': False,
    'dirty_hit': False,
    'decided': '',
    'committed': False,
    'hold_until': 0.0,
    'logged': -1,
    'last_seen': 0.0,
    'hits': 0,
    'misses': 0,
    'crack_n': 0,
    'dirty_n': 0,
    'good_n': 0,
}


def _reset_scan() -> None:
    _scan['start'] = 0.0
    _scan['crack'] = 0.0
    _scan['dirty'] = 0.0
    _scan['good'] = 0.0
    _scan['crack_hit'] = False
    _scan['dirty_hit'] = False
    _scan['decided'] = ''
    _scan['committed'] = False
    _scan['logged'] = -1
    _scan['last_seen'] = 0.0
    _scan['hits'] = 0
    _scan['misses'] = 0
    _scan['crack_n'] = 0
    _scan['dirty_n'] = 0
    _scan['good_n'] = 0


def _scan_active() -> tuple[bool, float]:
    with _scan_lock:
        if _scan['start'] > 0.0 and not _scan['decided']:
            left = max(0.0, SCAN_SEC - (time.monotonic() - _scan['start']))
            return True, round(left, 1)
    return False, 0.0


def _egg_interior(crop, margin: int):
    """Solid egg area (crack gaps filled), pulled in from the rim."""
    mask = _egg_color_mask(crop)
    cnts, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cnts:
        return None
    big = max(cnts, key=cv2.contourArea)
    solid = np.zeros(mask.shape, np.uint8)
    cv2.drawContours(solid, [big], -1, 255, -1)
    k = max(3, int(margin) * 2 + 1)
    pad = k
    solid = cv2.copyMakeBorder(solid, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=0)
    solid = cv2.erode(solid, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
    return solid[pad:-pad, pad:-pad] > 0


# Thin dark line = crack. Soft JPEG (HQVGA Q~14) blurs hairlines — slightly looser.
CRACK_MIN_CONTRAST = 20.0
CRACK_MIN_LEN_FRAC = 0.14
CRACK_MIN_ELONG = 3.2
_crack_dbg_at = 0.0


def _crack_lines(frame, box) -> tuple[bool, float, float]:
    """Find thin dark lines inside the shell. Returns (found, contrast, length_px)."""
    if frame is None or box is None or getattr(frame, 'size', 0) == 0:
        return False, 0.0, 0.0
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w, x2), min(h, y2)
    bw, bh = x2 - x1, y2 - y1
    if bw < 40 or bh < 40:
        return False, 0.0, 0.0
    crop = frame[y1:y2, x1:x2]
    size = float(min(bw, bh))
    k = int(max(5, round(size * 0.045))) | 1
    margin = k // 2 + max(3, int(size * 0.04))
    inside = _egg_interior(crop, margin)
    if inside is None or int(inside.sum()) < 400:
        return False, 0.0, 0.0
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (3, 3), 0)
    se = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    # Dark line on a pale egg, or a pale line on a brown egg.
    dark = cv2.morphologyEx(gray, cv2.MORPH_BLACKHAT, se)
    light = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, se)
    resp = np.maximum(dark, light)
    vals = resp[inside].astype(np.float32)
    med = float(np.median(vals))
    mad = float(np.median(np.abs(vals - med))) * 1.4826
    thr = max(CRACK_MIN_CONTRAST, med + 3.2 * mad + 2.0)
    binary = ((resp >= thr) & inside).astype(np.uint8)
    binary = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    n, labels, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    dist = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
    # How far each pixel is from the shell rim. Marks hugging the rim are edge shading.
    rim = cv2.distanceTransform(cv2.copyMakeBorder(inside.astype(np.uint8), 1, 1, 1, 1,
                                                   cv2.BORDER_CONSTANT, value=0),
                                cv2.DIST_L2, 3)[1:-1, 1:-1]
    min_rim = max(2.0, size * 0.035)
    best_len = 0.0
    best_con = 0.0
    min_len = max(10.0, size * CRACK_MIN_LEN_FRAC)
    for i in range(1, n):
        area = float(stats[i, cv2.CC_STAT_AREA])
        if area < 10:
            continue
        cw = float(stats[i, cv2.CC_STAT_WIDTH])
        ch = float(stats[i, cv2.CC_STAT_HEIGHT])
        length = float(np.hypot(cw, ch))
        if length < min_len:
            continue
        comp = labels == i
        thick = max(1.0, 2.0 * float(dist[comp].max()))
        # A soft, slightly wide crack still counts. A big round stain does not.
        if thick > max(10.0, size * 0.10):
            continue
        if float(rim[comp].mean()) < min_rim:
            continue  # sits on the rim, not across the shell
        if length / thick < CRACK_MIN_ELONG:
            continue
        con = float(resp[comp].mean())
        if length > best_len:
            best_len, best_con = length, con
    return best_len > 0.0, best_con, best_len


def _shell_quality(frame, box) -> str:
    """Smooth shell is clean. A dark line inside is a crack. A stain is dirty."""
    if frame is None or box is None or getattr(frame, 'size', 0) == 0:
        return ''
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = [int(round(v)) for v in box]
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w, x2), min(h, y2)
    if x2 - x1 < 24 or y2 - y1 < 24:
        return ''
    crop = frame[y1:y2, x1:x2]
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    mask = _egg_color_mask(crop)
    inside = cv2.erode(mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))) > 0
    if int(inside.sum()) < 150:
        return ''
    vv = hsv[:, :, 2][inside].astype(np.float32)
    ss = hsv[:, :, 1][inside].astype(np.float32)
    mean_v = float(vv.mean())
    std_v = float(vv.std())
    med_s = float(np.median(ss))
    dark = float(((vv < mean_v - 45.0) & (vv < 150.0)).mean())
    # Stain is color that stands out from this shell. A brown egg is not dirt.
    stain = float(((ss > med_s + 45.0) & (ss > 80.0) & (vv > 40.0)).mean())
    # Only a thin dark LINE is a crack — never call crack from soft shadow / blur.
    cracked, contrast, length = _crack_lines(frame, box)
    if cracked:
        global _crack_dbg_at
        now = time.monotonic()
        if now - _crack_dbg_at > 2.0:
            _crack_dbg_at = now
            print(f'[crack] thin line len={length:.0f}px contrast={contrast:.0f}', flush=True)
        return 'crack'
    # Real stain / soil patch → Dirty (do not fold into Clean).
    if stain >= 0.08 and dark >= 0.04:
        return 'dirty'
    if dark <= 0.10 and stain < 0.06:
        return 'clean'
    return ''


def _apply_shell(scores: dict, shell: str) -> dict:
    out = dict(scores or {})
    if shell == 'clean':
        # Soft prior only — never crush YOLO crack/dirty (soft JPEG false-clean).
        out['No Crack Egg'] = max(float(out.get('No Crack Egg', 0.0)), 70.0)
    elif shell == 'crack':
        out['Crack Egg'] = max(float(out.get('Crack Egg', 0.0)), 80.0)
        out['No Crack Egg'] = min(float(out.get('No Crack Egg', 0.0)), 30.0)
        out['Dirty Egg'] = min(float(out.get('Dirty Egg', 0.0)), 30.0)
    elif shell == 'dirty':
        out['Dirty Egg'] = max(float(out.get('Dirty Egg', 0.0)), 80.0)
        out['No Crack Egg'] = min(float(out.get('No Crack Egg', 0.0)), 30.0)
        out['Crack Egg'] = min(float(out.get('Crack Egg', 0.0)), 30.0)
    return out


def _camera_quality_name(label: str) -> str:
    low = (label or '').lower()
    if 'crack' in low and 'no crack' not in low:
        return 'Crack'
    if 'dirty' in low or 'soil' in low or 'stain' in low:
        return 'Dirty'
    if 'clean' in low or 'no crack' in low or 'good' in low:
        return 'Clean'
    return 'Pending'


def _commit_camera_detection(label: str, confidence: float = 80.0) -> str | None:
    """One visible egg → one Firebase record (Clean / Crack / Dirty)."""
    global _last_count_at, _clean_hold_until, _reject_hold_until, _pending_weight
    cat = counting_category(label)
    if cat not in ('goodEggs', 'crackedEggs', 'dirtyEggs'):
        return None
    cam = _camera_quality_name(label)
    now = time.monotonic()
    with _egg_pipe_lock:
        # Good egg waiting on the scale — do not open a second record yet.
        if (
            _egg_pipe.get('awaiting_weight')
            and _egg_pipe.get('id')
            and (now - float(_egg_pipe.get('opened_at') or 0.0)) < AWAIT_WEIGHT_TIMEOUT_SEC
        ):
            print(
                f'[egg] still waiting weight for {_egg_pipe["id"][:8]}... '
                f'({_egg_pipe.get("camera")}) - skip duplicate',
                flush=True,
            )
            return str(_egg_pipe['id'])
        # Timed-out wait — free pipe so tracker/detect can run on the next egg.
        if _egg_pipe.get('awaiting_weight'):
            _egg_pipe['awaiting_weight'] = False
            _egg_pipe['id'] = ''
            print('[egg] cleared stale awaiting_weight — ready to detect', flush=True)
        rid = uuid.uuid4().hex
        # Clean / Crack / Dirty all get grams when this egg hits the load cell.
        await_w = True
        _egg_pipe['id'] = rid
        _egg_pipe['camera'] = cam
        _egg_pipe['category'] = cat
        _egg_pipe['awaiting_weight'] = await_w
        _egg_pipe['weighed'] = False
        _egg_pipe['opened_at'] = now
        metrics[cat] = int(metrics.get(cat) or 0) + 1
        _last_count_at = now
    # GATE cue for DevKit — long enough for flaky extender Wi‑Fi (HB often misses 5s).
    # Firmware latches with gateDecisionPulsed (one physical move).
    if cat == 'goodEggs':
        _clean_hold_until = now + 25.0
        _reject_hold_until = 0.0
    else:
        _reject_hold_until = now + 25.0
        _clean_hold_until = 0.0
    sorting = sorting_result_for(cat)
    # Firebase immediately for Good, Cracked, and Dirty (one doc per egg).
    # Placeholder grams (>0) so older Firestore rules still accept the create;
    # real weight attaches when the same egg hits the load cell.
    remember_sorted_egg(
        weight=0.01,
        size_class='pending',
        camera_result=cam,
        sorting_result=sorting,
        record_id=rid,
        measurement_status='uncalibrated',
        device_id='egg-camera',
    )
    detection_records.append({
        'id': rid,
        'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
        'label': cam,
        'confidence': round(float(confidence or 80.0), 1),
        'category': cat,
        'weightGrams': None,
        'sizeClass': 'pending',
        'awaitingWeight': True,
    })
    # Immediate Live Inspection HUD — do not wait for the next classify tick.
    if cat == 'goodEggs':
        metrics['lastLabel'] = 'Clean Egg'
    elif cat == 'dirtyEggs':
        metrics['lastLabel'] = 'Dirty Egg'
    else:
        metrics['lastLabel'] = 'Crack Egg'
    metrics['lastConfidence'] = round(float(confidence or 80.0), 1)
    metrics['status'] = f'{cam} recorded — waiting for weight'
    # Drop stale pad grams so weight cannot attach until THIS egg reaches
    # the load cell and DevKit POSTs /weight with commitEgg.
    with _weight_lock:
        _pending_weight = None
    metrics['lastSizeClass'] = 'pending'
    metrics['lastWeightGrams'] = 0.0
    metrics['lastMeasurementStatus'] = 'pending'
    # Sync disk immediately so hard refresh / tunnel blips cannot lose the row.
    _save_live_detections()
    print(
        f'[egg] CAMERA {cam} → recorded id={rid[:8]}... '
        f'(weight pending → load cell)',
        flush=True,
    )
    return rid


def _attach_scale_to_camera_egg(
    grams: float,
    size: str,
    *,
    measurement_status: str = 'uncalibrated',
    device_id: str = 'egg-devkit',
) -> str | None:
    """Same egg: fill weight/size on the open Clean/Crack/Dirty camera record."""
    with _egg_pipe_lock:
        rid = str(_egg_pipe.get('id') or '')
        awaiting = bool(_egg_pipe.get('awaiting_weight'))
        cam = str(_egg_pipe.get('camera') or 'Clean')
        cat = str(_egg_pipe.get('category') or 'goodEggs')
        opened_at = float(_egg_pipe.get('opened_at') or 0.0)
        if not rid or not awaiting:
            return None
        # Belt travel ~4–5s camera → pad, then pad settles before weigh/record.
        # Ignore any lock before the egg can physically arrive.
        # Selftest uses measurement_status='simulated' and may skip the delay.
        age = time.monotonic() - opened_at if opened_at else 999.0
        if measurement_status != 'simulated' and age < 5.0:
            print(
                f'[egg] SCALE {grams}g ignored — only {age:.1f}s after camera '
                f'(need ≥5s travel to pad)',
                flush=True,
            )
            return None
        _egg_pipe['awaiting_weight'] = False
        _egg_pipe['weighed'] = True
    ok = attach_weight_to_egg(
        rid,
        weight=grams,
        size_class=size,
        measurement_status=measurement_status,
    )
    if not ok:
        # Fallback: new row still linked by camera label (should be rare).
        rid = remember_sorted_egg(
            weight=grams,
            size_class=size,
            camera_result=cam,
            sorting_result=sorting_result_for(cat),
            measurement_status=measurement_status,
            device_id=device_id,
        )
    for rec in detection_records:
        if rec.get('id') == rid:
            rec['weightGrams'] = grams
            rec['sizeClass'] = size
            rec['awaitingWeight'] = False
            break
    else:
        detection_records.append({
            'id': rid,
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
            'label': cam,
            'confidence': 80.0,
            'category': cat,
            'weightGrams': grams,
            'sizeClass': size,
            'awaitingWeight': False,
        })
    metrics['lastWeightGrams'] = grams
    metrics['lastSizeClass'] = size
    metrics['lastMeasurementStatus'] = measurement_status
    metrics['status'] = f'{cam} weighed {grams:g} g'
    _save_live_detections_bg()
    print(
        f'[egg] SCALE {grams}g {size} attached to camera {cam} id={rid[:8]}...',
        flush=True,
    )
    return rid


def _scan_decision(now: float, elapsed: float) -> tuple[str, float]:
    crack_n = int(_scan['crack_n'])
    dirty_n = int(_scan['dirty_n'])
    good_n = int(_scan['good_n'])
    hits = int(_scan['hits'])
    crack_sc = float(_scan['crack'])
    dirty_sc = float(_scan['dirty'])
    good_sc = float(_scan['good'])
    # After the watch: Clean / Crack / Dirty — never fold Dirty into Clean.
    if crack_n >= 2 and crack_n >= dirty_n and crack_n > good_n:
        label, conf = 'Crack Egg', max(crack_sc, 70.0)
    elif dirty_n >= 2 and dirty_n >= crack_n and dirty_n > good_n:
        label, conf = 'Dirty Egg', max(dirty_sc, 70.0)
    elif crack_sc >= CRACK_SCORE_MIN and crack_sc >= dirty_sc + 5.0 and crack_sc >= good_sc + 8.0:
        label, conf = 'Crack Egg', max(crack_sc, 68.0)
    elif dirty_sc >= DIRTY_SCORE_MIN and dirty_sc >= crack_sc + 5.0 and dirty_sc >= good_sc + 8.0:
        label, conf = 'Dirty Egg', max(dirty_sc, 68.0)
    elif good_n >= 2 and good_n >= crack_n and good_n >= dirty_n:
        label, conf = 'Clean Egg', max(good_sc, 60.0)
    elif hits >= 3 and crack_n > good_n and crack_n >= dirty_n:
        label, conf = 'Crack Egg', max(crack_sc, 65.0)
    elif hits >= 3 and dirty_n > good_n and dirty_n >= crack_n:
        label, conf = 'Dirty Egg', max(dirty_sc, 65.0)
    elif hits >= 3:
        # Tracked egg, no defect majority → Clean.
        label, conf = 'Clean Egg', max(good_sc, 55.0)
    else:
        _reset_scan()
        return 'Empty Model', 0.0
    _scan['decided'] = label
    _scan['hold_until'] = now + 45.0  # Egg may take time to reach the load cell
    _scan['committed'] = False
    # Station layout: Clean → LEFT, Crack/Dirty → RIGHT (matches DevKit GATE).
    side = 'full left' if label == 'Clean Egg' else 'full right'
    print(
        f'[scan] done {elapsed:.1f}s -> {label}  gate {side}  '
        f'shell c={crack_n} d={dirty_n} g={good_n} hits={hits}  '
        f'crack={crack_sc:.0f} dirty={dirty_sc:.0f} good={good_sc:.0f}',
        flush=True,
    )
    return label, max(conf, 1.0)


def _scan_egg(seen: bool, scores: dict | None, shell: str = '') -> tuple[str, float]:
    """Watch a real egg briefly, then Clean/Crack. Early-exit when votes agree."""
    now = time.monotonic()
    with _scan_lock:
        if _scan['decided']:
            # Decision already locked for this egg — do not extend forever (that
            # made cleanEgg sticky and GATE re-fire while egg lingered in FOV).
            if seen:
                _scan['last_seen'] = now
                _scan['misses'] = 0
                return _scan['decided'], 80.0
            _scan['misses'] = int(_scan['misses']) + 1
            if int(_scan['misses']) < EGG_LOST_GRACE:
                return _scan['decided'], 80.0
            _reset_scan()
            return 'Empty Model', 0.0
        if seen:
            _scan['last_seen'] = now
            _scan['hits'] = int(_scan['hits']) + 1
            _scan['misses'] = 0
            good, crack, dirty = _score_buckets(scores or {})
            if _scan['start'] <= 0.0:
                _scan['start'] = now
                _scan['logged'] = -1
                print(f'[scan] egg seen - counting {SCAN_SEC:.1f}s then Clean/Crack/Dirty', flush=True)
            _scan['crack'] = max(_scan['crack'], crack)
            _scan['dirty'] = max(_scan['dirty'], dirty)
            _scan['good'] = max(_scan['good'], good)
            # Shell + model votes: Crack / Dirty / Clean are separate grades.
            # Model defects beat a soft shell=='clean' (blurry JPEG false-clean).
            if shell == 'crack' or (crack >= CRACK_SCORE_MIN and crack >= dirty + 5.0 and crack >= good + 8.0):
                _scan['crack_n'] = int(_scan['crack_n']) + 1
            elif shell == 'dirty' or (dirty >= DIRTY_SCORE_MIN and dirty >= crack + 5.0 and dirty >= good + 8.0):
                _scan['dirty_n'] = int(_scan['dirty_n']) + 1
            elif (
                crack < CRACK_SCORE_MIN
                and dirty < DIRTY_SCORE_MIN
                and (
                    shell == 'clean'
                    or (good >= 65.0 and good >= crack + 10.0 and good >= dirty + 10.0)
                )
            ):
                _scan['good_n'] = int(_scan['good_n']) + 1
            # else: no vote — empty-pad glare must not pile into Clean
        elif _scan['start'] <= 0.0:
            return 'Empty Model', 0.0
        elif int(_scan['misses']) >= 8 and int(_scan['hits']) < 4:
            print('[scan] egg left — scan cancelled', flush=True)
            _reset_scan()
            return 'Empty Model', 0.0
        else:
            _scan['misses'] = int(_scan['misses']) + 1
        elapsed = now - _scan['start']
        sec = int(elapsed * 10)  # 0.1s ticks while the short scan runs
        if sec != _scan['logged'] and elapsed < SCAN_SEC:
            _scan['logged'] = sec
            if sec % 5 == 0:  # print ~every 0.5s
                print(
                    f'[scan] {elapsed:.1f}s / {SCAN_SEC:.1f}s  '
                    f'crack={_scan["crack"]:.0f} dirty={_scan["dirty"]:.0f} '
                    f'good={_scan["good"]:.0f}  '
                    f'shell c={_scan["crack_n"]} d={_scan["dirty_n"]} g={_scan["good_n"]}',
                    flush=True,
                )
        crack_n = int(_scan['crack_n'])
        dirty_n = int(_scan['dirty_n'])
        good_n = int(_scan['good_n'])
        hits = int(_scan['hits'])
        # Only after full SCAN_SEC (SCAN_EARLY_SEC defaults to same) unless all
        # three vote buckets clearly agree earlier.
        early_ready = (
            elapsed >= SCAN_EARLY_SEC
            and hits >= 4
            and (
                (crack_n >= 4 and crack_n > good_n and crack_n > dirty_n)
                or (dirty_n >= 4 and dirty_n > good_n and dirty_n > crack_n)
                or (good_n >= 4 and crack_n == 0 and dirty_n == 0)
            )
        )
        if early_ready or elapsed >= SCAN_SEC:
            if hits < 3:
                _reset_scan()
                return 'Empty Model', 0.0
            return _scan_decision(now, elapsed)
        return 'Scanning', 0.0


def _jpg_url(stream_url: str) -> str:
    """Map any CAM stream URL to the still-JPEG endpoint on :82/jpg."""
    u = (stream_url or '').strip().rstrip('/')
    if not u:
        return ''
    # Heartbeat / stream use :81/mjpeg — stills are always :82/jpg on this firmware.
    if ':81/mjpeg' in u:
        return u.replace(':81/mjpeg', ':82/jpg')
    if ':81/stream' in u:
        return u.replace(':81/stream', ':82/jpg')
    if ':81/jpg' in u:
        return u.replace(':81/jpg', ':82/jpg')
    if u.endswith('/jpg'):
        if ':81/' in u:
            return u.replace(':81/', ':82/')
        return u
    if u.endswith('/stream'):
        base = u[:-7]
        if base.endswith(':81'):
            return base[:-3] + ':82/jpg'
        return base + '/jpg'
    if u.endswith('/mjpeg'):
        base = u[:-6]
        if base.endswith(':81'):
            return base[:-3] + ':82/jpg'
        return base + '/jpg'
    if '/stream' in u:
        return u.replace('/stream', '/jpg').replace(':81/', ':82/')
    if u.endswith(':81'):
        return u + '/jpg'  # may 404 — discovery also tries :82
    return u + '/jpg'


_jpg_session = requests.Session()
_jpg_session.mount('http://', HTTPAdapter(max_retries=0))
_jpg_session.mount('https://', HTTPAdapter(max_retries=0))


def _inspect_waiting() -> bool:
    with _inspect_lock:
        return bool(_inspect['waiting'] and not _inspect['ready'])


def _grab_jpg(jpg_url: str):
    try:
        r = _jpg_session.get(
            jpg_url,
            timeout=(0.8, 1.8),
            headers={'Connection': 'close'},
        )
        if r.status_code != 200 or not r.content:
            return None
        arr = np.frombuffer(r.content, dtype=np.uint8)
        return cv2.imdecode(arr, cv2.IMREAD_COLOR)
    except Exception:
        return None


_direct_jpg = ''


def _cam_jpg_url() -> str:
    with _stream_url_lock:
        direct = _direct_jpg
        url = ESP32_STREAM_URL
    if direct.startswith('http'):
        return _jpg_url(direct) if '/jpg' not in direct or ':81/' in direct else direct
    jpg = _jpg_url(url)
    if ':8000' in jpg or '127.0.0.1' in jpg or 'localhost' in jpg or not jpg.startswith('http'):
        return 'http://192.168.11.237:82/jpg'
    return jpg


# Last camera address on the extender. A heartbeat replaces this with the live address.
_CAM_FALLBACKS = ('http://192.168.11.237:82/jpg', 'http://192.168.11.237:81/jpg')
_cam_pick = 0
_discover_lock = threading.Lock()
_discovering = False
_discover_at = 0.0


def _discover_cam_async() -> None:
    """Find the ESP32-CAM /jpg on this Wi-Fi when the saved address is quiet."""
    global _discovering
    now = time.monotonic()
    with _discover_lock:
        if _discovering or now - _discover_at < 8.0:
            return
        _discovering = True

    def _run() -> None:
        global _discovering, _discover_at, ESP32_STREAM_URL, _stream_url_epoch, _cam_pick
        found = ''
        try:
            import socket
            probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                probe.connect(('192.168.11.1', 80))
                me = probe.getsockname()[0]
            except Exception:
                me = '192.168.11.212'
            finally:
                probe.close()
            parts = me.split('.')
            if len(parts) != 4:
                return
            prefix = '.'.join(parts[:3])

            def _port_open(host: str) -> str:
                # Prefer :82/jpg (firmware stills). Fall back to :81/jpg.
                for port in (82, 81):
                    s = socket.socket()
                    s.settimeout(0.2)
                    try:
                        if s.connect_ex((host, port)) != 0:
                            continue
                    except Exception:
                        continue
                    finally:
                        s.close()
                    url = f'http://{host}:{port}/jpg'
                    try:
                        r = requests.get(
                            url, timeout=(0.3, 0.8), headers={'Connection': 'close'}
                        )
                        ok = r.status_code == 200 and r.content[:2] == b'\xff\xd8'
                        r.close()
                        if ok:
                            return url
                    except Exception:
                        pass
                return ''

            hosts = [f'{prefix}.{n}' for n in range(2, 255) if f'{prefix}.{n}' != me]
            with ThreadPoolExecutor(max_workers=40) as pool:
                for url in pool.map(_port_open, hosts):
                    if url:
                        found = url
                        break
        finally:
            with _discover_lock:
                _discovering = False
                _discover_at = time.monotonic()
            if found:
                with _stream_url_lock:
                    if ESP32_STREAM_URL != found:
                        ESP32_STREAM_URL = found
                        _stream_url_epoch += 1
                        _cam_pick = 0
                print(f'[worker] camera found at {found}', flush=True)

    threading.Thread(target=_run, daemon=True).start()


def _grab_urls() -> list[str]:
    urls = [_cam_jpg_url()]
    for extra in _CAM_FALLBACKS:
        if extra not in urls:
            urls.append(extra)
    return urls


def _camera_label(label: str) -> str:
    """Live camera reports Clean, Crack, or Dirty (plus SCAN while deciding)."""
    s = (label or '').strip().lower()
    if not s or s in ('n/a', '—', '-', 'empty model') or s.startswith('empty'):
        return ''
    if 'scan' in s:
        return 'SCAN'
    if 'dirty' in s or 'soil' in s or 'stain' in s:
        return 'Dirty'
    # Must check "no crack" BEFORE "crack" — "No Crack Egg" contains the word crack.
    if 'no crack' in s or 'uncrack' in s or 'clean' in s or 'good' in s or 'no damage' in s:
        return 'Clean'
    if 'crack' in s or 'broken' in s:
        return 'Crack'
    if 'egg' in s:
        return 'Clean'
    return ''


def _overlay_live(frame, label: str, confidence: float, scores: dict | None = None, box=None, track_id: int = 0) -> bytes:
    vis = frame
    h, w = vis.shape[:2]
    # Downscale for faster encode / smoother live.jpg.
    if max(h, w) > 640:
        scale = 640.0 / float(max(h, w))
        vis = cv2.resize(frame, (int(w * scale), int(h * scale)))
        if box is not None:
            box = tuple(int(round(v * scale)) for v in box)
        h, w = vis.shape[:2]
    else:
        vis = frame.copy()
    title = _camera_label(label)
    # Always draw the track box when we have one (incl. Scanning) — live view needs it.
    if box is None:
        ok, buf = cv2.imencode('.jpg', vis, [int(cv2.IMWRITE_JPEG_QUALITY), 70])
        return buf.tobytes() if ok else b''
    if title not in ('Clean', 'Crack', 'Dirty', 'SCAN'):
        title = 'Clean' if track_id > 0 else (title or 'Clean')
    color = (70, 220, 90)  # Clean = green
    if title == 'Dirty':
        color = (40, 180, 255)
    elif title == 'Crack':
        color = (40, 40, 245)
    elif title == 'SCAN' or 'scan' in (label or '').lower():
        color = (80, 220, 255)
        title = 'SCAN'
    cv2.rectangle(vis, (0, 0), (w, 42), (18, 14, 12), -1)
    hud = title  # Clean / Crack / Dirty / SCAN — no TRACK #N (same egg ≠ new count)
    cv2.putText(
        vis, hud, (10, 28),
        cv2.FONT_HERSHEY_SIMPLEX, 0.75, color, 2, cv2.LINE_AA,
    )
    if box is not None:
        _draw_tracker(vis, box, color)
        x1, y1, _, _ = [int(round(v)) for v in box]
        tag = title
        if confidence and confidence > 1 and title != 'SCAN':
            tag = f'{title} {confidence:.0f}%'
        tw = max(80, len(tag) * 12)
        ty1 = max(48, y1 - 24)
        ty2 = ty1 + 22
        cv2.rectangle(vis, (x1, ty1), (min(w - 2, x1 + tw), ty2), color, -1)
        cv2.putText(
            vis, tag, (x1 + 4, ty2 - 5),
            cv2.FONT_HERSHEY_SIMPLEX, 0.55, (20, 16, 14), 2, cv2.LINE_AA,
        )
    ok, buf = cv2.imencode('.jpg', vis, [int(cv2.IMWRITE_JPEG_QUALITY), 72])
    return buf.tobytes() if ok else b''


def _ingest_jpeg(data: bytes) -> tuple[str, float, bool, bool, str, float]:
    global _last_count_at, _last_jpeg, _last_jpeg_at
    arr = np.frombuffer(data, dtype=np.uint8)
    full = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if full is None:
        return '', 0.0, False, False, '', 0.0
    global _egg_streak, _egg_lost

    # Detect on half-res (short GIL), track/shell on full-res boxes.
    fh, fw = full.shape[:2]
    if fw >= 240:
        small = cv2.resize(full, (max(1, fw // 2), max(1, fh // 2)), interpolation=cv2.INTER_AREA)
        sh, sw = small.shape[:2]
        sx = fw / float(sw)
        sy = fh / float(sh)

        def _up(box):
            x1, y1, x2, y2 = box
            return (
                int(round(x1 * sx)), int(round(y1 * sy)),
                int(round(x2 * sx)), int(round(y2 * sy)),
            )

        fresh = [_up(b) for b in _detect_egg_boxes(small)]
    else:
        fresh = _detect_egg_boxes(full)
    frame = full
    # 2) Always search near the predicted track when following — merge with fresh
    #    so a distant false detect cannot steal / drop a moving egg.
    with _track_lock:
        prev_box = _track['box']
        had_track = prev_box is not None and bool(_track.get('confirmed'))
    near = _search_egg_near(frame, prev_box) if had_track else []
    detect_cands = _merge_track_candidates(fresh, near) if had_track else list(fresh)

    # Soft JPEG over tunnel is blurry — looser shell gates so tracker can lock.
    egg_only: list = []
    shell_need = 0.14 if not had_track else 0.18
    for box in detect_cands:
        if _box_is_metal_or_belt(frame, box):
            continue
        if not _box_is_egg_shell(frame, box, min_shell=shell_need):
            continue
        if not _box_looks_like_egg(frame, box):
            continue
        egg_only.append(box)
    detect_cands = egg_only[:1]

    if detect_cands:
        _egg_streak += 1
        _egg_lost = 0
    else:
        _egg_streak = 0
        _egg_lost += 1

    # Need several solid egg frames before a NEW track (never one-frame glare/wood).
    can_start = _egg_streak >= EGG_CONFIRM_FRAMES
    # Empty belt: do not coast a fake track — drop as soon as oval is gone.
    if had_track and not detect_cands and _egg_lost >= EGG_LOST_GRACE:
        _clear_tracker()
        track_box, track_id = None, 0
        had_track = False
    if had_track:
        # Brief coast OK (egg still there if JPEG blinks); wood/metal kills immediately.
        track_box, track_id = _update_tracker(detect_cands, keep=True, frame=frame)
        if track_box is not None and (
            _box_is_metal_or_belt(frame, track_box)
            or _box_is_wood_board(frame, track_box)
            or (
                detect_cands
                and not _box_is_egg_shell(frame, track_box, min_shell=0.12)
            )
        ):
            _clear_tracker()
            track_box, track_id = None, 0
    elif can_start and detect_cands:
        track_box, track_id = _update_tracker(detect_cands, keep=False, frame=frame)
    else:
        track_box, track_id = None, 0
        if not had_track:
            _clear_tracker()

    with _track_lock:
        # Allow several miss frames so tunnel blinks do not drop DETECTING.
        tracking = (
            _track['box'] is not None
            and bool(_track.get('confirmed'))
            and (bool(detect_cands) or int(_track.get('miss') or 0) < 6)
        )
        if tracking:
            track_box = _track['box']
            track_id = int(_track['id'] or 0)
        else:
            track_box = None
            track_id = 0
            if not detect_cands and int(_track.get('miss') or 0) >= 6:
                _track['confirmed'] = False
                _track['box'] = None

    # Egg-only gate for count/detect — never scan belt/wood/metal as an egg.
    # Soft shell fill (0.22) so a just-arrived egg is not dropped on glare.
    egg_visual = bool(
        tracking
        and track_box is not None
        and _box_is_egg_shell(frame, track_box, min_shell=0.12)
        and not _box_is_metal_or_belt(frame, track_box)
        and not _box_is_wood_board(frame, track_box)
    )
    if tracking and not egg_visual:
        _clear_tracker()
        track_box, track_id = None, 0
        tracking = False
    shaped_now = [tuple(int(round(v)) for v in track_box)] if egg_visual else []

    # Never run TF before the egg is locked — TF was blocking first detect.
    # Default CLASSIFY_TF=0: shell vision only (smooth live over tunnel).
    global _classify_tick
    _classify_tick += 1
    # Skip paint encode on live path — re-JPEG made motion look late. HUD uses
    # live-status; pixels stay the newest raw CAM push.
    # During the 5s scan, run crack/dirty nets often enough to vote.
    run_model = bool(CLASSIFY_TF) and bool(egg_visual) and (_classify_tick % 4 == 1)
    label = str(metrics.get('lastLabel') or 'Empty Model')
    confidence = float(metrics.get('lastConfidence') or 0.0)
    scores: dict = {}
    boxes = shaped_now
    if run_model:
        try:
            if signature is None:
                raise RuntimeError('model signature not loaded')
            label, confidence, scores, boxes = classify_frame(
                frame, shaped_now[0] if shaped_now else None,
            )
        except Exception as exc:
            # Never abort egg tracking because TF failed — HUD would stick on waiting egg.
            if _classify_tick % 30 == 1:
                print(f'[classify] skip (vision-only): {exc}', flush=True)
            scores = {}
            boxes = shaped_now
    global _last_seen_egg, _egg_in_view, _clean_hold_until, _reject_hold_until
    seen = False
    picked = 'Empty Model'
    pconf = 0.0
    scanning = False
    shown = ''
    reject = False
    identified = False
    cat = None

    if egg_visual:
        seen = True  # oval on belt already confirmed by detector + tracker
        _egg_in_view = True
        _last_seen_egg = True
        with _egg_pipe_lock:
            scale_busy = bool(_egg_pipe.get('awaiting_weight'))
            opened_at = float(_egg_pipe.get('opened_at') or 0.0)
        # Always run shell scan while locked — sticky scale-await used to skip
        # this and freeze DETECTING. _commit_camera_detection still dedupes.
        if scale_busy and opened_at and (time.monotonic() - opened_at) > AWAIT_WEIGHT_TIMEOUT_SEC:
            with _egg_pipe_lock:
                _egg_pipe['awaiting_weight'] = False
                _egg_pipe['id'] = ''
            scale_busy = False
            print('[egg] cleared awaiting_weight during view — resuming detect', flush=True)
        raw_good, raw_crack, raw_dirty = _score_buckets(scores)
        shell = _shell_quality(frame, shaped_now[0]) if shaped_now else ''
        # Model-only dirty/crack when shell vision is unsure (soft JPEG).
        if shaped_now and shell == '':
            if (
                raw_crack >= CRACK_SCORE_MIN
                and raw_crack >= raw_dirty + 5.0
                and raw_crack >= raw_good + 8.0
            ):
                shell = 'crack'
            elif (
                raw_dirty >= DIRTY_SCORE_MIN
                and raw_dirty >= raw_crack + 5.0
                and raw_dirty >= raw_good + 8.0
            ):
                shell = 'dirty'
        # Shell vision + model scores feed Clean / Crack / Dirty.
        if shell and not scores:
            scores = _apply_shell({}, shell)
        elif shell:
            scores = _apply_shell(scores, shell)
        picked, pconf = _scan_egg(True, scores, shell)
        scanning = picked == 'Scanning'
        commit_now = False
        commit_label = ''
        commit_conf = 0.0
        with _scan_lock:
            if _scan['decided']:
                picked = _scan['decided']
                pconf = max(pconf, 80.0)
                _scan['last_seen'] = time.monotonic()
                scanning = False
                if not _scan.get('committed'):
                    _scan['committed'] = True
                    commit_now = True
                    commit_label = picked
                    commit_conf = pconf
            elif _scan['start'] > 0.0:
                picked = 'Scanning'
                scanning = True
        if commit_now:
            _commit_camera_detection(commit_label, commit_conf)
        if scanning or is_empty_frame(picked) or picked == 'Waiting Scale':
            picked = 'Scanning' if scanning else ('Waiting Scale' if picked == 'Waiting Scale' else 'Egg')
            pconf = max(pconf, 1.0)
        cat = counting_category(picked)
        reject = cat == 'crackedEggs'
        identified = cat in ('crackedEggs', 'dirtyEggs', 'goodEggs')
        if cat == 'crackedEggs':
            metrics['lastLabel'] = 'Crack Egg'
            picked = 'Crack Egg'
        elif cat == 'dirtyEggs':
            metrics['lastLabel'] = 'Dirty Egg'
            picked = 'Dirty Egg'
        elif cat == 'goodEggs':
            metrics['lastLabel'] = 'Clean Egg'
            picked = 'Clean Egg'
        else:
            metrics['lastLabel'] = 'Scanning' if scanning else picked
        metrics['lastConfidence'] = round(max(pconf, 1.0), 1)
        shown = _camera_label(picked) or ('Waiting' if picked == 'Waiting Scale' else 'Clean')
        # Do NOT attach weight while the egg is still in the camera FOV.
        # Grams must come from DevKit POST /weight after the egg reaches the pad.
    else:
        with _scan_lock:
            _reset_scan()
        # Egg left the frame — free the pipe so the next egg can record once.
        # Keep the open Good record only while it is waiting on the load cell.
        with _egg_pipe_lock:
            if not _egg_pipe.get('awaiting_weight'):
                _egg_pipe['id'] = ''
                _egg_pipe['camera'] = ''
                _egg_pipe['category'] = ''
                _egg_pipe['weighed'] = False
                _egg_pipe['opened_at'] = 0.0
        _last_seen_egg = False
        _egg_in_view = False
        # End GATE hold as soon as the egg leaves the frame.
        _clean_hold_until = 0.0
        _reject_hold_until = 0.0
        # Keep the committed Clean/Crack label for Live Inspection while scale waits.
        with _egg_pipe_lock:
            still_waiting = bool(_egg_pipe.get('awaiting_weight'))
            pipe_cam = str(_egg_pipe.get('camera') or '')
        if still_waiting and pipe_cam:
            if 'crack' in pipe_cam.lower():
                shown = 'Crack Egg'
            else:
                shown = 'Clean Egg'
            picked = shown
            pconf = max(pconf, 80.0)
        else:
            metrics['lastLabel'] = 'Empty Model'
            metrics['lastConfidence'] = 0.0

    # Live pixels come only from /api/frame → _store_live_jpeg. Never re-encode
    # here (paint/TF) or moving eggs look lagged on /watch.
    global _classify_n
    with _raw_lock:
        fresh_raw = _last_raw or bytes(data)
    with _jpeg_lock:
        _last_jpeg = fresh_raw
        _last_jpeg_at = time.monotonic()
    _apply_inspect_frame(picked, pconf, scores)
    metrics['status'] = 'Running'
    metrics['connected'] = True
    # Never wipe a pending Clean record back to N/A when the egg leaves FOV.
    with _egg_pipe_lock:
        keep_pending = bool(_egg_pipe.get('awaiting_weight')) and str(
            _egg_pipe.get('camera') or ''
        )
    if shown:
        metrics['lastLabel'] = shown
    elif keep_pending:
        cam = str(keep_pending)
        if 'crack' in cam.lower():
            metrics['lastLabel'] = 'Crack Egg'
        else:
            metrics['lastLabel'] = 'Clean Egg'
    else:
        metrics['lastLabel'] = 'N/A'
    _classify_n += 1
    if _classify_n == 1 or _classify_n % 8 == 0:
        with _egg_pipe_lock:
            pipe = f'{_egg_pipe.get("camera") or "-"}/await={_egg_pipe.get("awaiting_weight")}'
        print(
            f'[frame] camera={picked or "—"!r} model={label!r} egg={seen} '
            f'box={"yes" if track_box is not None else "no"} '
            f'detect={len(fresh)} streak={_egg_streak} pipe={pipe}',
            flush=True,
        )
    # Counts happen in _commit_camera_detection; weight attaches separately.
    return label, confidence, reject, identified, picked, pconf


def _stream_url(jpg_url: str) -> str:
    u = (jpg_url or '').strip().rstrip('/')
    if u.endswith('/mjpeg'):
        return u
    if u.endswith('/jpg'):
        return u[:-4] + '/jpg'
    if u.endswith('/stream'):
        return u[:-7] + '/jpg'
    return u + '/jpg'


def grab_worker():
    """Internet / tunnel mode: wait for CAM HTTPS POST /api/frame only.

    Extender AP isolation blocks PC→CAM :82 pulls. Pulling just wastes time and
    made the dashboard show Connecting camera… / frozen frames.
    """
    push_only = os.environ.get('CAM_PUSH_ONLY', '1').strip() not in ('0', 'false', 'no')
    if push_only:
        print('[worker] live = INTERNET CAM PUSH only (no LAN :82 pull)', flush=True)
        stale_log_at = 0.0
        while True:
            try:
                with _raw_lock:
                    raw_age = (time.monotonic() - _last_raw_at) if _last_raw_at else 999.0
                if raw_age < 2.0:
                    time.sleep(0.15)
                    continue
                now = time.monotonic()
                if now - stale_log_at > 8.0:
                    stale_log_at = now
                    print(
                        f'[worker] waiting for CAM tunnel POST /api/frame '
                        f'(age={raw_age:.1f}s) — keep cloudflared + CAM online',
                        flush=True,
                    )
                time.sleep(0.5)
            except Exception as exc:
                print(f'[worker] grab_worker recovered: {exc}', flush=True)
                time.sleep(0.5)
        return

    print('[worker] live = CAM PUSH; pull :82 when frames go stale', flush=True)
    global _cam_pick
    fail = 0
    sess = requests.Session()
    adapter = HTTPAdapter(pool_connections=1, pool_maxsize=1, max_retries=0)
    sess.mount('http://', adapter)
    while True:
        try:
            with _raw_lock:
                raw_age = (time.monotonic() - _last_raw_at) if _last_raw_at else 999.0
            if raw_age < 2.0:
                time.sleep(0.2)
                continue
            jpg_url = _jpg_url(_grab_urls()[_cam_pick % len(_grab_urls())])
            try:
                r = sess.get(jpg_url, timeout=(0.4, 0.8), headers={'Connection': 'close'})
                body = r.content or b''
                if r.status_code == 200 and len(body) >= 200 and body[:2] == b'\xff\xd8':
                    _store_live_jpeg(body)
                    fail = 0
                    time.sleep(0.08)
                    continue
                raise RuntimeError(f'bad jpg {r.status_code} {len(body)}')
            except Exception as exc:
                fail += 1
                if fail == 1 or fail % 15 == 0:
                    print(
                        f'[worker] no CAM frames (push dead / :82 blocked): {exc}',
                        flush=True,
                    )
                if fail % 6 == 0:
                    _discover_cam_async()
                    _cam_pick += 1
                time.sleep(1.0)
        except Exception as exc:
            print(f'[worker] grab_worker recovered: {exc}', flush=True)
            time.sleep(0.5)


def _paint_view_fast(raw: bytes) -> bytes:
    """Draw track box + label when an egg is locked. Empty belt returns RAW (no lag)."""
    with _track_lock:
        box = _track.get('box')
        track_id = int(_track.get('id') or 0)
        tracking = box is not None and bool(_track.get('confirmed'))
    if not tracking or box is None:
        return raw
    title = str(metrics.get('lastLabel') or 'Egg')
    scanning, _ = _scan_active()
    try:
        arr = np.frombuffer(raw, dtype=np.uint8)
        vis = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if vis is None:
            return raw
        low = (title or '').lower().strip()
        color = (80, 220, 255)
        name = 'EGG'
        # Do not use "'scan' in low" — it matched "Waiting Scale" and showed DETECT #N.
        if scanning or low in ('scanning', 'egg', 'empty model', 'empty'):
            name, color = 'DETECT', (80, 220, 255)
        elif 'dirty' in low:
            name, color = 'DIRTY', (40, 180, 255)
        elif 'clean' in low or 'no crack' in low:
            name, color = 'CLEAN', (70, 220, 90)
        elif 'crack' in low:
            name, color = 'CRACK', (40, 40, 245)
        # Never paint TRACK #N — that ID climbs when the same egg is re-locked
        # (blink / FOV wobble), so 1 egg looked like "4 detections".
        _draw_tracker(vis, box, color)
        x1, y1 = int(box[0]), int(box[1])
        cv2.putText(
            vis, name, (max(4, x1), max(18, y1 - 6)),
            cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2, cv2.LINE_AA,
        )
        # Soft encode — watch smoothness > overlay sharpness.
        ok, buf = cv2.imencode('.jpg', vis, [int(cv2.IMWRITE_JPEG_QUALITY), 55])
        return buf.tobytes() if ok else raw
    except Exception:
        return raw


def _publish_view(raw: bytes, seq: int | None = None, paint: bool = False) -> None:
    """Publish newest camera bytes for /watch — raw first for zero lag."""
    global _view_jpeg, _view_seq
    out = _paint_view_fast(raw) if paint else raw
    with _view_lock:
        if seq is not None and seq < _view_seq:
            return
        _view_jpeg = out
        _view_seq = int(seq) if seq is not None else (_view_seq + 1)


_sane_tick = 0


def _jpeg_frame_sane(jpg: bytes, deep: bool = False) -> bool:
    """Fast EOI check always; full magenta decode only occasionally (deep=True)."""
    if not jpg or len(jpg) < 200 or jpg[:2] != b'\xff\xd8':
        return False
    if b'\xff\xd9' not in jpg[-96:]:
        return False
    if not deep:
        return True
    try:
        fr = cv2.imdecode(np.frombuffer(jpg, dtype=np.uint8), cv2.IMREAD_COLOR)
    except Exception:
        return False
    if fr is None or getattr(fr, 'size', 0) == 0:
        return False
    h, w = fr.shape[:2]
    if h < 40 or w < 40:
        return False
    # Classic OV2640 brownout: huge magenta/purple slab, almost no green.
    b, g, r = cv2.split(fr)
    mag = float(
        ((r.astype(np.int16) > 155) & (b.astype(np.int16) > 155) & (g.astype(np.int16) < 95)).mean()
    )
    if mag > 0.16:
        return False
    if float(fr.std()) < 6.5:
        return False
    return True


def _store_live_jpeg(jpg: bytes) -> None:
    global _last_raw, _last_raw_at, _preview, _preview_at, _raw_seq, _sane_tick
    if not jpg or len(jpg) < 200 or jpg[:2] != b'\xff\xd8':
        return
    # Hot path (often on asyncio): EOI only. Deep magenta decode belongs in
    # classify_worker — never on /api/frame or the event loop wedges.
    _sane_tick += 1
    if not _jpeg_frame_sane(jpg, deep=False):
        return
    now = time.monotonic()
    with _raw_lock:
        _last_raw = jpg
        _last_raw_at = now
        _preview = jpg
        _preview_at = now
        _raw_seq += 1
        seq = _raw_seq
    # Always publish RAW on the CAM push path — paint/decode here stalled HTTP
    # and made the egg look late on /live.jpg while the CAM waited for 200 OK.
    _publish_view(jpg, seq, paint=False)
    if seq == 1 or seq % 40 == 0:
        print(f'[live] got JPEG {len(jpg)}B from CAM (seq={seq})', flush=True)


def classify_worker():
    """Classify newest frame only. Skip stale frames so live view does not lag.

    TF predict holds the GIL and freezes uvicorn's event loop in-process.
    Cap each tick and always sleep afterward so /live.jpg stays reachable.
    """
    enabled = os.environ.get('CLASSIFY_ENABLED', '1').strip().lower() not in (
        '0', 'false', 'no',
    )
    if not enabled:
        print('[worker] classify DISABLED (CLASSIFY_ENABLED=0) — live view only', flush=True)
        while True:
            time.sleep(2.0)
            with _raw_lock:
                raw_at = _last_raw_at
            age = (time.monotonic() - raw_at) if raw_at else 999.0
            if age >= TRACK_STALE_CLEAR_SEC:
                _clear_tracker()
        return
    last = b''
    last_seq = -1
    while True:
        with _raw_lock:
            data = _last_raw
            seq = _raw_seq
            raw_at = _last_raw_at
        age = (time.monotonic() - raw_at) if raw_at else 999.0
        if age >= TRACK_STALE_CLEAR_SEC:
            _clear_tracker()
        if not data or data is last or seq == last_seq:
            time.sleep(0.01)
            continue
        # Drop backlog: if many frames arrived while TF ran, jump to newest.
        last = data
        last_seq = seq
        t0 = time.monotonic()
        try:
            _ingest_jpeg(data)
            # Do NOT paint over live view — decode/draw made the egg look late.
            # Live pixels stay the newest raw from /api/frame only.
        except Exception as exc:
            print(f'[worker] classify fail: {exc}', flush=True)
        took = time.monotonic() - t0
        heavy = bool(CLASSIFY_TF) and took >= 0.12
        # After classify, prefer the freshest raw (do not process a queue of old frames).
        with _raw_lock:
            if _raw_seq != last_seq:
                last = b''  # force take newest next loop
                if heavy:
                    time.sleep(min(1.0, CLASSIFY_HEAVY_SLEEP_SEC))
                continue
        if heavy:
            time.sleep(min(1.0, CLASSIFY_HEAVY_SLEEP_SEC))
        else:
            time.sleep(CLASSIFY_SLEEP_SEC)


def stream_worker():
    grab = threading.Thread(target=grab_worker, daemon=True)
    clf = threading.Thread(target=classify_worker, daemon=True)
    grab.start()
    clf.start()
    grab.join()


@app.get('/')
def root():
    payload = _public_metrics()
    return {
        'ok': True,
        'service': 'egg-system',
        'engine': 'fastapi',
        'message': 'Egg System backend is running. Open the Flutter app, not this URL.',
        'health': '/health',
        'metrics': '/metrics',
        'authHealth': '/auth/health',
        'docs': '/docs',
        'connected': payload['connected'],
        'hardwareOnline': payload['hardwareOnline'],
        'status': payload['status'],
    }


_NO_STORE = {
    'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
    'Pragma': 'no-cache',
    'Expires': '0',
}


@app.get('/metrics')
def get_metrics():
    return JSONResponse(_public_metrics(), headers=_NO_STORE)


def _hardware_status_response(body: dict | None = None):
    global _pending_weight, _last_live_weight_at, _clean_hold_until, _reject_hold_until
    global _cam_hb_jpg
    body = body or {}
    device = str(body.get('device') or 'ESP32-CAM')
    status = str(body.get('status') or 'ONLINE').upper()
    stream_url = str(body.get('streamUrl') or '')
    jpg_url = str(body.get('jpgUrl') or '')
    try:
        cam_jpg = int(body.get('jpg') if body.get('jpg') is not None else -1)
    except (TypeError, ValueError):
        cam_jpg = -1
    if cam_jpg >= 0:
        with _cam_hb_jpg_lock:
            _cam_hb_jpg = cam_jpg
    _set_cam_zoom(body.get('zoom', 1.0))
    if status in ('ONLINE', 'OK', 'ACTIVE', '1', 'TRUE'):
        _note_heartbeat(device, stream_url)
    # Only adopt a camera URL after a live JPEG probe. A DevKit mis-flashed as
    # CAM (e.g. 192.168.11.152) used to overwrite the real CAM and black out /watch.
    if 'devkit' not in device.lower():
        cand = jpg_url if jpg_url.startswith('http') else (
            stream_url if stream_url.startswith('http') else ''
        )
        if cand:
            _adopt_cam_jpg(cand, reason=device)
        # CAM has JPEG bytes but /api/frame push may be stalled → try :82 now.
        _maybe_pull_on_heartbeat(cand if cand else jpg_url, cam_jpg)
    # Live load-cell grams from ESP32 heartbeat → show on dashboard immediately.
    grams = body.get('weightGrams')
    if isinstance(grams, (int, float)):
        grams = correct_scale_grams(float(grams))
        if grams < 5.0:
            if time.monotonic() - _last_live_weight_at >= 5.0:
                metrics['lastWeightGrams'] = 0.0
                metrics['lastSizeClass'] = 'N/A'
                with _weight_lock:
                    _pending_weight = None
        elif grams >= 8.0:
            # Live pad readout only — never attach here. Heartbeat grams often
            # exist before the egg leaves the camera / reaches the cell; attaching
            # would fill the Clean row with stale residual weight.
            _last_live_weight_at = time.monotonic()
            size = classify_size(grams) if grams <= 150.0 else 'jumbo'
            with _egg_pipe_lock:
                awaiting = bool(_egg_pipe.get('awaiting_weight'))
            if awaiting:
                # Keep HUD on "waiting for weight" until commitEgg /weight.
                metrics['status'] = f'Waiting for pad lock — scale live {grams:g} g'
            else:
                metrics['lastWeightGrams'] = grams
                metrics['lastSizeClass'] = size
                metrics['lastMeasurementStatus'] = 'uncalibrated'
                metrics['status'] = f'Scale live {grams:g} g'
    payload = _public_metrics()
    if stream_url:
        print(
            f"[heartbeat] streamUrl={stream_url} cam={body.get('cam')} "
            f"jpg={body.get('jpg')} h={body.get('h')} p={body.get('p')}",
            flush=True,
        )
    global _pending_servo_test
    servo_test = False
    with _pending_servo_lock:
        if _pending_servo_test:
            servo_test = True
            _pending_servo_test = False
            print('[servo] queued push → ESP on this heartbeat', flush=True)
    label = str(payload.get('lastLabel') or '')
    conf = float(payload.get('lastConfidence') or 0)
    cat = counting_category(label)
    hb_g = 0.0
    raw_g = body.get('weightGrams')
    if isinstance(raw_g, (int, float)):
        hb_g = correct_scale_grams(float(raw_g))
    now = time.monotonic()
    # GATE cues follow the camera FOV: Clean/Crack only while egg is still seen.
    # awaiting_weight must NOT keep cleanEgg after the egg leaves — GATE returns
    # middle when FOV clears; pad weigh stays armed on the DevKit separately.
    reject_egg = now < _reject_hold_until
    clean_egg = (now < _clean_hold_until) and not reject_egg
    egg_seen = bool(_egg_in_view)
    scanning, scan_left = _scan_active()
    with _egg_pipe_lock:
        pipe_id = str(_egg_pipe.get('id') or '')
        pipe_cam = str(_egg_pipe.get('camera') or '')
        awaiting_weight = bool(_egg_pipe.get('awaiting_weight'))
        opened_at = float(_egg_pipe.get('opened_at') or 0.0)
        # Short timeout so live detect/tracker is not stuck on "Clean / wait scale".
        if awaiting_weight and opened_at and (now - opened_at) > AWAIT_WEIGHT_TIMEOUT_SEC:
            timed_id = pipe_id
            _egg_pipe['awaiting_weight'] = False
            _egg_pipe['id'] = ''
            awaiting_weight = False
            pipe_id = ''
            for rec in detection_records:
                if str(rec.get('id') or '') == timed_id:
                    rec['awaitingWeight'] = False
                    if rec.get('weightGrams') is None:
                        rec['sizeClass'] = 'pending'
                    break
            _save_live_detections()
            print(
                f'[egg] awaiting_weight timed out ({AWAIT_WEIGHT_TIMEOUT_SEC:.0f}s) '
                '— next egg may detect',
                flush=True,
            )
    if egg_seen and awaiting_weight and pipe_cam:
        pl = pipe_cam.lower()
        if 'crack' in pl or 'dirty' in pl:
            reject_egg = True
            clean_egg = False
        else:
            clean_egg = True
            reject_egg = False
    if not egg_seen:
        # Egg left camera → drop GATE hold cues (scale pipe may still await grams).
        clean_egg = False
        reject_egg = False
    # HUD can show Clean while pipe briefly lags — still cue GATE from lastLabel.
    if egg_seen and not clean_egg and not reject_egg:
        low_lbl = (label or '').lower()
        if 'clean' in low_lbl or 'no crack' in low_lbl:
            clean_egg = True
    if reject_egg:
        cam_result = 'Crack' if 'dirty' not in (pipe_cam or label).lower() else 'Dirty'
        if 'dirty' in (pipe_cam or label).lower():
            cam_result = 'Dirty'
        sort_result = 'Reject'
    elif clean_egg:
        cam_result = 'Clean'
        sort_result = 'Good'
    elif scanning:
        cam_result = 'Scanning'
        sort_result = 'Good'
    else:
        cam_result = 'Pending'
        sort_result = 'Good'
    # DevKit only needs gate flags — tiny body avoids ESP32 lwIP pbuf_free crashes.
    if 'devkit' in device.lower():
        # cleanEgg drives GATE only while the egg is still in FOV.
        # weighArm stays true after FOV clear so HX711 can still lock grams.
        # Dirty/dust folds to Clean — still arm the pad (only Crack skips weigh).
        weigh_arm = bool(
            awaiting_weight
            and pipe_cam
            and 'crack' not in pipe_cam.lower()
        )
        return {
            'ok': True,
            'scanning': scanning,
            'rejectEgg': reject_egg,
            'cleanEgg': clean_egg,  # GATE while eggSeen
            'weighArm': weigh_arm,  # pad auto-weigh after Clean commit
            'awaitingWeight': weigh_arm,
            'cameraResult': cam_result if (egg_seen or weigh_arm) else (
                'Clean' if weigh_arm else cam_result
            ),
            'sortingResult': sort_result,
            'servoTest': servo_test,
            'eggSeen': egg_seen,
        }
    return {
        'ok': True,
        'hardwareOnline': payload['hardwareOnline'],
        'device': payload['hardwareDevice'],
        'connected': payload['connected'],
        'status': payload['status'],
        'lastWeightGrams': payload.get('lastWeightGrams', 0),
        'lastSizeClass': payload.get('lastSizeClass', 'N/A'),
        'lastLabel': payload.get('lastLabel', 'N/A'),
        'lastConfidence': payload.get('lastConfidence', 0),
        'eggSeen': egg_seen,
        'eggInView': egg_seen,
        'scanning': scanning,
        'scanLeft': scan_left,
        'rejectEgg': reject_egg,
        'cleanEgg': clean_egg,
        'cameraResult': cam_result,
        'sortingResult': sort_result,
        'pendingEggId': pipe_id,
        'awaitingWeight': awaiting_weight,
        # Do NOT send crackedEggs/dirtyEggs here — old DevKit firmware matched
        # substring "crack"/"dirty" inside those keys and held GATE on reject forever.
        'okEggs': payload.get('goodEggs', 0),
        'badEggs': payload.get('crackedEggs', 0),
        'soilEggs': payload.get('dirtyEggs', 0),
        'servoTest': servo_test,
    }


@app.get('/api/gate-cue')
def api_gate_cue():
    """Tiny Clean/Crack flags for DevKit when POST /api/status reply is dropped on weak Wi‑Fi."""
    now = time.monotonic()
    reject_egg = now < _reject_hold_until
    clean_egg = (now < _clean_hold_until) and not reject_egg
    egg_seen = bool(_egg_in_view)
    scanning, _scan_left = _scan_active()
    label = str(metrics.get('lastLabel') or '')
    with _egg_pipe_lock:
        pipe_cam = str(_egg_pipe.get('camera') or '')
        awaiting_weight = bool(_egg_pipe.get('awaiting_weight'))
    if egg_seen and awaiting_weight and pipe_cam:
        pl = pipe_cam.lower()
        if 'crack' in pl or 'dirty' in pl:
            reject_egg, clean_egg = True, False
        else:
            clean_egg, reject_egg = True, False
    if not egg_seen:
        clean_egg = False
        reject_egg = False
    if egg_seen and not clean_egg and not reject_egg:
        low_lbl = (label or '').lower()
        if 'clean' in low_lbl or 'no crack' in low_lbl:
            clean_egg = True
    weigh_arm = bool(
        awaiting_weight
        and pipe_cam
        and 'crack' not in pipe_cam.lower()
    )
    if reject_egg:
        cam_result = 'Dirty' if 'dirty' in (pipe_cam or label).lower() else 'Crack'
    elif clean_egg or weigh_arm:
        cam_result = 'Clean'
    elif scanning:
        cam_result = 'Scanning'
    else:
        cam_result = 'Pending'
    return {
        'ok': True,
        'scanning': scanning,
        'rejectEgg': reject_egg,
        'cleanEgg': clean_egg,
        'weighArm': weigh_arm,
        'awaitingWeight': weigh_arm,
        'cameraResult': cam_result,
        'eggSeen': egg_seen,
    }


@app.api_route('/api/servo-test', methods=['POST', 'GET'])
def api_servo_test():
    """Queue one servo push; ESP runs it on the next heartbeat."""
    global _pending_servo_test
    with _pending_servo_lock:
        _pending_servo_test = True
    print('[servo] test requested — waiting for ESP heartbeat', flush=True)
    return {'ok': True, 'queued': True, 'hint': 'ESP moves on next heartbeat (~2s)'}


@app.post('/api/station-selftest')
def api_station_selftest(request: Request):
    """Local check: camera Clean count → same-egg weight attach (no hardware)."""
    if not _is_private_ip(_client_ip(request)):
        return JSONResponse({'error': 'private LAN only'}, status_code=403)
    # Clear any stuck open pipe so the test is clean.
    with _egg_pipe_lock:
        _egg_pipe['id'] = ''
        _egg_pipe['awaiting_weight'] = False
    rid = _commit_camera_detection('Clean Egg', 90.0)
    if not rid:
        return {'ok': False, 'error': 'camera commit failed'}
    linked = _attach_scale_to_camera_egg(
        55.0, 'medium', measurement_status='simulated', device_id='selftest',
    )
    crack = _commit_camera_detection('Crack Egg', 88.0)
    return {
        'ok': True,
        'cleanEggId': rid,
        'weightLinkedId': linked,
        'weightLinked': linked == rid,
        'crackEggId': crack,
        'goodEggs': metrics.get('goodEggs'),
        'crackedEggs': metrics.get('crackedEggs'),
        'dirtyEggs': metrics.get('dirtyEggs'),
        'hardwareOnline': _hardware_online(),
        'camConnected': bool(metrics.get('connected')),
        'hint': (
            'Software path OK. Power ESP32-CAM + DevKit on same Wi-Fi; '
            'flash EGG_DEVKIT 0=CAM, 1=DevKit.'
        ),
    }


@app.api_route('/api/status', methods=['GET', 'POST'])
async def api_status(request: Request):
    if request.method == 'POST':
        try:
            body = await request.json()
        except Exception:
            body = {}
        return _hardware_status_response(body if isinstance(body, dict) else {})
    payload = _public_metrics()
    return {
        'connected': payload['connected'],
        'hardwareOnline': payload['hardwareOnline'],
        'status': payload['status'],
        'lastLabel': payload['lastLabel'],
        'lastConfidence': payload['lastConfidence'],
    }


@app.api_route('/api/inspect', methods=['GET', 'POST'])
async def api_inspect(request: Request):
    """ESP32 calls POST when the IR has stopped an egg, then GET until ready."""
    try:
        return _api_inspect(request.method)
    except Exception:
        import traceback
        _log('[inspect] ' + traceback.format_exc().strip().splitlines()[-1])
        return {
            'ok': True,
            'ready': False,
            'reject': False,
            'label': '',
            'eggSeen': False,
        }


def _api_inspect(method: str = 'GET'):
    with _inspect_lock:
        if method == 'POST':
            _inspect['waiting'] = True
            _inspect['ready'] = False
            _inspect['reject'] = False
            _inspect['label'] = ''
            _inspect['asked_at'] = time.time()
            _inspect['best_good'] = 0.0
            _inspect['best_crack'] = 0.0
            _inspect['best_dirty'] = 0.0
            _inspect['saw_egg'] = False
            _station_vote.clear()
            _seed_inspect_from_live()
            if _egg_in_view:
                _inspect['saw_egg'] = True
            if time.monotonic() - _last_raw_at > 2.0:
                _discover_cam_async()
            _log('[inspect] egg held — camera scan')
            return {
                'ok': True,
                'ready': _inspect['ready'],
                'reject': _inspect['reject'],
                'label': _inspect['label'],
                'eggSeen': bool(_egg_in_view),
            }

        if (
            _inspect['waiting']
            and not _inspect['ready']
            and time.time() - _inspect['asked_at'] > INSPECT_GIVE_UP_SEC
        ):
            if not _inspect.get('saw_egg') and not _egg_in_view:
                _inspect['reject'] = False
                _inspect['label'] = ''
                _inspect['ready'] = False
                _inspect['waiting'] = False
            else:
                if _inspect['best_crack'] > 0.0:
                    _inspect['reject'] = True
                    _inspect['label'] = 'Crack Egg'
                elif _inspect['best_dirty'] >= DIRTY_SCORE_MIN:
                    _inspect['reject'] = True
                    _inspect['label'] = 'Dirty Egg'
                else:
                    _inspect['reject'] = False
                    _inspect['label'] = 'No Crack Egg'
                _inspect['ready'] = True
                _inspect['waiting'] = False
        return {
            'ok': True,
            'ready': _inspect['ready'],
            'reject': _inspect['reject'],
            'label': _inspect['label'],
            'eggSeen': bool(_egg_in_view),
        }


@app.api_route('/status', methods=['GET', 'POST'])
async def get_status(request: Request):
    if request.method == 'POST':
        try:
            body = await request.json()
        except Exception:
            body = {}
        return _hardware_status_response(body if isinstance(body, dict) else {})
    payload = _public_metrics()
    return {
        'connected': payload['connected'],
        'hardwareOnline': payload['hardwareOnline'],
        'status': payload['status'],
        'lastLabel': payload['lastLabel'],
        'lastConfidence': payload['lastConfidence'],
        'goodEggs': payload.get('goodEggs', 0),
        'crackedEggs': payload.get('crackedEggs', 0),
        'dirtyEggs': payload.get('dirtyEggs', 0),
        'lastWeightGrams': payload.get('lastWeightGrams', 0),
        'lastSizeClass': payload.get('lastSizeClass', 'N/A'),
    }


@app.get('/debug')
def get_debug_info():
    return {'metrics': metrics, 'debug': debug_info}


@app.get('/records')
def get_records():
    """Return the last MAX_RECORDS confirmed detections in reverse-chronological
    order (newest first), skipping 'Empty Model' and low-confidence frames."""
    return JSONResponse(list(reversed(detection_records)), headers=_NO_STORE)


def _merge_detection_rows(incoming: list) -> int:
    """Merge browser/cache rows into the farm board (by id). Returns added count."""
    if not incoming:
        return 0
    by_id: dict[str, dict] = {}
    for row in detection_records:
        if isinstance(row, dict) and row.get('id'):
            by_id[str(row['id'])] = dict(row)
    added = 0
    for item in incoming:
        if not isinstance(item, dict):
            continue
        rid = str(item.get('id') or '').strip()
        if not rid:
            # Stable fallback from timestamp+label so refresh rows still merge.
            ts = str(item.get('timestamp') or '')
            lab = str(item.get('label') or '')
            rid = f'cache-{ts}-{lab}'.replace(' ', '_')
            item = dict(item)
            item['id'] = rid
        lab = str(item.get('label') or 'Clean')
        cat = str(item.get('category') or '')
        if not cat:
            low = lab.lower()
            if 'crack' in low and 'no crack' not in low:
                cat = 'crackedEggs'
            elif 'dirty' in low or 'soil' in low or 'stain' in low:
                cat = 'dirtyEggs'
            else:
                cat = 'goodEggs'
        row = {
            'id': rid,
            'timestamp': str(item.get('timestamp') or time.strftime('%Y-%m-%d %H:%M:%S')),
            'label': lab if lab else 'Clean',
            'confidence': float(item.get('confidence') or 80.0),
            'category': cat,
            'weightGrams': item.get('weightGrams'),
            'sizeClass': item.get('sizeClass') or (
                'pending' if item.get('awaitingWeight') else 'N/A'
            ),
            'awaitingWeight': bool(item.get('awaitingWeight')),
        }
        prev = by_id.get(rid)
        if prev is None:
            added += 1
            by_id[rid] = row
        else:
            # Keep newer weight if cache finally got grams.
            merged = dict(prev)
            if row.get('weightGrams') is not None and (
                prev.get('weightGrams') is None
                or float(prev.get('weightGrams') or 0) < 5.0
            ):
                merged['weightGrams'] = row['weightGrams']
                merged['sizeClass'] = row.get('sizeClass') or merged.get('sizeClass')
                merged['awaitingWeight'] = bool(row.get('awaitingWeight'))
            by_id[rid] = merged
    # Chronological (oldest → newest) so reverse() on GET stays newest-first.
    ordered = sorted(
        by_id.values(),
        key=lambda r: str(r.get('timestamp') or ''),
    )
    if len(ordered) > MAX_RECORDS:
        ordered = ordered[-MAX_RECORDS:]
    detection_records.clear()
    detection_records.extend(ordered)
    good_n = 0
    crack_n = 0
    dirty_n = 0
    for row in detection_records:
        cat = str(row.get('category') or '').lower()
        lab = str(row.get('label') or '').lower()
        if cat == 'crackedeggs' or ('crack' in lab and 'no crack' not in lab):
            crack_n += 1
        elif cat == 'dirtyeggs' or 'dirty' in lab or 'soil' in lab or 'stain' in lab:
            dirty_n += 1
        else:
            good_n += 1
    metrics['goodEggs'] = max(int(metrics.get('goodEggs') or 0), good_n)
    metrics['crackedEggs'] = max(int(metrics.get('crackedEggs') or 0), crack_n)
    metrics['dirtyEggs'] = max(int(metrics.get('dirtyEggs') or 0), dirty_n)
    _save_live_detections()
    return added


@app.post('/records/restore')
async def restore_records(request: Request):
    """Rehydrate Live Egg Records after hard refresh / backend restart."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    rows = body.get('records') if isinstance(body, dict) else body
    if not isinstance(rows, list):
        return JSONResponse({'ok': False, 'error': 'records list required'}, status_code=400)
    added = _merge_detection_rows(rows)
    return {
        'ok': True,
        'added': added,
        'total': len(detection_records),
        'goodEggs': int(metrics.get('goodEggs') or 0),
        'crackedEggs': int(metrics.get('crackedEggs') or 0),
        'dirtyEggs': int(metrics.get('dirtyEggs') or 0),
    }


@app.post('/api/egg-records')
async def api_egg_records(request: Request):
    """Save one egg to Firestore egg_readings (no SQLite)."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    payload, code = ingest_body(body if isinstance(body, dict) else {})
    return JSONResponse(payload, status_code=code)


@app.get('/api/egg-sync')
def api_egg_sync():
    store = get_store()
    counts = store.counts()
    online = bool(store.internet())
    return {
        'pending': counts['pending'],
        'synced': counts['synced'],
        'online': online,
        'backend': 'firestore',
        'records': store.recent(),
    }


@app.get('/health')
async def get_health():
    # Stay on the event loop — never touch _public_metrics / threadpool.
    # A hung sync /health + /stream workers wedged the whole farm under tunnel load.
    now = time.monotonic()
    with _raw_lock:
        raw_at = _last_raw_at
        has_raw = bool(_last_raw)
    frame_age = (now - raw_at) if raw_at else 999.0
    cam = bool(has_raw and frame_age <= LIVE_VIEW_MAX_AGE_SEC)
    hw = _hardware_online()
    return {
        'backend': 'ready',
        'ok': True,
        'connected': cam,
        'cameraConnected': cam,
        'hardwareOnline': hw,
        'frameLive': cam,
        'frameAgeMs': int(round(min(frame_age, 99.0) * 1000)),
        'status': (
            'Running'
            if (cam or hw)
            else 'Running — waiting for ESP32-CAM'
        ),
    }


def _jpeg_response(data: bytes):
    return Response(
        content=data,
        media_type='image/jpeg',
        headers={
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
            'Pragma': 'no-cache',
            'Expires': '0',
        },
    )


_PLACEHOLDER_JPEG: bytes | None = None


def _placeholder_jpeg():
    """Calm blank only — never put flash/power troubleshooting text on /watch.

    Cached once. Re-encoding 800x480 on every /live.jpg poll blocked the
    asyncio loop under tunnel load and made health + live.jpg time out.
    """
    global _PLACEHOLDER_JPEG
    cached = _PLACEHOLDER_JPEG
    if cached:
        return cached
    img = np.zeros((240, 400, 3), dtype=np.uint8)
    img[:] = (28, 24, 22)
    cv2.putText(
        img, "Waiting for internet camera...", (18, 128),
        cv2.FONT_HERSHEY_SIMPLEX, 0.45, (200, 196, 190), 1, cv2.LINE_AA,
    )
    ok, buf = cv2.imencode('.jpg', img, [int(cv2.IMWRITE_JPEG_QUALITY), 70])
    cached = buf.tobytes() if ok else b''
    _PLACEHOLDER_JPEG = cached
    return cached


def _preview_jpeg(data: bytes) -> tuple[bytes, tuple[int, int]]:
    """Live-page frame: light resize + faster JPEG so /stream stays snappy."""
    arr = np.frombuffer(data, dtype=np.uint8)
    frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if frame is None:
        return data, (640, 480)
    h, w = frame.shape[:2]
    src = (w, h)
    if w > 640:
        scale = 640.0 / float(w)
        frame = cv2.resize(frame, (640, max(1, int(h * scale))), interpolation=cv2.INTER_AREA)
    elif w < 280:
        scale = 560.0 / float(max(w, 1))
        frame = cv2.resize(
            frame, (560, max(1, int(h * scale))), interpolation=cv2.INTER_LINEAR,
        )
    elif w < 400:
        scale = 560.0 / float(w)
        frame = cv2.resize(
            frame, (560, max(1, int(h * scale))), interpolation=cv2.INTER_LINEAR,
        )
    ok, buf = cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), 62])
    return (buf.tobytes() if ok else data), src


def _paint_track(preview: bytes, box, src_wh, title: str, track_id: int) -> bytes:
    arr = np.frombuffer(preview, dtype=np.uint8)
    vis = cv2.imdecode(arr, cv2.IMREAD_COLOR)
    if vis is None:
        return preview
    ph, pw = vis.shape[:2]
    sw, sh = src_wh if src_wh and src_wh[0] and src_wh[1] else (pw, ph)
    sx = pw / float(sw)
    sy = ph / float(sh)
    scaled = (
        float(box[0]) * sx, float(box[1]) * sy,
        float(box[2]) * sx, float(box[3]) * sy,
    )
    low = (title or '').lower().strip()
    color = (80, 220, 255)
    name = 'EGG'
    if 'dirty' in low:
        name, color = 'DIRTY', (40, 180, 255)
    elif 'clean' in low or 'no crack' in low:
        name, color = 'CLEAN', (70, 220, 90)
    elif 'crack' in low:
        name, color = 'CRACK', (40, 40, 245)
    elif low in ('scanning', 'egg', 'empty model', 'empty'):
        name = 'DETECT'
    _draw_tracker(vis, scaled, color)
    x1, y1 = int(scaled[0]), int(scaled[1])
    cv2.putText(
        vis, name, (max(4, x1), max(18, y1 - 6)),
        cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 2, cv2.LINE_AA,
    )
    ok, buf = cv2.imencode('.jpg', vis, [int(cv2.IMWRITE_JPEG_QUALITY), 60])
    return buf.tobytes() if ok else preview


_pull_lock = threading.Lock()
_pull_at = 0.0


def _pull_cam_jpeg_once() -> bytes:
    """One still from the CAM. Serialized so /watch + grab_worker do not stampede :82."""
    global _pull_at
    now = time.monotonic()
    # Prefer cached CAM-push frames; only pull when cache is cold.
    if now - _pull_at < 0.70:
        with _raw_lock:
            return _last_raw or b''
    if not _pull_lock.acquire(blocking=False):
        with _raw_lock:
            return _last_raw or b''
    try:
        _pull_at = time.monotonic()
        url = _cam_jpg_url()
        # Short timeouts — unreachable LAN CAM must not block grab_worker.
        r = _jpg_session.get(url, timeout=(0.4, 0.8), headers={'Connection': 'close'})
        if r.status_code == 200 and len(r.content) >= 200 and r.content[:2] == b'\xff\xd8':
            _store_live_jpeg(r.content)
            return r.content
    except Exception:
        pass
    finally:
        _pull_lock.release()
    with _raw_lock:
        return _last_raw or b''


# Tunnel HTTPS from ESP32 is bursty on weak internet. LIVE badge uses a short
# window; /live.jpg keeps the last real picture much longer so the UI does not
# flash the "Waiting for internet camera" placeholder over a good frame.
# Short LIVE window — old frames must not look like a live hand-in-view stream.
# Realtime egg detect over tunnel: LIVE while frames arrive (~1–2 fps).
# Do NOT clear the egg tracker from /live.jpg polls — UI hits this many times
# per second and was wiping DETECTING between pushes.
LIVE_VIEW_MAX_AGE_SEC = 3.5
LIVE_VIEW_HOLD_SEC = 60.0
# Only drop track when the CAM stream is truly gone (not a 2s tunnel gap).
TRACK_STALE_CLEAR_SEC = 8.0


def _latest_view_jpeg() -> tuple[bytes, str, int]:
    """Return (jpeg, kind, age_ms). kind: live | hold | wait.

    Never pull CAM :82 here. Extender AP isolation makes LAN :82 hang.
    Never decode/encode here — request path must stay microseconds.
    Prefer painted overlay only when it matches the newest raw seq — otherwise
    a stale paint freezes the live view while CAM keeps pushing.
    """
    now = time.monotonic()
    with _raw_lock:
        raw_at = _last_raw_at
        has_raw = bool(_last_raw)
        raw = _last_raw if has_raw else b''
        raw_seq = _raw_seq
    with _view_lock:
        view = _view_jpeg if _view_jpeg and _view_jpeg[:2] == b'\xff\xd8' else b''
        view_seq = _view_seq
    age = (now - raw_at) if raw_at else 999.0
    age_ms = int(round(min(age, 999.0) * 1000))
    # Fresh raw wins. Painted box is OK only for the same frame seq.
    if view and view_seq == raw_seq:
        show = view
    else:
        show = raw or view
    if has_raw and age <= LIVE_VIEW_MAX_AGE_SEC:
        metrics['connected'] = True
        return show or raw, 'live', age_ms
    # Defer tracker clear off the /live.jpg hot path — UI polls this hard.
    if has_raw and age <= LIVE_VIEW_HOLD_SEC and raw[:2] == b'\xff\xd8':
        # Keep last real pixels on slow links — do not swap in placeholder.
        metrics['connected'] = False
        return show or raw, 'hold', age_ms
    metrics['connected'] = False
    return _placeholder_jpeg(), 'wait', age_ms


@app.get('/live.jpg')
@app.get('/live.jpgg')
async def live_jpg():
    # Async + zero OpenCV on this path so tunnel polls cannot wedge uvicorn.
    data, kind, age_ms = _latest_view_jpeg()
    return Response(
        content=data,
        media_type='image/jpeg',
        headers={
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Expose-Headers': 'X-Egg-Frame, X-Frame-Age-Ms',
            'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
            'Pragma': 'no-cache',
            'Expires': '0',
            # Drop idle tunnel sockets quickly so CF cannot pin the origin.
            'Connection': 'close',
            'X-Egg-Frame': kind,
            'X-Frame-Age-Ms': str(age_ms),
        },
    )


@app.get('/stream')
async def proxy_stream(request: Request):
    """LAN MJPEG only. Cloudflare must use /live.jpg — open /stream pins workers."""
    if _from_cloudflare(request):
        return JSONResponse(
            {'error': 'use /live.jpg over tunnel', 'code': 'stream_disabled'},
            status_code=404,
        )

    def generate():
        seen = -1
        while True:
            now = time.monotonic()
            with _raw_lock:
                raw_at = _last_raw_at
                raw = _last_raw
                seq = _raw_seq
            age = (now - raw_at) if raw_at else 999.0
            # Stream newest raw only — never the painted/view copy.
            if raw and age <= LIVE_VIEW_MAX_AGE_SEC and raw[:2] == b'\xff\xd8':
                data = raw
            elif raw and age <= LIVE_VIEW_HOLD_SEC and raw[:2] == b'\xff\xd8':
                data = raw
                seq = -1
            else:
                data = _placeholder_jpeg()
                seq = -1
            if data and seq != seen:
                seen = seq
                yield (
                    b'--frame\r\nContent-Type: image/jpeg\r\n'
                    b'Content-Length: ' + str(len(data)).encode() + b'\r\n\r\n'
                    + data + b'\r\n'
                )
            else:
                time.sleep(0.02)

    return StreamingResponse(
        generate(),
        media_type='multipart/x-mixed-replace; boundary=frame',
        headers={
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'no-store, no-cache, must-revalidate',
        },
    )


@app.get('/live-status')
def live_status():
    now = time.monotonic()
    with _raw_lock:
        raw_at = _last_raw_at
        has_raw = bool(_last_raw)
    # Real picture = fresh JPEG from CAM. Soft/QVGA frames can be ~2–6 KB —
    # the old 8 KB gate falsely kept /watch on the placeholder forever.
    with _raw_lock:
        raw_len = len(_last_raw) if _last_raw else 0
    frame_age = (now - raw_at) if raw_at else 999.0
    frame_live = (
        has_raw
        and raw_at > 0
        and frame_age < LIVE_VIEW_MAX_AGE_SEC
        and raw_len >= 800
        and (not _last_raw or _last_raw[:2] == b'\xff\xd8')
    )
    hb_live = _hardware_online()
    # Realtime detect: only clear after a long CAM gap (not every /metrics poll).
    if not frame_live and frame_age > TRACK_STALE_CLEAR_SEC:
        _clear_tracker()
    metrics['connected'] = bool(frame_live)
    egg_now = bool(_egg_in_view)
    with _track_lock:
        tracking = (
            frame_live
            and egg_now
            and _track['box'] is not None
            and bool(_track.get('confirmed'))
        )
        track_id = int(_track['id'] or 0) if tracking else 0
    scanning, scan_left = _scan_active()
    _restore_pipe_from_pending()
    pub = _public_metrics()
    lab = str(pub.get('lastLabel') or metrics.get('lastLabel') or '')
    low = lab.lower().strip()
    awaiting_weight = bool(pub.get('awaitingWeight'))
    pending_id = str(pub.get('pendingEggId') or '')
    pipe_cam = str(pub.get('pipeCamera') or '')
    quality = 'empty'
    # Never show CLEAN/CRACK/DIRTY on empty wood — only while an egg is in view.
    # NOTE: do not use "'scan' in low" — that matched "Waiting Scale" and stuck DETECTING.
    if awaiting_weight and (egg_now or tracking):
        pc = pipe_cam.lower()
        if 'dirty' in pc:
            quality = 'dirty'
        elif 'crack' in pc:
            quality = 'crack'
        else:
            quality = 'clean'
        scanning = False
        scan_left = 0.0
    elif not egg_now or not tracking:
        quality = 'empty'
        scanning = False
    elif scanning or low in ('scanning', 'egg', 'detecting'):
        quality = 'scanning'
    elif 'dirty' in low:
        quality = 'dirty'
    elif 'no crack' in low or low.startswith('clean') or low == 'clean egg':
        quality = 'clean'
    elif 'crack' in low:
        quality = 'crack'
    else:
        quality = 'scanning'
    return {
        'ok': True,
        'label': metrics.get('lastLabel') or 'Empty Model',
        'confidence': metrics.get('lastConfidence', 0),
        'connected': bool(frame_live),
        'frameLive': bool(frame_live),
        'frameAgeMs': int(round(min(frame_age, 99.0) * 1000)),
        'hardwareOnline': bool(hb_live),
        'tracking': tracking,
        'trackId': track_id if tracking else 0,
        'quality': quality,
        'scanning': bool(scanning),
        'scanLeft': float(scan_left),
        'scanTotal': float(SCAN_SEC),
        # Same-origin path so workers.dev / phones never hit a LAN CAM IP.
        'cameraStream': '/stream',
        'goodEggs': int(metrics.get('goodEggs') or 0),
        'crackedEggs': int(metrics.get('crackedEggs') or 0),
        'dirtyEggs': int(metrics.get('dirtyEggs') or 0),
        'lastWeightGrams': metrics.get('lastWeightGrams', 0),
        'lastSizeClass': metrics.get('lastSizeClass', 'N/A'),
        'awaitingWeight': awaiting_weight,
        'pendingEggId': pending_id,
        'pipeCamera': pipe_cam,
    }


# Served from the threaded front door too — CF /watch must not wait on busy uvicorn.
_WATCH_PAGE_HTML = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Egg live detection</title>
<style>
  html,body{margin:0;height:100%;overflow:hidden;background:#0d0b0a;color:#f3efe9;font-family:Segoe UI,sans-serif}
  .wrap{height:100%;box-sizing:border-box;padding:12px 16px;display:flex;flex-direction:column;overflow:hidden}
  h1{font-size:18px;margin:0 0 4px}
  .sub{color:#b7aea6;margin:0 0 10px;font-size:13px}
  img{width:min(960px,100%);height:min(78vh,720px);object-fit:contain;background:#111;border-radius:12px;display:block}
  #hud{margin-top:10px;font-size:22px;font-weight:700}
  #hud.clean{color:#6ee7a8} #hud.crack{color:#f87171} #hud.dirty{color:#fbbf24}
  #hud.scanning{color:#93c5fd} #hud.egg{color:#e5e7eb}
</style>
</head>
<body>
<div class="wrap">
  <h1>Live camera · egg tracker</h1>
  <p class="sub">Waiting egg → count + detect → Clean / Crack / Dirty</p>
  <img id="cam" alt="live camera">
  <div id="hud">waiting egg</div>
</div>
<script>
const cam = document.getElementById('cam');
const hud = document.getElementById('hud');
// v5: front-door /watch + one in-flight /live.jpg (no CF 502 on busy uvicorn).
let pulling = false;
let lastBlobAt = 0;
async function pullFrame() {
  if (pulling) return;
  pulling = true;
  try {
    const r = await fetch('/live.jpg?t=' + Date.now() + '&v=5', {
      cache: 'no-store',
      headers: { 'Cache-Control': 'no-cache' },
    });
    if (!r.ok) return;
    const blob = await r.blob();
    if (blob.size < 100) return;
    const url = URL.createObjectURL(blob);
    const prev = cam.src;
    cam.src = url;
    lastBlobAt = Date.now();
    if (prev && prev.startsWith('blob:')) URL.revokeObjectURL(prev);
  } catch (e) {}
  finally { pulling = false; }
}
setInterval(pullFrame, 140);
pullFrame();
setInterval(pullFrame, 280);
async function hudTick() {
  try {
    const s = await fetch('/live-status?t=' + Date.now(), {cache:'no-store'});
    if (s.ok) {
      const j = await s.json();
      hud.className = '';
      const age = (typeof j.frameAgeMs === 'number') ? j.frameAgeMs : 9999;
      const blobAge = lastBlobAt ? (Date.now() - lastBlobAt) : 99999;
      const hasPic = (!!(j.frameLive) && age < 8000) || blobAge < 8000;
      const eggOn = !!(j.tracking || j.scanning || j.awaitingWeight);
      const pipe = String(j.pipeCamera || '').toLowerCase();
      if (!hasPic) {
        hud.textContent = 'connecting…';
      } else if (j.awaitingWeight) {
        if (j.quality === 'crack' || pipe === 'crack') {
          hud.className = 'crack';
          hud.textContent = 'CRACK — waiting scale';
        } else if (j.quality === 'dirty' || pipe === 'dirty') {
          hud.className = 'dirty';
          hud.textContent = 'DIRTY — waiting scale';
        } else {
          hud.className = 'clean';
          hud.textContent = 'CLEAN — waiting scale';
        }
      } else if (!eggOn || j.quality === 'empty') {
        hud.textContent = 'waiting egg';
      } else if (j.quality === 'clean') {
        hud.className = 'clean';
        hud.textContent = 'CLEAN';
      } else if (j.quality === 'crack') {
        hud.className = 'crack';
        hud.textContent = 'CRACK';
      } else if (j.quality === 'dirty') {
        hud.className = 'dirty';
        hud.textContent = 'DIRTY';
      } else if (j.quality === 'scanning' || j.scanning) {
        hud.className = 'scanning';
        const left = (typeof j.scanLeft === 'number') ? j.scanLeft : 0;
        const total = (typeof j.scanTotal === 'number' && j.scanTotal > 0) ? j.scanTotal : 5.0;
        const done = Math.min(total, Math.max(0, total - left));
        hud.textContent = 'DETECTING… ' + done.toFixed(1) + 's / ' + total.toFixed(1) + 's';
      } else {
        hud.textContent = 'waiting egg';
      }
    }
  } catch (e) {}
  setTimeout(hudTick, 400);
}
hudTick();
</script>
</body>
</html>"""


@app.get('/watch')
@app.get('/live')
@app.get('/camera')
def live_watch():
    return HTMLResponse(
        content=_WATCH_PAGE_HTML,
        headers={
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'no-store',
            'Content-Security-Policy': (
        "default-src 'self'; img-src 'self' blob: data:; "
        "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
            ),
        },
    )


@app.post('/reset')
def reset_metrics():
    """Zero today's live counters and delete today's Firestore egg_readings."""
    global _force_empty_records_save
    metrics['goodEggs'] = 0
    metrics['crackedEggs'] = 0
    metrics['dirtyEggs'] = 0
    with _egg_pipe_lock:
        _egg_pipe['id'] = ''
        _egg_pipe['camera'] = ''
        _egg_pipe['category'] = ''
        _egg_pipe['awaiting_weight'] = False
        _egg_pipe['weighed'] = False
        _egg_pipe['opened_at'] = 0.0
    metrics['lastLabel'] = 'N/A'
    metrics['lastConfidence'] = 0.0
    metrics['lastWeightGrams'] = 0.0
    metrics['lastSizeClass'] = 'N/A'
    metrics['status'] = 'Counters reset'
    detection_records.clear()
    debug_info['frameCount'] = 0
    debug_info['rawScores'] = []
    debug_info['topClasses'] = []
    _force_empty_records_save = True
    _save_live_detections()
    get_store().clear_memory()
    deleted = 0
    try:
        deleted = int(delete_eggs_for_utc_day())
    except Exception as exc:
        print(f'[reset] Firestore day clear skipped: {exc}', flush=True)
    print(f'[reset] counters cleared, firestore_deleted={deleted}', flush=True)
    return {'reset': True, 'firestoreDeleted': deleted}


@app.get('/api/ping')
@app.get('/ping')
def api_ping():
    """Tiny reachability check for ESP32 (fixes false http=-1 when backend was down)."""
    return {'ok': True, 't': time.time()}


@app.post('/frame')
@app.post('/api/frame')
async def receive_frame(request: Request):
    """ESP32-CAM pushes JPEG here. Store fast; classify_worker does the heavy work."""
    data = await request.body()
    if len(data) < 200 or data[:2] != b'\xff\xd8':
        return Response(status_code=400)
    # Empty 200 — any JSON/lock work here delayed the next CAM frame.
    _store_live_jpeg(data)
    # Tiny body + explicit keep-alive so CF/tunnel can reuse the ESP32 TLS
    # session (full handshake each frame = multi-second lag).
    return Response(
        content=b'ok',
        status_code=200,
        media_type='text/plain',
        headers={
            'Connection': 'keep-alive',
            'Keep-Alive': 'timeout=30, max=1000',
            'Content-Length': '2',
        },
    )


@app.post('/weight')
async def receive_weight(request: Request):
    """
    Accept a weight reading from an external scale (e.g. Arduino + load cell).

    Expected JSON body:
        {
          "weightGrams": 55.3,
          "measurementStatus": "uncalibrated" | "simulated" | "calibrated",
          "sizeClass": "medium",          // optional override
          "deviceId": "egg-station",
          "eventId": "unique-id",         // optional; enables in-memory egg event
          "commitEgg": true,              // if true, keep egg event in RAM
          "cameraResult": "Clean",
          "sortingResult": "Good"
        }

    Live UI updates always. Egg events stay in memory (no SQLite / Firebase).
    Simulated/uncalibrated values are labeled — not treated as verified production mass.
    """
    global _pending_weight, _last_live_weight_at
    try:
        body = await request.json()
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    grams = body.get('weightGrams')
    if grams is None or not isinstance(grams, (int, float)):
        return JSONResponse({'error': 'weightGrams (number) required'}, status_code=400)
    status = str(body.get('measurementStatus') or 'uncalibrated').strip().lower()
    if status not in ('calibrated', 'uncalibrated', 'simulated'):
        status = 'uncalibrated'
    # Do not apply legacy scale correction to simulated integration weights.
    if status != 'simulated':
        grams = correct_scale_grams(float(grams))
    else:
        grams = float(grams)
    device_id = str(body.get('deviceId') or 'egg-station').strip()[:64] or 'egg-station'
    if grams < 5.0:
        held = metrics.get('lastWeightGrams') or 0
        if time.monotonic() - _last_live_weight_at >= 5.0:
            metrics['lastWeightGrams'] = 0.0
            metrics['lastSizeClass'] = 'N/A'
            metrics['lastMeasurementStatus'] = status
            with _weight_lock:
                _pending_weight = None
            print(f'[weight] empty {grams}g ({status})', flush=True)
        else:
            print(f'[weight] empty pulse ignored — keeping {held}g', flush=True)
        return {'ok': True, 'empty': True, 'weightGrams': metrics.get('lastWeightGrams') or 0.0}
    # Accept inaccurate load-cell readings (soft cell often lands 10–40 g or 90–140 g).
    if grams > 2000.0:
        print(f'[weight] Ignored {grams}g — out of range', flush=True)
        return {'ok': False, 'ignored': True, 'weightGrams': grams}
    _last_live_weight_at = time.monotonic()
    with _weight_lock:
        if 5.0 <= grams <= 250.0 or status == 'simulated':
            _pending_weight = grams
    size = str(body.get('sizeClass') or '').strip().lower()
    if not size:
        size = classify_size(grams if grams <= 150.0 else 150.0)
    if grams > 150.0:
        size = 'jumbo'
    metrics['lastWeightGrams'] = grams
    metrics['lastSizeClass'] = size
    metrics['lastMeasurementStatus'] = status
    metrics['status'] = 'Running'
    print(
        f'[weight] Received {grams}g -> {size} [{status}] device={device_id}',
        flush=True,
    )
    _decide_after_weight(grams)

    record_id = None
    sync_status = None
    linked = False
    commit = bool(body.get('commitEgg')) or bool(str(body.get('eventId') or '').strip())
    if commit and 5.0 <= grams <= 250.0:
        # Prefer same-egg link: camera Clean count → this load-cell weight.
        # Re-open pipe from orphan pending rows (timeout / FOV clear) before attach.
        _restore_pipe_from_pending()
        with _egg_pipe_lock:
            awaiting = bool(_egg_pipe.get('awaiting_weight')) and bool(_egg_pipe.get('id'))
        if awaiting:
            record_id = _attach_scale_to_camera_egg(
                grams, size, measurement_status=status, device_id=device_id,
            )
            linked = bool(record_id)
            with _weight_lock:
                _pending_weight = None
        if not linked:
            # Last chance: newest unweighted Clean/Crack/Dirty row.
            pending = _latest_pending_detection()
            if pending is None:
                for rec in reversed(list(detection_records)):
                    if rec.get('weightGrams') is not None:
                        continue
                    cat = str(rec.get('category') or '')
                    if cat not in ('goodEggs', 'crackedEggs', 'dirtyEggs'):
                        continue
                    pending = rec
                    break
            if pending and pending.get('id'):
                with _egg_pipe_lock:
                    _egg_pipe['id'] = str(pending.get('id'))
                    cam = str(pending.get('label') or 'Clean')
                    low = cam.lower()
                    if 'dirty' in low or 'soil' in low or 'stain' in low:
                        pipe_cam = 'Dirty'
                    elif 'crack' in low and 'no crack' not in low:
                        pipe_cam = 'Crack'
                    else:
                        pipe_cam = 'Clean'
                    _egg_pipe['camera'] = pipe_cam
                    _egg_pipe['category'] = str(pending.get('category') or 'goodEggs')
                    _egg_pipe['awaiting_weight'] = True
                    _egg_pipe['weighed'] = False
                    _egg_pipe['opened_at'] = time.monotonic()
                record_id = _attach_scale_to_camera_egg(
                    grams, size, measurement_status=status, device_id=device_id,
                )
                linked = bool(record_id)
                with _weight_lock:
                    _pending_weight = None
        if not linked:
            camera = str(body.get('cameraResult') or '').strip()[:80]
            sorting = str(body.get('sortingResult') or '').strip()[:80]
            live_lab = str(metrics.get('lastLabel') or '')
            if not camera or camera.upper() in ('STATION', 'PENDING', 'INTEGRATION', 'SCANNING'):
                low = live_lab.lower()
                if 'dirty' in low:
                    camera = 'Dirty'
                elif 'crack' in low:
                    camera = 'Crack'
                elif 'clean' in low or 'no crack' in low:
                    camera = 'Clean'
                else:
                    camera = camera or 'Pending'
            if not sorting:
                sorting = 'Reject' if camera in ('Crack', 'Dirty') else 'Good'
            event_id = str(body.get('eventId') or '').strip() or None
            record_id = remember_sorted_egg(
                weight=grams,
                size_class=size,
                camera_result=camera,
                sorting_result=sorting,
                record_id=event_id,
                measurement_status=status,
                device_id=device_id,
            )
            print(
                f'[weight] standalone {grams}g {size} cam={camera} (no open Clean egg)',
                flush=True,
            )
        try:
            get_store().sync_once()
        except Exception as exc:
            print(f'[weight] egg sync later: {exc}', flush=True)
        row = get_store().get(record_id) or {} if record_id else {}
        sync_status = row.get('sync_status', 'pending') if row else None
        print(
            f'[weight] egg event {record_id} sync={sync_status} linked={linked}',
            flush=True,
        )

    return {
        'ok': True,
        'weightGrams': grams,
        'sizeClass': size,
        'measurementStatus': status,
        'deviceId': device_id,
        'recordId': record_id,
        'syncStatus': sync_status,
        'linkedToCamera': linked,
    }


def _egg_sync_loop() -> None:
    while True:
        try:
            done = get_store().sync_once()
            if done:
                print(f'[egg-sync] uploaded {done} egg(s) to Firestore', flush=True)
        except Exception as exc:
            print(f'[egg-sync] retry later: {exc}', flush=True)
        time.sleep(1.5)  # retry pending Firebase uploads quickly


def ensure_background_thread():
    """Start the stream worker once (safe under uvicorn reload)."""
    global _thread_started
    with _thread_lock:
        if _thread_started:
            return
        _thread_started = True
    print('[main] Starting background stream worker...')
    print('[main] Egg history = Firestore egg_readings only (no SQLite)')
    thread = threading.Thread(target=stream_worker, daemon=True)
    thread.start()
    threading.Thread(target=_egg_sync_loop, daemon=True).start()


@app.on_event('startup')
def _on_startup():
    global labels
    classify_on = os.environ.get('CLASSIFY_ENABLED', '1').strip().lower() not in (
        '0', 'false', 'no',
    )
    if not labels:
        print('Loading labels...')
        labels = load_labels(LABELS_PATH) if LABELS_PATH.is_file() else [
            'Empty Model', 'No Crack Egg', 'Crack Egg', 'Dirty Egg',
        ]
        print(f'Labels loaded: {labels}')
        if classify_on:
            print('Loading models: crack/dirty TFLite + Empty/Clean SavedModel...')
            load_model()
            print('Hybrid detectors ready.')
        else:
            print(
                'Models SKIPPED (CLASSIFY_ENABLED=0) — live camera only',
                flush=True,
            )
    # Drop sticky Clean→scale wait from prior runs so tracker can lock immediately.
    with _egg_pipe_lock:
        _egg_pipe['id'] = ''
        _egg_pipe['camera'] = ''
        _egg_pipe['category'] = ''
        _egg_pipe['awaiting_weight'] = False
        _egg_pipe['weighed'] = False
        _egg_pipe['opened_at'] = 0.0
    for rec in detection_records:
        if rec.get('awaitingWeight'):
            rec['awaitingWeight'] = False
    try:
        _save_live_detections()
    except Exception:
        pass
    ensure_background_thread()


@app.put('/farm/snapshot')
async def farm_snapshot_put(request: Request):
    """Shared farm ledger so seller sales update admin inventory/sales."""
    user = get_user_from_authorization(request.headers.get('authorization'))
    if user is None:
        return JSONResponse(
            {'error': 'Sign in again.', 'code': 'unauthorized'},
            status_code=401,
        )
    try:
        payload = await request.json()
    except Exception:
        payload = None
    if not isinstance(payload, dict):
        return JSONResponse(
            {'error': 'Invalid farm snapshot.', 'code': 'invalid_request'},
            status_code=400,
        )
    merged = put_shared_farm_snapshot(int(user['id']), payload)
    return {'ok': True, 'snapshot': merged}


@app.get('/farm/snapshot')
async def farm_snapshot_get(request: Request):
    user = get_user_from_authorization(request.headers.get('authorization'))
    if user is None:
        return JSONResponse(
            {'error': 'Sign in again.', 'code': 'unauthorized'},
            status_code=401,
        )
    shared = get_shared_farm_snapshot(int(user['id']))
    if shared is None:
        return JSONResponse({'snapshot': None}, status_code=404)
    return {'snapshot': shared}


# Auth stays on Flask; mount last so FastAPI live routes win.
app.mount('/auth', WSGIMiddleware(_PrependAuthPath(_auth_flask)))


def _front_health_bytes() -> bytes:
    now = time.monotonic()
    with _raw_lock:
        raw_at = _last_raw_at
        has_raw = bool(_last_raw)
    frame_age = (now - raw_at) if raw_at else 999.0
    cam = bool(has_raw and frame_age <= LIVE_VIEW_MAX_AGE_SEC)
    payload = {
        'backend': 'ready',
        'ok': True,
        'connected': cam,
        'cameraConnected': cam,
        'hardwareOnline': _hardware_online(),
        'frameLive': cam,
        'frameAgeMs': int(round(min(frame_age, 99.0) * 1000)),
        'status': (
            'Running'
            if cam
            else 'Running — waiting for ESP32-CAM'
        ),
    }
    return json.dumps(payload).encode('utf-8')


def _start_tunnel_front_door(public_host: str, public_port: int, inner_port: int) -> None:
    """Threaded :public_port so cloudflared backpressure cannot freeze uvicorn.

    Proven: with cloudflared stopped, asyncio /live.jpg was 2–7ms; with it up,
    the same loop stalled for seconds because slow CF socket writes blocked
    the single event loop. Live + CAM push run in their own threads here.
    """
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib import error as urlerror
    from urllib import request as urlrequest

    inner = f'http://127.0.0.1:{inner_port}'

    class FrontHandler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, fmt, *args):  # noqa: N802
            return

        def _send(self, code: int, body: bytes, headers: dict[str, str]) -> None:
            self.send_response(code)
            for key, val in headers.items():
                self.send_header(key, val)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if body and self.command != 'HEAD':
                self.wfile.write(body)

        def do_OPTIONS(self):  # noqa: N802
            self._send(204, b'', {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
                'Access-Control-Allow-Headers': '*',
            })

        def do_HEAD(self):  # noqa: N802
            self.do_GET()

        def do_GET(self):  # noqa: N802
            path = (self.path or '/').split('?', 1)[0]
            if path in ('/live.jpg', '/live.jpgg'):
                data, kind, age_ms = _latest_view_jpeg()
                self._send(200, data, {
                    'Content-Type': 'image/jpeg',
                    'Access-Control-Allow-Origin': '*',
                    'Access-Control-Expose-Headers': 'X-Egg-Frame, X-Frame-Age-Ms',
                    'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
                    'X-Egg-Frame': kind,
                    'X-Frame-Age-Ms': str(age_ms),
                })
                return
            if path == '/health':
                body = _front_health_bytes()
                self._send(200, body, {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*',
                    'Cache-Control': 'no-store',
                })
                return
            if path in ('/watch', '/live', '/camera'):
                body = _WATCH_PAGE_HTML.encode('utf-8')
                self._send(200, body, {
                    'Content-Type': 'text/html; charset=utf-8',
                    'Access-Control-Allow-Origin': '*',
                    'Cache-Control': 'no-store',
                    'Connection': 'close',
                })
                return
            if path == '/live-status':
                try:
                    body = json.dumps(live_status()).encode('utf-8')
                except Exception:
                    body = b'{"ok":false}'
                self._send(200, body, {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*',
                    'Cache-Control': 'no-store',
                    'Connection': 'close',
                })
                return
            if path in ('/api/ping', '/ping'):
                body = json.dumps({'ok': True, 't': time.time()}).encode('utf-8')
                self._send(200, body, {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*',
                })
                return
            self._proxy()

        def do_POST(self):  # noqa: N802
            path = (self.path or '/').split('?', 1)[0]
            if path in ('/api/frame', '/frame'):
                try:
                    length = int(self.headers.get('Content-Length') or 0)
                except ValueError:
                    length = 0
                # Cap read so a stuck CAM cannot pin a worker thread forever.
                length = max(0, min(length, 512_000))
                body = self.rfile.read(length) if length else b''
                if len(body) < 200 or body[:2] != b'\xff\xd8':
                    self._send(400, b'bad', {'Content-Type': 'text/plain'})
                    return
                _store_live_jpeg(body)
                self._send(200, b'ok', {
                    'Content-Type': 'text/plain',
                    'Connection': 'keep-alive',
                    'Keep-Alive': 'timeout=30, max=1000',
                })
                return
            self._proxy()

        def _proxy(self) -> None:
            url = inner + (self.path or '/')
            data = None
            if self.command in ('POST', 'PUT', 'PATCH'):
                try:
                    length = int(self.headers.get('Content-Length') or 0)
                except ValueError:
                    length = 0
                data = self.rfile.read(length) if length > 0 else None
            headers = {
                k: v for k, v in self.headers.items()
                if k.lower() not in ('host', 'content-length', 'connection')
            }
            req = urlrequest.Request(
                url, data=data, headers=headers, method=self.command,
            )
            try:
                # Short timeout — CF 502 beats a hung origin under TF/GIL load.
                with urlrequest.urlopen(req, timeout=8) as resp:
                    payload = resp.read()
                    self.send_response(resp.status)
                    for key, val in resp.headers.items():
                        if key.lower() in (
                            'transfer-encoding', 'connection', 'content-length',
                        ):
                            continue
                        self.send_header(key, val)
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    if self.command != 'HEAD':
                        self.wfile.write(payload)
            except urlerror.HTTPError as exc:
                payload = exc.read() or b''
                self.send_response(exc.code)
                self.send_header('Content-Type', exc.headers.get(
                    'Content-Type', 'text/plain',
                ))
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                if payload and self.command != 'HEAD':
                    self.wfile.write(payload)
            except Exception:
                self._send(502, b'origin', {'Content-Type': 'text/plain'})

    httpd = ThreadingHTTPServer((public_host, public_port), FrontHandler)
    httpd.daemon_threads = True
    print(
        f'[front] threaded live door on {public_host}:{public_port} '
        f'(inner uvicorn 127.0.0.1:{inner_port})',
        flush=True,
    )
    httpd.serve_forever()


if __name__ == '__main__':
    import os
    import socket
    import uvicorn

    # cloudflared → threaded :8000 front (live.jpg / api/frame) → uvicorn :8001
    port = int(os.environ.get('FARM_APP_PORT', '8000'))
    host = os.environ.get('FARM_APP_HOST', '0.0.0.0')
    inner_port = int(os.environ.get('FARM_INNER_PORT', '8001'))
    print('Public live API  https://egg-farm.eggsorting.site')
    print('Hosted UI        https://egg-system.paghasianjustine.workers.dev')
    print('Storage          Firebase Firestore only')
    print(f'Tunnel origin   {host}:{port} threaded front → 127.0.0.1:{inner_port}')
    _placeholder_jpeg()

    def _run_inner() -> None:
        # Pass the app object (not 'module:app' string) so CAM frames stored by
        # the threaded front share the same _last_raw as classify_worker.
        # String import loaded a second module copy → live.jpg worked, detect did not.
        uvicorn.run(
            app,
            host='127.0.0.1',
            port=inner_port,
            reload=False,
            log_level='warning',
            access_log=False,
            timeout_keep_alive=5,
            limit_concurrency=64,
        )

    threading.Thread(target=_run_inner, name='uvicorn-inner', daemon=True).start()
    for _ in range(80):
        time.sleep(0.25)
        try:
            with socket.create_connection(('127.0.0.1', inner_port), timeout=0.3):
                break
        except OSError:
            continue
    else:
        print('[front] WARNING: inner uvicorn not ready — starting front anyway', flush=True)
    _start_tunnel_front_door(host, port, inner_port)
