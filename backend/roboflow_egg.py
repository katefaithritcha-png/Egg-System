"""Roboflow Serverless inference for egg-defect-detection-sznlj/1."""

from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Any

import cv2
import numpy as np

_client = None
_client_failed = False
_printed_ok = False


def _api_key() -> str:
    return (os.environ.get('ROBOFLOW_API_KEY') or '').strip()


def _model_id() -> str:
    return (os.environ.get('ROBOFLOW_MODEL_ID') or 'egg-defect-detection-sznlj/1').strip()


def _api_url() -> str:
    return (os.environ.get('ROBOFLOW_API_URL') or 'https://serverless.roboflow.com').strip()


def client_ready() -> bool:
    return bool(_api_key()) and not _client_failed


def _get_client():
    global _client, _client_failed
    if _client_failed:
        return None
    if _client is not None:
        return _client
    key = _api_key()
    if not key:
        print('[roboflow] ROBOFLOW_API_KEY missing — using local Teachable Machine', flush=True)
        _client_failed = True
        return None
    try:
        from inference_sdk import InferenceConfiguration, InferenceHTTPClient
        _client = InferenceHTTPClient(
            api_url=_api_url(),
            api_key=key,
        ).configure(InferenceConfiguration(api_key_transport='header'))
        print(f'[roboflow] connected model={_model_id()}', flush=True)
        return _client
    except Exception as exc:
        print(f'[roboflow] SDK not ready: {exc}', flush=True)
        _client_failed = True
        return None


def _display_label(raw: str) -> str:
    s = (raw or '').strip().lower()
    if 'dirty' in s or 'soil' in s or 'stain' in s:
        return 'Dirty Egg'
    if 'crack' in s or 'broken' in s:
        return 'Crack Egg'
    if 'good' in s or 'clean' in s or 'ok' in s or 'healthy' in s or s == 'egg':
        return 'No Crack Egg'
    return 'Empty Model'


def _as_percent(value: Any) -> float:
    try:
        num = float(value)
    except (TypeError, ValueError):
        return 0.0
    if num <= 1.0:
        num *= 100.0
    return max(0.0, min(num, 100.0))


def _clip_box(x1: int, y1: int, x2: int, y2: int, fw: int, fh: int) -> tuple[int, int, int, int] | None:
    x1 = max(0, min(fw - 1, x1))
    y1 = max(0, min(fh - 1, y1))
    x2 = max(0, min(fw - 1, x2))
    y2 = max(0, min(fh - 1, y2))
    if x2 - x1 < 8 or y2 - y1 < 8:
        return None
    return x1, y1, x2, y2


def _box_from_pred(pred: dict[str, Any], fw: int, fh: int) -> tuple[int, int, int, int] | None:
    if fw < 8 or fh < 8:
        return None
    if all(k in pred for k in ('xmin', 'ymin', 'xmax', 'ymax')):
        return _clip_box(
            int(float(pred['xmin'])), int(float(pred['ymin'])),
            int(float(pred['xmax'])), int(float(pred['ymax'])),
            fw, fh,
        )
    x = pred.get('x')
    y = pred.get('y')
    bw = pred.get('width', pred.get('w'))
    bh = pred.get('height', pred.get('h'))
    if x is None or y is None or bw is None or bh is None:
        return None
    cx, cy, w, h = float(x), float(y), float(bw), float(bh)
    if max(abs(cx), abs(cy), abs(w), abs(h)) <= 1.5:
        cx *= fw
        cy *= fh
        w *= fw
        h *= fh
    return _clip_box(
        int(round(cx - w / 2.0)), int(round(cy - h / 2.0)),
        int(round(cx + w / 2.0)), int(round(cy + h / 2.0)),
        fw, fh,
    )


def _collect_preds(obj: Any, found: list[tuple[str, float]]) -> None:
    if isinstance(obj, dict):
        cls = obj.get('class') or obj.get('class_name') or obj.get('label')
        conf = obj.get('confidence', obj.get('score'))
        if cls is not None and conf is not None:
            found.append((str(cls), _as_percent(conf)))
        top = obj.get('top')
        if top is not None and obj.get('confidence') is not None:
            found.append((str(top), _as_percent(obj.get('confidence'))))
        preds = obj.get('predictions')
        if preds is not None:
            _collect_preds(preds, found)
        for key, val in obj.items():
            if key in ('predictions', 'class', 'class_name', 'label', 'top', 'confidence', 'score'):
                continue
            if isinstance(val, (dict, list)):
                _collect_preds(val, found)
    elif isinstance(obj, list):
        for item in obj:
            _collect_preds(item, found)


