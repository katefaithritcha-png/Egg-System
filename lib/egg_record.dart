class EggRecord {
  const EggRecord({
    required this.id,
    required this.createdAt,
    required this.weight,
    required this.size,
    required this.cameraResult,
    required this.sortingResult,
    required this.syncStatus,
    required this.attempts,
    required this.nextAttemptAt,
  });

  final String id;
  final DateTime createdAt;
  final double weight;
  final String size;
  final String cameraResult;
  final String sortingResult;
  final String syncStatus;
  final int attempts;
  final DateTime nextAttemptAt;

  bool get isSynced => syncStatus == 'synced';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'weight': weight,
        'size': size,
        'cameraResult': cameraResult,
        'sortingResult': sortingResult,
      };
}

enum EggPushResult { synced, pending, failed }
