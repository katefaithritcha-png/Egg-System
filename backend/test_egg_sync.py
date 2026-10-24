"""Offline egg queue: local save, backoff, restart, and duplicate ids."""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from egg_sync import EggRecordStore, ingest_body, sorting_result_for, valid_record_id


class EggSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'eggs.sqlite'
        self.now = [1000.0]
        self.uploads = []
        self.online = True
        self.fail = False
        self.store = EggRecordStore(
            self.path,
            uploader=self._upload,
            internet=lambda: self.online,
            clock=lambda: self.now[0],
        )

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def _upload(self, row):
        if self.fail:
            raise RuntimeError('upload interrupted')
        self.uploads.append(row['id'])
        return self.accept

    def _save(self, record_id='eggrecord01'):
        return self.store.enqueue(
            record_id=record_id,
            created_at='2026-10-11T00:00:00Z',
            weight=55.0,
            size_class='large',
            camera_result='No Crack Egg',
            sorting_result='KEEP',
        )

    def test_offline_create_stays_pending_until_server_confirms(self):
        self.online = False
        self.accept = True
        self._save()
        self.assertEqual(self.store.sync_once(), 0)
        self.assertEqual(self.store.counts()['pending'], 1)
        self.assertEqual(self.uploads, [])
        self.online = True
        self.assertEqual(self.store.sync_once(), 1)
        self.assertEqual(self.store.get('eggrecord01')['sync_status'], 'synced')

    def test_interrupted_upload_is_not_marked_synced(self):
        self.accept = True
        self.fail = True
        self._save()
        self.assertEqual(self.store.sync_once(), 0)
        row = self.store.get('eggrecord01')
        self.assertEqual(row['sync_status'], 'pending')
        self.assertEqual(row['attempts'], 1)

    def test_backoff_waits_before_retry(self):
        self.accept = False
        self._save()
        self.store.sync_once()
        self.assertEqual(len(self.uploads), 1)
        self.store.sync_once()
        self.assertEqual(len(self.uploads), 1)
        self.now[0] += 3
        self.accept = True
        self.assertEqual(self.store.sync_once(), 1)
        self.assertEqual(self.store.counts()['synced'], 1)

    def test_duplicate_id_does_not_insert_a_second_row(self):
        self._save()
        self._save()
        self.assertEqual(self.store.counts()['pending'], 1)

    def test_memory_store_clears_on_close(self):
        # No SQLite — records live in RAM only for this process.
        self._save('eggrecord02')
        self.assertIsNotNone(self.store.get('eggrecord02'))
        self.store.close()
        self.assertIsNone(self.store.get('eggrecord02'))

    def test_sorting_result_maps_quality_labels(self):
        self.assertEqual(sorting_result_for('goodEggs'), 'Good')
        self.assertEqual(sorting_result_for('crackedEggs'), 'Cracked')
        self.assertEqual(sorting_result_for('dirtyEggs'), 'Dirty')
        self.assertEqual(sorting_result_for(None), 'UNSORTED')

    def test_ingest_is_idempotent(self):
        import egg_sync

        egg_sync._STORE = self.store
        body = {
            'id': 'eggrecord03',
            'weight': 48,
            'size': 'medium',
            'cameraResult': 'Crack Egg',
            'sortingResult': 'Cracked',
            'createdAt': '2026-10-11T01:02:03Z',
        }
        self.online = False
        first, code = ingest_body(body)
        second, code2 = ingest_body(body)
        self.assertEqual(code, 200)
        self.assertEqual(code2, 200)
        self.assertEqual(first['syncStatus'], 'pending')
        self.assertEqual(second['id'], first['id'])
        self.assertEqual(self.store.counts()['pending'], 1)
        self.assertFalse(valid_record_id('bad'))


if __name__ == '__main__':
    unittest.main()
