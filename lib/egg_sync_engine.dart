import 'dart:math';

import 'egg_record.dart';
import 'egg_record_store.dart';

class EggSyncEngine {
  EggSyncEngine(this.store, {required this.push});

  final EggRecordStore store;
  final Future<EggPushResult> Function(EggRecord record) push;
  bool serverReachable = false;

  Future<EggRecord> createOffline({
    required double weight,
    required String size,
    required String cameraResult,
    required String sortingResult,
    String? id,
  }) async {
    final DateTime created = store.now().toUtc();
    final EggRecord record = EggRecord(
      id: id ?? _newId(created),
      createdAt: created,
      weight: weight,
      size: size,
      cameraResult: cameraResult,
      sortingResult: sortingResult,
      syncStatus: 'pending',
      attempts: 0,
      nextAttemptAt: created,
    );
    await store.insertIgnore(record);
    return record;
  }

  Future<int> syncOnce() async {
    if (!serverReachable) {
      return 0;
    }
    var synced = 0;
    for (final EggRecord record in await store.due()) {
      try {
        final EggPushResult result = await push(record);
        if (result == EggPushResult.synced) {
          await store.markSynced(record.id);
          synced += 1;
        } else {
          await store.backoff(record.id);
        }
      } catch (_) {
        await store.backoff(record.id);
      }
    }
    return synced;
  }

  String _newId(DateTime created) {
    final int salt = Random().nextInt(0xFFFFFF);
    return 'egg${created.microsecondsSinceEpoch.toRadixString(16)}${salt.toRadixString(16)}';
  }
}
