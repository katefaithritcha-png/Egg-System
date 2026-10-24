import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:egg_system_flutter/egg_record.dart';
import 'package:egg_system_flutter/egg_record_store.dart';
import 'package:egg_system_flutter/egg_sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('egg-sync');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Future<EggRecordStore> openStore(DateTime Function() now) async {
    final EggRecordStore store = EggRecordStore(
      filePath: '${dir.path}${Platform.pathSeparator}eggs.sqlite',
    );
    store.now = now;
    await store.open();
    return store;
  }

  test('offline create stays pending and syncs after reconnection', () async {
    final DateTime clock = DateTime.utc(2026, 10, 11, 1);
    final EggRecordStore store = await openStore(() => clock);
    final List<String> sent = <String>[];
    final EggSyncEngine engine = EggSyncEngine(
      store,
      push: (EggRecord record) async {
        sent.add(record.id);
        return EggPushResult.synced;
      },
    );
    final EggRecord created = await engine.createOffline(
      weight: 55,
      size: 'large',
      cameraResult: 'No Crack Egg',
      sortingResult: 'KEEP',
      id: 'eggrecord01',
    );
    expect(created.syncStatus, 'pending');
    expect(await engine.syncOnce(), 0);
    expect(sent, isEmpty);
    engine.serverReachable = true;
    expect(await engine.syncOnce(), 1);
    expect((await store.getById('eggrecord01'))!.isSynced, isTrue);
    await store.close();
  });

  test('interrupted upload is not marked synced and backs off', () async {
    var clock = DateTime.utc(2026, 10, 11, 2);
    final EggRecordStore store = await openStore(() => clock);
    var calls = 0;
    final EggSyncEngine engine = EggSyncEngine(
      store,
      push: (EggRecord record) async {
        calls += 1;
        throw StateError('connection dropped');
      },
    )..serverReachable = true;
    await engine.createOffline(
      weight: 42,
      size: 'small',
      cameraResult: 'Dirty Egg',
      sortingResult: 'REJECT',
      id: 'eggrecord02',
    );
    expect(await engine.syncOnce(), 0);
    final EggRecord? row = await store.getById('eggrecord02');
    expect(row!.syncStatus, 'pending');
    expect(row.attempts, 1);
    expect(await engine.syncOnce(), 0);
    expect(calls, 1);
    clock = clock.add(const Duration(seconds: 5));
    expect(await engine.syncOnce(), 0);
    expect(calls, 2);
    await store.close();
  });

  test('same id is stored once', () async {
    final EggRecordStore store = await openStore(() => DateTime.utc(2026, 10, 11));
    final EggSyncEngine engine = EggSyncEngine(
      store,
      push: (_) async => EggPushResult.failed,
    );
    await engine.createOffline(
      weight: 61,
      size: 'large',
      cameraResult: 'No Crack Egg',
      sortingResult: 'KEEP',
      id: 'eggrecord03',
    );
    await engine.createOffline(
      weight: 61,
      size: 'large',
      cameraResult: 'No Crack Egg',
      sortingResult: 'KEEP',
      id: 'eggrecord03',
    );
    final counts = await store.counts();
    expect(counts.pending, 1);
    await store.close();
  });

  test('pending rows remain after the database is reopened', () async {
    final String path = '${dir.path}${Platform.pathSeparator}eggs.sqlite';
    final EggRecordStore first = EggRecordStore(filePath: path);
    await first.open();
    final EggSyncEngine engine = EggSyncEngine(
      first,
      push: (_) async => EggPushResult.synced,
    );
    await engine.createOffline(
      weight: 70,
      size: 'jumbo',
      cameraResult: 'Crack Egg',
      sortingResult: 'REJECT',
      id: 'eggrecord04',
    );
    await first.close();

    final EggRecordStore second = EggRecordStore(filePath: path);
    await second.open();
    final EggRecord? row = await second.getById('eggrecord04');
    expect(row, isNotNull);
    expect(row!.syncStatus, 'pending');
    expect(row.weight, 70);
    expect(row.cameraResult, 'Crack Egg');
    await second.close();
  });
}
