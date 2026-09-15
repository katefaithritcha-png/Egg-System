from collections import deque
from pathlib import Path
import os
import random
import sys
import threading
import time

import cv2
import numpy as np
import requests
import tensorflow as tf
from flask import Flask, Response, jsonify, request, stream_with_context
from flask_cors import CORS

sys.path.insert(0, str(Path(__file__).resolve().parent))
from auth import init_auth

ESP32_STREAM_URL = os.environ.get('ESP32_STREAM_URL', 'http://192.168.11.121:81/stream')
MODEL_DIR = Path(r'C:\Users\ADMIN\Downloads\converted_savedmodel\model.savedmodel')
LABELS_PATH = Path(r'C:\Users\ADMIN\Downloads\converted_savedmodel\labels.txt')

# Only count a detection when the model is at least this confident.
CONFIDENCE_THRESHOLD = 60.0

# How many recent detection records to keep for the /records endpoint.
MAX_RECORDS = 200

app = Flask(__name__)
CORS(app, supports_credentials=False, allow_headers=['Authorization', 'Content-Type'])
init_auth(app)

metrics = {
    'goodEggs': 0,
    'crackedEggs': 0,
    'dirtyEggs': 0,
    'status': 'Starting live inspection...',
    'lastLabel': 'N/A',
    'lastConfidence': 0.0,
    'lastWeightGrams': 0.0,
    'lastSizeClass': 'N/A',
    'connected': False,
}

# Chronological log of every confirmed detection (egg present, above threshold).
# Each entry: { timestamp, label, confidence, category, weightGrams, sizeClass }
detection_records: deque = deque(maxlen=MAX_RECORDS)

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

_heartbeat_lock = threading.Lock()
_esp32_last_seen = 0.0

# ESP32 stops the belt at the IR, then asks for one decision on this egg.
_inspect_lock = threading.Lock()
_inspect = {
    'waiting': False,
    'ready': False,
    'reject': False,
    'label': '',
    'asked_at': 0.0,
}
_esp32_device = 'ESP32-CAM'
_stream_url_lock = threading.Lock()
_stream_url_epoch = 0
HEARTBEAT_TTL_SECONDS = 15.0


def _hardware_online() -> bool:
    with _heartbeat_lock:
        if _esp32_last_seen <= 0:
            return False
        return (time.monotonic() - _esp32_last_seen) < HEARTBEAT_TTL_SECONDS


def _note_heartbeat(device: str, stream_url: str = '') -> None:
    global _esp32_last_seen, _esp32_device, ESP32_STREAM_URL, _stream_url_epoch
    name = (device or 'ESP32-CAM').strip() or 'ESP32-CAM'
    with _heartbeat_lock:
        _esp32_last_seen = time.monotonic()
        _esp32_device = name
    cleaned = stream_url.strip()
    if cleaned.startswith('http://') or cleaned.startswith('https://'):
        with _stream_url_lock:
            if ESP32_STREAM_URL != cleaned:
                ESP32_STREAM_URL = cleaned
                _stream_url_epoch += 1
                print(f'[heartbeat] camera stream set to {cleaned}', flush=True)
    print(f'[heartbeat] {name} ONLINE', flush=True)


def _public_metrics() -> dict:
    hardware = _hardware_online()
    payload = dict(metrics)
    payload['hardwareOnline'] = hardware
    payload['hardwareDevice'] = _esp32_device
    payload['connected'] = bool(metrics.get('connected') or hardware)
    if hardware and not metrics.get('connected'):
        payload['status'] = f'{_esp32_device} powered on and connected to Wi-Fi'
    return payload


def classify_size(grams: float) -> str:
    """
    Map a weight in grams to a size-class string matching the Flutter enum.
        peewee      < 40.0 g
        small       40.0 – 47.0 g
        medium      47.1 – 54.0 g
        large       54.1 – 61.3 g
        extraLarge  61.4 – 68.5 g
        jumbo       > 68.5 g
    """
    if grams < 40.0:
        return 'peewee'
    if grams <= 47.0:
        return 'small'
    if grams <= 54.0:
        return 'medium'
    if grams <= 61.3:
        return 'large'
    if grams <= 68.5:
        return 'extraLarge'
    return 'jumbo'


def _simulate_weight() -> float:
    """
    Produce a realistic random egg weight when no physical scale is connected.
    Weights are sampled from a normal distribution centred on 54 g (Large)
    with a std-dev of 10 g, clamped to the plausible 30–85 g range.
    """
    return round(max(30.0, min(85.0, random.gauss(54.0, 10.0))), 1)


def _consume_pending_weight() -> float | None:
    """Return a real scale POST, or None. Never invent a weight."""
    global _pending_weight
    with _weight_lock:
        if _pending_weight is None:
            return None
        w = _pending_weight
        _pending_weight = None
        return w


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


