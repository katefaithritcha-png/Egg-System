"""In-memory egg records for the live farm backend.

No SQLite file and no Firestore upload — live counts stay in RAM
(and in live_inspection_backend detection_records) only.
"""

from __future__ import annotations

import os
import re
import threading
import time
import uuid
from pathlib import Path

_ID_RE = re.compile(r'^[A-Za-z0-9_-]{8,80}$')
_LOCK = threading.Lock()
_STORE: 'EggRecordStore | None' = None


def sorting_result_for(category: str | None) -> str:
    """Map inspection category to the quality label shown on the dashboard."""
    if category == 'goodEggs':
        return 'Good'
    if category == 'crackedEggs':
        return 'Cracked'
    if category == 'dirtyEggs':
        return 'Dirty'
    return 'UNSORTED'


def valid_record_id(value: str) -> bool:
    return bool(_ID_RE.match(value or ''))


def internet_available() -> bool:
    """Cloud sync disabled — always offline for Firestore."""
    return False


def firestore_put_egg(row: dict) -> bool:
    """Disabled: project does not use Firebase egg history."""
    return False


class EggRecordStore:
    """RAM-only egg log (same API as the old SQLite store, no disk/cloud)."""

    def __init__(self, path=None, uploader=None, internet=None, clock=None):
        self.path = Path(path) if path else Path('.')
        # Default: never upload. Tests may pass a custom uploader.
        self.uploader = uploader
        self.internet = internet or internet_available
        self.clock = clock or time.time
        self._lock = threading.Lock()
        self._rows: dict[str, dict] = {}

    def close(self) -> None:
        with self._lock:
            self._rows.clear()

    def enqueue(
        self,
        *,
        record_id: str,
        created_at: str,
        weight: float,
        size_class: str,
        camera_result: str,
        sorting_result: str,
        measurement_status: str = 'uncalibrated',
        device_id: str = 'egg-station',
    ) -> dict:
        status = (measurement_status or 'uncalibrated').strip().lower()[:40]
        if status not in ('calibrated', 'uncalibrated', 'simulated'):
            status = 'uncalibrated'
        device = (device_id or 'egg-station').strip()[:64] or 'egg-station'
        with self._lock:
            if record_id in self._rows:
                return dict(self._rows[record_id])
            # No cloud sync — mark local immediately.
            sync = 'local' if self.uploader is None else 'pending'
            row = {
                'id': record_id,
                'created_at': created_at,
                'weight': float(weight),
                'size_class': size_class,
                'camera_result': (camera_result or '')[:80],
                'sorting_result': (sorting_result or '')[:80],
                'sync_status': sync,
                'attempts': 0,
                'next_attempt_at': float(self.clock()),
                'measurement_status': status,
                'device_id': device,
            }
            self._rows[record_id] = row
            return dict(row)

    def counts(self) -> dict:
        with self._lock:
            pending = sum(1 for r in self._rows.values() if r['sync_status'] == 'pending')
            synced = sum(
                1 for r in self._rows.values() if r['sync_status'] in ('synced', 'local')
            )
        return {'pending': int(pending), 'synced': int(synced)}

    def get(self, record_id: str) -> dict | None:
        with self._lock:
            row = self._rows.get(record_id)
        return dict(row) if row else None

    def recent(self, limit: int = 40) -> list[dict]:
        with self._lock:
            rows = sorted(
                self._rows.values(),
                key=lambda r: str(r.get('created_at') or ''),
                reverse=True,
            )[:limit]
        return [
            {
                'id': row['id'],
                'createdAt': row['created_at'],
                'weight': row['weight'],
                'size': row['size_class'],
                'cameraResult': row['camera_result'],
                'sortingResult': row['sorting_result'],
                'syncStatus': row['sync_status'],
                'measurementStatus': row.get('measurement_status', 'uncalibrated'),
                'deviceId': row.get('device_id', 'egg-station'),
            }
            for row in rows
        ]

    def due(self, limit: int = 20) -> list[dict]:
        if self.uploader is None:
            return []
        now = self.clock()
        with self._lock:
            rows = [
                dict(r)
                for r in self._rows.values()
                if r['sync_status'] == 'pending' and float(r.get('next_attempt_at') or 0) <= now
            ]
        rows.sort(key=lambda r: str(r.get('created_at') or ''))
        return rows[:limit]

    def mark_synced(self, record_id: str) -> None:
        with self._lock:
            row = self._rows.get(record_id)
            if row is not None:
                row['sync_status'] = 'synced'

    def backoff(self, record_id: str) -> None:
        with self._lock:
            row = self._rows.get(record_id)
            if row is None or row.get('sync_status') != 'pending':
                return
            attempts = int(row.get('attempts') or 0) + 1
            delay = min(300, 2 ** attempts)
            row['attempts'] = attempts
            row['next_attempt_at'] = float(self.clock()) + delay

    def sync_once(self) -> int:
        """No Firebase in production. Optional uploader kept for unit tests only."""
        if self.uploader is None or not self.internet():
            return 0
        done = 0
        for row in self.due():
            try:
                ok = bool(self.uploader(row))
            except Exception:
                ok = False
            if ok:
                self.mark_synced(row['id'])
                done += 1
            else:
                self.backoff(row['id'])
        return done


