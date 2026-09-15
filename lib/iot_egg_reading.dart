import 'package:cloud_firestore/cloud_firestore.dart';

class IotEggReading {
  const IotEggReading({
    required this.id,
    required this.weightGrams,
    required this.grade,
    required this.sizeClass,
    required this.createdAt,
    this.streamUrl,
  });

  factory IotEggReading.fromDoc(QueryDocumentSnapshot<Object?> doc) {
    final Object? raw = doc.data();
    final Map<String, dynamic> data =
        raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    DateTime created = DateTime.now().toUtc();
    final Object? rawTime = data['createdAt'];
    if (rawTime is Timestamp) {
      created = rawTime.toDate().toUtc();
    } else if (rawTime is String) {
      created = DateTime.tryParse(rawTime)?.toUtc() ?? created;
    }
    return IotEggReading(
      id: doc.id,
      weightGrams: (data['weight'] as num?)?.toDouble() ?? 0,
      grade: data['grade'] as String? ?? 'UNKNOWN',
      sizeClass: data['sizeClass'] as String? ?? '',
      createdAt: created,
      streamUrl: data['streamUrl'] as String?,
    );
  }

  final String id;
  final double weightGrams;
  final String grade;
  final String sizeClass;
  final DateTime createdAt;
  final String? streamUrl;
}
