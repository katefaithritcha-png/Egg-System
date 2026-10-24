import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'egg_record.dart';

class EggRecordStore {
  EggRecordStore({this.filePath});

  String? filePath;
  Database? _db;
  DateTime Function() now = DateTime.now;

  Future<void> open() async {
    if (_db != null) {
      return;
    }
    final String path = filePath ?? await _defaultPath();
    filePath = path;
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE egg_records (
            id TEXT PRIMARY KEY,
            created_at TEXT NOT NULL,
            weight REAL NOT NULL,
            size_class TEXT NOT NULL,
            camera_result TEXT NOT NULL,
            sorting_result TEXT NOT NULL,
            sync_status TEXT NOT NULL,
            attempts INTEGER NOT NULL,
            next_attempt_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<String> _defaultPath() async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'egg_records.sqlite');
  }

  Database get _database {
    final Database? db = _db;
    if (db == null) {
      throw StateError('Egg record database is not open');
    }
    return db;
  }

  Future<void> insertIgnore(EggRecord record) async {
    await _database.insert(
      'egg_records',
      <String, Object?>{
        'id': record.id,
        'created_at': record.createdAt.toUtc().toIso8601String(),
        'weight': record.weight,
        'size_class': record.size,
        'camera_result': record.cameraResult,
        'sorting_result': record.sortingResult,
        'sync_status': record.syncStatus,
        'attempts': record.attempts,
        'next_attempt_at': record.nextAttemptAt.toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<EggRecord?> getById(String id) async {
    final List<Map<String, Object?>> rows = await _database.query(
      'egg_records',
      where: 'id = ?',
      whereArgs: <Object>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _fromRow(rows.first);
  }

  Future<({int pending, int synced})> counts() async {
    final int pending = Sqflite.firstIntValue(
          await _database.rawQuery(
            "SELECT COUNT(*) FROM egg_records WHERE sync_status = 'pending'",
          ),
        ) ??
        0;
    final int synced = Sqflite.firstIntValue(
          await _database.rawQuery(
            "SELECT COUNT(*) FROM egg_records WHERE sync_status = 'synced'",
          ),
        ) ??
        0;
    return (pending: pending, synced: synced);
  }

  Future<List<EggRecord>> due() async {
    final String stamp = now().toUtc().toIso8601String();
    final List<Map<String, Object?>> rows = await _database.query(
      'egg_records',
      where: "sync_status = 'pending' AND next_attempt_at <= ?",
      whereArgs: <Object>[stamp],
      orderBy: 'created_at',
      limit: 20,
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> markSynced(String id) async {
    await _database.update(
      'egg_records',
      <String, Object?>{'sync_status': 'synced'},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
  }

  Future<void> backoff(String id) async {
    final EggRecord? row = await getById(id);
    if (row == null || row.isSynced) {
      return;
    }
    final int attempts = row.attempts + 1;
    final int seconds = attempts >= 8 ? 300 : (1 << attempts);
    final DateTime next = now().toUtc().add(Duration(seconds: seconds));
    await _database.update(
      'egg_records',
      <String, Object?>{
        'attempts': attempts,
        'next_attempt_at': next.toIso8601String(),
      },
      where: "id = ? AND sync_status = 'pending'",
      whereArgs: <Object>[id],
    );
  }

  EggRecord _fromRow(Map<String, Object?> row) {
    return EggRecord(
      id: row['id'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      weight: (row['weight'] as num).toDouble(),
      size: row['size_class'] as String,
      cameraResult: row['camera_result'] as String,
      sortingResult: row['sorting_result'] as String,
      syncStatus: row['sync_status'] as String,
      attempts: row['attempts'] as int,
      nextAttemptAt: DateTime.parse(row['next_attempt_at'] as String).toUtc(),
    );
  }
}
