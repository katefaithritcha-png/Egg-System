import 'package:cloud_firestore/cloud_firestore.dart';

class IotEggReading {
  const IotEggReading({
    required this.id,
    required this.weightGrams,
    required this.grade,
    required this.sizeClass,
    required this.createdAt,
    this.streamUrl,
    this.cameraResult,
    this.measurementStatus = 'uncalibrated',
    this.deviceId,
    this.verifiedWeight = false,
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
    final String status =
        (data['measurementStatus'] as String? ?? 'uncalibrated').toLowerCase();
    final bool verified = data['verifiedWeight'] == true || status == 'calibrated';
    return IotEggReading(
      id: doc.id,
      weightGrams: (data['weight'] as num?)?.toDouble() ?? 0,
      grade: data['grade'] as String? ?? 'UNKNOWN',
      sizeClass: data['sizeClass'] as String? ?? '',
      createdAt: created,
      streamUrl: data['streamUrl'] as String?,
      cameraResult: data['cameraResult'] as String?,
      measurementStatus: status,
      deviceId: data['deviceId'] as String?,
      verifiedWeight: verified,
    );
  }

  final String id;
  final double weightGrams;
  final String grade;
  final String sizeClass;
  final DateTime createdAt;
  final String? streamUrl;
  final String? cameraResult;
  final String measurementStatus;
  final String? deviceId;
  final bool verifiedWeight;

  bool get isSimulated => measurementStatus == 'simulated';
  bool get isUncalibrated =>
      !verifiedWeight && measurementStatus != 'calibrated';

  String get measurementBanner {
    if (isSimulated) return 'SIMULATED — integration test';
    if (isUncalibrated) return 'UNCALIBRATED — not production mass';
    return 'CALIBRATED';
  }

  /// Normalized quality label for UI: Good, Cracked, or Dirty.
  String get displayGrade {
    final String combined =
        '${grade.toLowerCase()} ${(cameraResult ?? '').toLowerCase()}';
    if (combined.contains('crack') || combined.contains('broken')) {
      return 'Cracked';
    }
    if (combined.contains('dirty') ||
        combined.contains('soil') ||
        combined.contains('stain')) {
      return 'Dirty';
    }
    if (combined.contains('good') ||
        combined.contains('clean') ||
        combined.contains('no crack') ||
        combined.contains('keep') ||
        combined.contains('ok')) {
      return 'Good';
    }
    return grade;
  }
}