def load_model():
    global signature, input_name, input_shape
    model = tf.saved_model.load(str(MODEL_DIR))
    signatures = getattr(model, 'signatures', None)
    if signatures is None or 'serving_default' not in signatures:
        raise RuntimeError('SavedModel does not expose a serving_default signature')
    signature = signatures['serving_default']
    input_signature = signature.structured_input_signature[1]
    if not input_signature:
        raise RuntimeError('SavedModel serving_default signature has no inputs.')
    input_name, input_spec = next(iter(input_signature.items()))
    input_shape = tuple(input_spec.shape[1:])
    if len(input_shape) != 3:
        raise RuntimeError(f'Unsupported model input shape: {input_shape}')


def preprocess_frame(frame):
    resized = cv2.resize(frame, (input_shape[1], input_shape[0]))
    rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    arr = rgb.astype(np.float32) / 255.0
    return np.expand_dims(arr, axis=0)


def classify_frame(frame):
    global debug_info
    input_data = preprocess_frame(frame)
    outputs = signature(**{input_name: tf.constant(input_data)})
    output_tensor = next(iter(outputs.values()))
    predictions = output_tensor.numpy()
    if predictions.ndim == 2 and predictions.shape[0] == 1:
        predictions = predictions[0]
    idx = int(np.argmax(predictions))
    label = labels[idx] if idx < len(labels) else f'Class_{idx}'
    confidence = float(predictions[idx]) * 100.0

    raw_scores = predictions.tolist()
    top_k = sorted(enumerate(raw_scores), key=lambda x: x[1], reverse=True)[:3]
    debug_info['rawScores'] = raw_scores
    debug_info['topClasses'] = [
        {
            'index': int(r[0]),
            'label': labels[r[0]] if r[0] < len(labels) else f'Class_{r[0]}',
            'score': float(r[1]) * 100.0,
        }
        for r in top_k
    ]
    debug_info['lastFrameTimestamp'] = time.strftime('%Y-%m-%d %H:%M:%S')
    debug_info['frameCount'] += 1

    return label, confidence