def _db_path() -> Path:
    # Kept for API compatibility; no file is created.
    raw = os.environ.get('EGG_SYNC_DB', '').strip()
    if raw:
        return Path(raw)
    return Path(__file__).resolve().parent / 'data' / 'egg_records.memory'


def get_store() -> EggRecordStore:
    global _STORE
    with _LOCK:
        if _STORE is None:
            _STORE = EggRecordStore(_db_path())
        return _STORE


def remember_sorted_egg(
    *,
    weight: float,
    size_class: str,
    camera_result: str,
    sorting_result: str,
    record_id: str | None = None,
    created_at: str | None = None,
    measurement_status: str = 'uncalibrated',
    device_id: str = 'egg-station',
) -> str:
    rid = (record_id or '').strip() or uuid.uuid4().hex
    if not valid_record_id(rid):
        rid = uuid.uuid4().hex
    created = created_at or time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    get_store().enqueue(
        record_id=rid,
        created_at=created,
        weight=weight,
        size_class=size_class or 'medium',
        camera_result=camera_result or '',
        sorting_result=sorting_result or 'UNSORTED',
        measurement_status=measurement_status,
        device_id=device_id,
    )
    return rid


def attach_weight_to_egg(
    record_id: str,
    *,
    weight: float,
    size_class: str,
    measurement_status: str = 'uncalibrated',
) -> bool:
    """Fill grams/size on an egg that was already counted by the camera."""
    rid = (record_id or '').strip()
    if not valid_record_id(rid):
        return False
    status = (measurement_status or 'uncalibrated').strip().lower()[:40]
    if status not in ('calibrated', 'uncalibrated', 'simulated'):
        status = 'uncalibrated'
    store = get_store()
    with store._lock:
        row = store._rows.get(rid)
        if row is None:
            return False
        row['weight'] = float(weight)
        row['size_class'] = (size_class or 'medium')[:40]
        row['measurement_status'] = status
        if store.uploader is not None:
            row['sync_status'] = 'pending'
            row['attempts'] = 0
            row['next_attempt_at'] = float(store.clock())
        else:
            row['sync_status'] = 'local'
        return True


def ingest_body(body: dict) -> tuple[dict, int]:
    rid = str(body.get('id') or '').strip()
    if not valid_record_id(rid):
        return {'ok': False, 'error': 'id required'}, 400
    try:
        weight = float(body.get('weight'))
    except (TypeError, ValueError):
        return {'ok': False, 'error': 'weight required'}, 400
    if not 0 < weight < 500:
        return {'ok': False, 'error': 'weight out of range'}, 400
    size = str(body.get('size') or body.get('sizeClass') or '').strip()[:40]
    camera = str(body.get('cameraResult') or '').strip()[:80]
    sorting = str(body.get('sortingResult') or body.get('grade') or '').strip()[:80]
    created = str(body.get('createdAt') or '').strip()[:40]
    measurement = str(body.get('measurementStatus') or 'uncalibrated').strip()[:40]
    device = str(body.get('deviceId') or 'egg-station').strip()[:64]
    if not size or not sorting or not created:
        return {'ok': False, 'error': 'size, sortingResult, and createdAt required'}, 400
    store = get_store()
    store.enqueue(
        record_id=rid,
        created_at=created,
        weight=weight,
        size_class=size,
        camera_result=camera,
        sorting_result=sorting,
        measurement_status=measurement,
        device_id=device,
    )
    store.sync_once()
    row = store.get(rid) or {}
    return {
        'ok': True,
        'id': rid,
        'syncStatus': row.get('sync_status', 'local'),
    }, 200