def _collect_boxes(obj: Any, fw: int, fh: int, boxes: list[tuple[int, int, int, int]]) -> None:
    if isinstance(obj, dict):
        preds = obj.get('predictions')
        if preds is not None:
            _collect_boxes(preds, fw, fh, boxes)
            return
        if obj.get('class') or obj.get('class_name') or obj.get('label'):
            box = _box_from_pred(obj, fw, fh)
            if box is not None:
                boxes.append(box)
    elif isinstance(obj, list):
        for item in obj:
            _collect_boxes(item, fw, fh, boxes)


def parse_infer_result(
    result: Any,
    frame_w: int = 0,
    frame_h: int = 0,
) -> tuple[str, float, dict[str, float], list[tuple[int, int, int, int]]]:
    found: list[tuple[str, float]] = []
    _collect_preds(result, found)
    boxes: list[tuple[int, int, int, int]] = []
    _collect_boxes(result, frame_w, frame_h, boxes)
    scores = {
        'Empty Model': 0.0,
        'No Crack Egg': 0.0,
        'Crack Egg': 0.0,
        'Dirty Egg': 0.0,
    }
    for raw, conf in found:
        lab = _display_label(raw)
        if lab not in scores:
            scores[lab] = 0.0
        scores[lab] = max(scores[lab], conf)
    if isinstance(result, dict) and result.get('top'):
        label = _display_label(str(result.get('top')))
        confidence = _as_percent(result.get('confidence', scores.get(label, 0.0)))
        scores[label] = max(scores.get(label, 0.0), confidence)
        return label, confidence, scores, boxes
    if found:
        raw, conf = max(found, key=lambda item: item[1])
        label = _display_label(raw)
        return label, conf, scores, boxes
    return 'Empty Model', 0.0, scores, boxes


def infer_bgr_frame(
    frame: np.ndarray,
) -> tuple[str, float, dict[str, float], list[tuple[int, int, int, int]]] | None:
    global _printed_ok
    cli = _get_client()
    if cli is None:
        return None
    ok, buf = cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), 72])
    if not ok:
        return None
    # Downscale big frames so Roboflow does not stall the PC.
    h, w = frame.shape[:2]
    if max(h, w) > 640:
        scale = 640.0 / float(max(h, w))
        small = cv2.resize(frame, (int(w * scale), int(h * scale)))
        ok, buf = cv2.imencode('.jpg', small, [int(cv2.IMWRITE_JPEG_QUALITY), 72])
        if not ok:
            return None
        path = ''
        try:
            handle, path = tempfile.mkstemp(suffix='.jpg')
            os.close(handle)
            Path(path).write_bytes(buf.tobytes())
            result = cli.infer(path, model_id=_model_id())
        finally:
            if path:
                try:
                    os.remove(path)
                except OSError:
                    pass
        if not _printed_ok:
            _printed_ok = True
            print('[roboflow] first infer ok', flush=True)
        label, conf, scores, boxes = parse_infer_result(result, small.shape[1], small.shape[0])
        # Map boxes back to full frame.
        mapped = []
        for x1, y1, x2, y2 in boxes:
            mapped.append((
                int(round(x1 / scale)), int(round(y1 / scale)),
                int(round(x2 / scale)), int(round(y2 / scale)),
            ))
        return label, conf, scores, mapped
    path = ''
    try:
        handle, path = tempfile.mkstemp(suffix='.jpg')
        os.close(handle)
        Path(path).write_bytes(buf.tobytes())
        result = cli.infer(path, model_id=_model_id())
    finally:
        if path:
            try:
                os.remove(path)
            except OSError:
                pass
    if not _printed_ok:
        _printed_ok = True
        print('[roboflow] first infer ok', flush=True)
    return parse_infer_result(result, w, h)