def counting_category(label: str):
    """
    Map a model label to a metrics bucket.

    Actual labels in labels.txt:
        0 Empty Model  → skip (no egg present)
        1 No Crack Egg → goodEggs
        2 Crack Egg    → crackedEggs
        3 Dirty Egg    → dirtyEggs

    Matching is case-insensitive and checks for substrings so minor
    label wording changes won't break things.
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


def _apply_inspect_frame(label: str, confidence: float) -> None:
    """One decision per stopped egg: crack or dirty ejects, clean stays."""
    with _inspect_lock:
        if not _inspect['waiting'] or _inspect['ready']:
            return
        if time.time() - _inspect['asked_at'] > 3.0:
            _inspect['ready'] = True
            _inspect['waiting'] = False
            _inspect['reject'] = False
            _inspect['label'] = 'timeout'
            print('[inspect] timeout — keep egg', flush=True)
            return
        if confidence < CONFIDENCE_THRESHOLD or is_empty_frame(label):
            return
        category = counting_category(label)
        if category not in ('goodEggs', 'crackedEggs', 'dirtyEggs'):
            return
        reject = category in ('crackedEggs', 'dirtyEggs')
        _inspect['ready'] = True
        _inspect['waiting'] = False
        _inspect['reject'] = reject
        _inspect['label'] = label
        print(f'[inspect] {"REJECT" if reject else "KEEP"} label={label!r}', flush=True)


def is_empty_frame(label: str) -> bool:
    """Return True when the model says there is no egg in the frame."""
    s = label.lower()
    return 'empty' in s or 'no egg' in s or 'background' in s or 'none' in s


_last_count_at = 0.0


def stream_worker():
    global metrics, _last_count_at
    while True:
        with _stream_url_lock:
            url = ESP32_STREAM_URL
            epoch = _stream_url_epoch
        print(f'[worker] Connecting to ESP32-CAM: {url}', flush=True)
        cap = cv2.VideoCapture(url)
        if not cap.isOpened():
            metrics['status'] = 'Unable to open ESP32-CAM stream'
            metrics['connected'] = False
            print('[worker] Connection failed; retrying in 3 s.', flush=True)
            cap.release()
            time.sleep(3.0)
            continue

        metrics['status'] = 'ESP32 stream opened; running inference'
        metrics['connected'] = True
        print('[worker] ESP32-CAM stream opened.', flush=True)

        while True:
            with _stream_url_lock:
                url_changed = ESP32_STREAM_URL != url or _stream_url_epoch != epoch
            if url_changed:
                print('[worker] camera IP changed — reconnecting', flush=True)
                cap.release()
                break

            success, frame = cap.read()
            if not success or frame is None:
                metrics['status'] = 'Frame read failed, reconnecting...'
                metrics['connected'] = False
                print('[worker] Frame read failed; reconnecting.', flush=True)
                cap.release()
                time.sleep(2.0)
                break

            label, confidence = classify_frame(frame)
            _apply_inspect_frame(label, confidence)

            # Always update the "last seen" fields so the UI shows activity.
            metrics['lastLabel'] = label
            metrics['lastConfidence'] = round(confidence, 1)
            metrics['status'] = 'Running'
            metrics['connected'] = True

            # Count one egg only when the ESP32 scale actually posted grams.
            # The camera alone was inventing a dirty egg and a random weight
            # on almost every frame.
            weight = None
            if confidence >= CONFIDENCE_THRESHOLD and not is_empty_frame(label):
                category = counting_category(label)
                weight = _consume_pending_weight()
                now = time.monotonic()
                if (
                    category is not None
                    and weight is not None
                    and 5.0 <= weight <= 150.0
                    and now - _last_count_at >= 3.0
                ):
                    _last_count_at = now
                    size_class = classify_size(weight)
                    metrics[category] += 1
                    metrics['lastWeightGrams'] = weight
                    metrics['lastSizeClass'] = size_class
                    detection_records.append({
                        'timestamp': time.strftime('%Y-%m-%d %H:%M:%S'),
                        'label': label,
                        'confidence': round(confidence, 1),
                        'category': category,
                        'weightGrams': weight,
                        'sizeClass': size_class,
                    })
                    print(
                        f'[worker] DETECTED  label={label!r}  '
                        f'conf={confidence:.1f}%  cat={category}  '
                        f'weight={weight}g  size={size_class}',
                        flush=True,
                    )
                elif weight is None:
                    print(
                        f'[worker] camera={label!r} {confidence:.0f}%  '
                        'no scale weight — not counted',
                        flush=True,
                    )
            else:
                reason = (
                    'empty frame'
                    if is_empty_frame(label)
                    else f'low confidence ({confidence:.1f}%)'
                )
                print(f'[worker] SKIPPED  label={label!r}  reason={reason}', flush=True)

            time.sleep(0.15)


@app.route('/', methods=['GET'])
def root():
    payload = _public_metrics()
    return jsonify({
        'ok': True,
        'service': 'egg-system',
        'message': 'Egg System backend is running. Open the Flutter app, not this URL.',
        'health': '/health',
        'metrics': '/metrics',
        'authHealth': '/auth/health',
        'connected': payload['connected'],
        'hardwareOnline': payload['hardwareOnline'],
        'status': payload['status'],
    })


@app.route('/metrics', methods=['GET'])
def get_metrics():
    return jsonify(_public_metrics())


def _hardware_status_response():
    body = request.get_json(silent=True) or {}
    device = str(body.get('device') or 'ESP32-CAM')
    status = str(body.get('status') or 'ONLINE').upper()
    stream_url = str(body.get('streamUrl') or '')
    if status in ('ONLINE', 'OK', 'ACTIVE', '1', 'TRUE'):
        _note_heartbeat(device, stream_url)
    payload = _public_metrics()
    if stream_url:
        print(f'[heartbeat] streamUrl={stream_url}', flush=True)
    return jsonify({
        'ok': True,
        'hardwareOnline': payload['hardwareOnline'],
        'device': payload['hardwareDevice'],
        'connected': payload['connected'],
        'status': payload['status'],
    })


@app.route('/api/status', methods=['GET', 'POST'])
def api_status():
    if request.method == 'POST':
        return _hardware_status_response()
    payload = _public_metrics()
    return jsonify({
        'connected': payload['connected'],
        'hardwareOnline': payload['hardwareOnline'],
        'status': payload['status'],
        'lastLabel': payload['lastLabel'],
        'lastConfidence': payload['lastConfidence'],
    })


@app.route('/api/inspect', methods=['GET', 'POST'])
def api_inspect():
    """ESP32 calls POST when the IR has stopped an egg, then GET until ready."""
    with _inspect_lock:
        if request.method == 'POST':
            _inspect['waiting'] = True
            _inspect['ready'] = False
            _inspect['reject'] = False
            _inspect['label'] = ''
            _inspect['asked_at'] = time.time()
            print('[inspect] egg held — waiting for camera', flush=True)
            return jsonify({'ok': True, 'ready': False, 'reject': False})

        if (
            _inspect['waiting']
            and not _inspect['ready']
            and time.time() - _inspect['asked_at'] > 3.0
        ):
            _inspect['ready'] = True
            _inspect['waiting'] = False
            _inspect['reject'] = False
            _inspect['label'] = 'timeout'
        return jsonify({
            'ok': True,
            'ready': _inspect['ready'],
            'reject': _inspect['reject'],
            'label': _inspect['label'],
        })


@app.route('/status', methods=['GET', 'POST'])
def get_status():
    if request.method == 'POST':
        return _hardware_status_response()
    payload = _public_metrics()
    return jsonify({
        'connected': payload['connected'],
        'hardwareOnline': payload['hardwareOnline'],
        'status': payload['status'],
        'lastLabel': payload['lastLabel'],
        'lastConfidence': payload['lastConfidence'],
    })


@app.route('/debug', methods=['GET'])
def get_debug_info():
    return jsonify({'metrics': metrics, 'debug': debug_info})


@app.route('/records', methods=['GET'])
def get_records():
    """Return the last MAX_RECORDS confirmed detections in reverse-chronological
    order (newest first), skipping 'Empty Model' and low-confidence frames."""
    return jsonify(list(reversed(detection_records)))


@app.route('/health', methods=['GET'])
def get_health():
    payload = _public_metrics()
    return jsonify({
        'backend': 'ready',
        'cameraConnected': bool(metrics.get('connected')),
        'hardwareOnline': payload['hardwareOnline'],
        'status': payload['status'],
    })


@app.route('/stream')
def proxy_stream():
    """Proxy the ESP32-CAM MJPEG stream through the backend."""
    def generate():
        try:
            with requests.get(ESP32_STREAM_URL, stream=True, timeout=10) as r:
                for chunk in r.iter_content(chunk_size=4096):
                    if chunk:
                        yield chunk
        except Exception as exc:
            print(f'[stream proxy] Error: {exc}')

    return Response(
        stream_with_context(generate()),
        content_type='multipart/x-mixed-replace; boundary=frame',
    )


@app.route('/reset', methods=['POST'])
def reset_metrics():
    """Zero all counters and clear the detection log."""
    metrics['goodEggs'] = 0
    metrics['crackedEggs'] = 0
    metrics['dirtyEggs'] = 0
    metrics['lastLabel'] = 'N/A'
    metrics['lastConfidence'] = 0.0
    metrics['lastWeightGrams'] = 0.0
    metrics['lastSizeClass'] = 'N/A'
    metrics['status'] = 'Counters reset'
    detection_records.clear()
    debug_info['frameCount'] = 0
    debug_info['rawScores'] = []
    debug_info['topClasses'] = []
    return jsonify({'reset': True})


@app.route('/weight', methods=['POST'])
def receive_weight():
    """
    Accept a weight reading from an external scale (e.g. Arduino + load cell).

    Expected JSON body:
        { "weightGrams": 55.3 }

    The value is stored and used by the next camera detection.
    No weight is invented if the scale has not posted.
    """
    global _pending_weight
    body = request.get_json(silent=True) or {}
    grams = body.get('weightGrams')
    if grams is None or not isinstance(grams, (int, float)):
        return jsonify({'error': 'weightGrams (number) required'}), 400
    grams = round(float(grams), 1)
    if grams < 5.0 or grams > 150.0:
        print(f'[weight] Ignored {grams}g — out of range', flush=True)
        return jsonify({'ok': False, 'ignored': True, 'weightGrams': grams}), 200
    with _weight_lock:
        _pending_weight = grams
    size = classify_size(grams)
    metrics['lastWeightGrams'] = grams
    metrics['lastSizeClass'] = size
    metrics['status'] = f'Scale reading {grams}g ({size})'
    print(f'[weight] Received {grams}g → {size} (shown on Live Inspection)', flush=True)
    return jsonify({'ok': True, 'weightGrams': grams, 'sizeClass': size})


def ensure_background_thread():
    """Start the stream worker once, even when Flask debug reloader is active."""
    global _thread_started
    # In debug mode Flask spawns a reloader child; only start in the child
    # (or when not in debug mode) to avoid double-starting.
    if os.environ.get('WERKZEUG_RUN_MAIN') == 'true' or not app.debug:
        with _thread_lock:
            if _thread_started:
                return
            _thread_started = True
        print('[main] Starting background stream worker...')
        thread = threading.Thread(target=stream_worker, daemon=True)
        thread.start()


@app.before_request
def start_background_thread():
    ensure_background_thread()


if __name__ == '__main__':
    print('Loading labels...')
    labels = load_labels(LABELS_PATH)
    print(f'Labels loaded: {labels}')
    print('Loading SavedModel...')
    load_model()
    print('Model loaded.')
    # debug=False prevents the Werkzeug reloader from spawning a second process
    # that would create a duplicate stream worker thread.
    app.run(host='0.0.0.0', port=8000, debug=False)
