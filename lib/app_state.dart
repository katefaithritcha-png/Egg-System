import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

import 'auth_api.dart';
import 'api_config.dart';
import 'iot_egg_reading.dart';
import 'offline_store.dart';

class ProductionRecord {
  const ProductionRecord({
    required this.id,
    required this.date,
    required this.timeSlot,
    required this.source,
    required this.count,
    required this.method,
  });

  factory ProductionRecord.fromJson(Map<String, dynamic> json) {
    return ProductionRecord(
      id: json['id'] as String? ?? '',
      date: json['date'] as String? ?? '',
      timeSlot: json['timeSlot'] as String? ?? '',
      source: json['source'] as String? ?? '',
      count: json['count'] as int? ?? 0,
      method: json['method'] as String? ?? 'Manual',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'date': date,
        'timeSlot': timeSlot,
        'source': source,
        'count': count,
        'method': method,
      };

  final String id;
  final String date;
  final String timeSlot;
  final String source;
  final int count;
  final String method;
}

class GradingRecord {
  const GradingRecord({
    required this.id,
    required this.date,
    required this.time,
    required this.batchId,
    required this.size,
    required this.quality,
    required this.quantity,
    required this.gradedBy,
  });

  factory GradingRecord.fromJson(Map<String, dynamic> json) {
    return GradingRecord(
      id: json['id'] as String? ?? '',
      date: json['date'] as String? ?? '',
      time: json['time'] as String? ?? '',
      batchId: json['batchId'] as String? ?? '',
      size: json['size'] as String? ?? '',
      quality: json['quality'] as String? ?? '',
      quantity: json['quantity'] as int? ?? 0,
      gradedBy: json['gradedBy'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'date': date,
        'time': time,
        'batchId': batchId,
        'size': size,
        'quality': quality,
        'quantity': quantity,
        'gradedBy': gradedBy,
      };

  final String id;
  final String date;
  final String time;
  final String batchId;
  final String size;
  final String quality;
  final int quantity;
  final String gradedBy;
}

class GradingSummary {
  const GradingSummary({
    required this.label,
    required this.quantity,
    required this.color,
  });

  final String label;
  final int quantity;
  final Color color;
}

class InventoryItem {
  const InventoryItem({
    required this.id,
    required this.name,
    required this.sku,
    required this.category,
    required this.zoneId,
    required this.quantity,
    required this.minThreshold,
    required this.maxCapacity,
    required this.unit,
  });

  final String id;
  final String name;
  final String sku;
  final String category;
  final String? zoneId;
  final int quantity;
  final int minThreshold;
  final int maxCapacity;
  final String unit;

  factory InventoryItem.fromJson(Map<String, dynamic> json) {
    return InventoryItem(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      sku: json['sku'] as String? ?? '',
      category: json['category'] as String? ?? '',
      zoneId: json['zoneId'] as String?,
      quantity: json['quantity'] as int? ?? 0,
      minThreshold: json['minThreshold'] as int? ?? 0,
      maxCapacity: json['maxCapacity'] as int? ?? 0,
      unit: json['unit'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'sku': sku,
        'category': category,
        'zoneId': zoneId,
        'quantity': quantity,
        'minThreshold': minThreshold,
        'maxCapacity': maxCapacity,
        'unit': unit,
      };
}

class InventoryZone {
  const InventoryZone({required this.id, required this.name});

  factory InventoryZone.fromJson(Map<String, dynamic> json) {
    return InventoryZone(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
      };

  final String id;
  final String name;
}

class InventoryMovement {
  const InventoryMovement({
    required this.id,
    required this.itemId,
    required this.movementType,
    required this.source,
    required this.quantityDelta,
    required this.quantityAfter,
    required this.timestamp,
    this.note,
  });

  final String id;
  final String itemId;
  final String movementType;
  final String source;
  final int quantityDelta;
  final int quantityAfter;
  final String timestamp;
  final String? note;

  factory InventoryMovement.fromJson(Map<String, dynamic> json) {
    return InventoryMovement(
      id: json['id'] as String? ?? '',
      itemId: json['itemId'] as String? ?? '',
      movementType: json['movementType'] as String? ?? '',
      source: json['source'] as String? ?? '',
      quantityDelta: json['quantityDelta'] as int? ?? 0,
      quantityAfter: json['quantityAfter'] as int? ?? 0,
      timestamp: json['timestamp'] as String? ?? '',
      note: json['note'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'itemId': itemId,
        'movementType': movementType,
        'source': source,
        'quantityDelta': quantityDelta,
        'quantityAfter': quantityAfter,
        'timestamp': timestamp,
        'note': note,
      };
}

class InventoryDevice {
  const InventoryDevice({
    required this.id,
    required this.deviceId,
    required this.name,
    required this.zoneId,
    required this.isActive,
    required this.lastSeenLabel,
  });

  final String id;
  final String deviceId;
  final String name;
  final String? zoneId;
  final bool isActive;
  final String lastSeenLabel;

  factory InventoryDevice.fromJson(Map<String, dynamic> json) {
    return InventoryDevice(
      id: json['id'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      zoneId: json['zoneId'] as String?,
      isActive: json['isActive'] as bool? ?? false,
      lastSeenLabel: json['lastSeenLabel'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'deviceId': deviceId,
        'name': name,
        'zoneId': zoneId,
        'isActive': isActive,
        'lastSeenLabel': lastSeenLabel,
      };
}

class AlertMessage {
  const AlertMessage({required this.title, required this.severity});

  final String title;
  final String severity;
}

class InsightNote {
  const InsightNote({required this.title, required this.description});

  final String title;
  final String description;
}

class ReportTrendPoint {
  const ReportTrendPoint({
    required this.label,
    required this.production,
    required this.sales,
    required this.losses,
    required this.graded,
    required this.collected,
  });

  final String label;
  final int production;
  final int sales;
  final int losses;
  final int graded;
  final int collected;
}

class ReportMetric {
  const ReportMetric({
    required this.label,
    required this.value,
    required this.change,
  });

  final String label;
  final String value;
  final double change;
}

class ReportModuleSummary {
  const ReportModuleSummary({
    required this.module,
    required this.icon,
    required this.color,
    required this.metrics,
  });

  final String module;
  final IconData icon;
  final Color color;
  final List<ReportMetric> metrics;
}

class ReportBreakdownRow {
  const ReportBreakdownRow({
    required this.label,
    required this.production,
    required this.sales,
    required this.losses,
  });

  final String label;
  final int production;
  final int sales;
  final int losses;
}

enum AppRole { admin, worker }

class DemoUser {
  const DemoUser({
    required this.name,
    required this.email,
    required this.role,
    required this.assignedZone,
    this.emailVerified = false,
    this.passwordChangedAt,
  });

  factory DemoUser.fromJson(Map<String, dynamic> json) {
    final String roleName = (json['role'] as String? ?? 'worker').toLowerCase();
    return DemoUser(
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      role: roleName == 'admin' ? AppRole.admin : AppRole.worker,
      assignedZone: json['assignedZone'] as String? ?? 'Unassigned',
      emailVerified: json['emailVerified'] as bool? ?? false,
      passwordChangedAt: json['passwordChangedAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'email': email,
        'role': role == AppRole.admin ? 'admin' : 'worker',
        'assignedZone': assignedZone,
        'emailVerified': emailVerified,
        'passwordChangedAt': passwordChangedAt,
      };

  final String name;
  final String email;
  final AppRole role;
  final String assignedZone;
  final bool emailVerified;
  final String? passwordChangedAt;
}

// ── Worker model classes ───────────────────────────────────────────────────

class WorkerActivity {
  WorkerActivity({
    required this.message,
    required this.time,
    required this.icon,
  });

  final String message;
  final String time;
  final IconData icon;
}

enum WorkerNotificationType { warning, success, info }

class WorkerNotification {
  WorkerNotification({
    required this.message,
    required this.type,
    required this.read,
  });

  final String message;
  final WorkerNotificationType type;
  bool read;
}

/// A single confirmed detection record returned from the backend /records endpoint.
class DetectionRecord {
  const DetectionRecord({
    required this.timestamp,
    required this.label,
    required this.confidence,
    required this.category,
    required this.weightGrams,
    required this.sizeClass,
  });

  factory DetectionRecord.fromJson(Map<String, dynamic> json) {
    final double w = (json['weightGrams'] as num?)?.toDouble() ?? 0.0;
    return DetectionRecord(
      timestamp: json['timestamp'] as String? ?? '',
      label: json['label'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      category: json['category'] as String? ?? '',
      weightGrams: w,
      sizeClass: EggSizeClass.fromGrams(w),
    );
  }

  final String timestamp;
  final String label;
  final double confidence;
  final String category;
  final double weightGrams;
  final EggSizeClass sizeClass;
}

// ── Egg size classification ────────────────────────────────────────────────

enum EggSizeClass {
  peewee,
  small,
  medium,
  large,
  extraLarge,
  jumbo;

  /// Classify a raw weight in grams into a size class using the standard
  /// thresholds requested:
  ///   Peewee   < 40 g
  ///   Small    40.0 – 47.0 g
  ///   Medium   47.1 – 54.0 g
  ///   Large    54.1 – 61.3 g
  ///   XL       61.4 – 68.5 g
  ///   Jumbo    > 68.5 g
  static EggSizeClass fromGrams(double g) {
    if (g < 40.0) return EggSizeClass.peewee;
    if (g <= 47.0) return EggSizeClass.small;
    if (g <= 54.0) return EggSizeClass.medium;
    if (g <= 61.3) return EggSizeClass.large;
    if (g <= 68.5) return EggSizeClass.extraLarge;
    return EggSizeClass.jumbo;
  }

  /// Short display label shown in badges and chips.
  String get label {
    switch (this) {
      case EggSizeClass.peewee:
        return 'Peewee';
      case EggSizeClass.small:
        return 'Small';
      case EggSizeClass.medium:
        return 'Medium';
      case EggSizeClass.large:
        return 'Large';
      case EggSizeClass.extraLarge:
        return 'XL';
      case EggSizeClass.jumbo:
        return 'Jumbo';
    }
  }

  /// Abbreviated code used in compact display (e.g. badge inside a card).
  String get code {
    switch (this) {
      case EggSizeClass.peewee:
        return 'PWI';
      case EggSizeClass.small:
        return 'SM';
      case EggSizeClass.medium:
        return 'MD';
      case EggSizeClass.large:
        return 'LG';
      case EggSizeClass.extraLarge:
        return 'XL';
      case EggSizeClass.jumbo:
        return 'JMB';
    }
  }

  /// Gram range description for tooltips/detail views.
  String get rangeLabel {
    switch (this) {
      case EggSizeClass.peewee:
        return '< 40 g';
      case EggSizeClass.small:
        return '40 – 47 g';
      case EggSizeClass.medium:
        return '47.1 – 54 g';
      case EggSizeClass.large:
        return '54.1 – 61.3 g';
      case EggSizeClass.extraLarge:
        return '61.4 – 68.5 g';
      case EggSizeClass.jumbo:
        return '> 68.5 g';
    }
  }
}

class AppState extends ChangeNotifier {
  static const String _sessionStorageKey = 'egg_system.session_token';

  DemoUser? _currentUser;
  String? _sessionToken;
  DateTime? _sessionExpiresAt;
  Timer? _sessionExpiryTimer;
  Timer? _sessionHeartbeatTimer;
  String backendBaseUrl = ApiConfig.initialUrl;
  late AuthApi _authApi = AuthApi(baseUrl: backendBaseUrl);

  String get liveInspectionBackendUrl => backendBaseUrl;

  /// Called after a live session is cleared so the UI can return to sign-in.
  VoidCallback? onUnauthenticated;

  // ── Live inspection ─────────────────────────────────────────────────────
  int liveGoodEggs = 0;
  int liveCrackedEggs = 0;
  int liveDirtyEggs = 0;
  String liveInspectionStatus = 'Waiting for live inspection data';
  String liveLastLabel = 'N/A';
  double liveLastConfidence = 0.0;
  bool liveInspectionConnected = false;

  double liveLastWeightGrams = 0.0;
  EggSizeClass liveLastSizeClass = EggSizeClass.medium;

  List<DetectionRecord> detectionRecords = const <DetectionRecord>[];

  // ── Worker state ─────────────────────────────────────────────────────────
  /// Today's egg collection total (worker-editable via Production screen).
  int workerTodayCollection = 0;

  /// Submission status for each daily record type.
  Map<String, bool> workerSubmissions = <String, bool>{
    'Production': false,
    'Grading': false,
    'Damaged / Rejected': false,
  };

  /// Checklist tasks for the worker — key is task label, value = done.
  Map<String, bool> workerTasks = <String, bool>{
    'Submit morning egg collection': false,
    'Complete grading record': false,
    'Record damaged or rejected eggs': false,
    'Review incomplete submissions': false,
  };

  /// Recent activity feed entries (newest first).
  List<WorkerActivity> workerActivities = <WorkerActivity>[];

  /// Contextual notifications for the worker (unread first).
  List<WorkerNotification> workerNotifications = <WorkerNotification>[];

  int get workerPendingTaskCount =>
      workerTasks.values.where((bool done) => !done).length;

  int get workerUnreadCount =>
      workerNotifications.where((WorkerNotification n) => !n.read).length;

  int get workerDamagedCount => liveCrackedEggs + liveDirtyEggs;

  /// Toggle a task done/undone and notify listeners.
  void toggleWorkerTask(String taskLabel) {
    if (workerTasks.containsKey(taskLabel)) {
      workerTasks[taskLabel] = !(workerTasks[taskLabel]!);
      // Add to activity feed when marking done.
      if (workerTasks[taskLabel]!) {
        workerActivities.insert(
          0,
          WorkerActivity(
            message: 'Completed: $taskLabel',
            time: 'just now',
            icon: Icons.check_circle_rounded,
          ),
        );
      }
      notifyListeners();
      unawaited(persistFarm());
    }
  }

  /// Mark a submission type as submitted and add to activity feed.
  void markSubmitted(String type) {
    workerSubmissions[type] = true;
    workerActivities.insert(
      0,
      WorkerActivity(
        message: 'Submitted $type record',
        time: 'just now',
        icon: Icons.upload_rounded,
      ),
    );
    notifyListeners();
    unawaited(persistFarm());
  }

  /// Mark all notifications as read.
  void markAllNotificationsRead() {
    for (final WorkerNotification n in workerNotifications) {
      n.read = true;
    }
    notifyListeners();
  }

  Timer? _livePollingTimer;
  Timer? _connectivityTimer;
  bool backendReachable = false;
  bool farmSyncPending = false;
  List<IotEggReading> iotReadings = <IotEggReading>[];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _iotSubscription;

  AppState();

  String get connectionLabel =>
      backendReachable ? 'Online — syncing when possible' : 'Offline — data saved on this device';

  DemoUser? get currentUser => _currentUser;
  bool get isAuthenticated =>
      _currentUser != null &&
      _sessionToken != null &&
      (_sessionExpiresAt == null ||
          _sessionExpiresAt!.isAfter(DateTime.now().toUtc()));
  bool get isAdmin => _currentUser?.role == AppRole.admin;
  AppRole? get role => _currentUser?.role;
  DateTime? get sessionExpiresAt => _sessionExpiresAt;

  void startLiveInspectionPolling({
    Duration interval = const Duration(seconds: 3),
  }) {
    _livePollingTimer?.cancel();
    unawaited(_pollLiveInspectionMetrics());
    _livePollingTimer = Timer.periodic(
      interval,
      (_) => _pollLiveInspectionMetrics(),
    );
  }

  void stopLiveInspectionPolling() {
    _livePollingTimer?.cancel();
    _livePollingTimer = null;
  }

  Future<void> _pollLiveInspectionMetrics() async {
    final List<String> urls = ApiConfig.candidates(
      preferred: liveInspectionBackendUrl,
    );
    http.Response? metricsResp;
    http.Response? recordsResp;
    String? usedBase;
    try {
      for (final String base in urls) {
        try {
          final Uri metricsEndpoint = Uri.parse('$base/metrics');
          final http.Response candidate = await http
              .get(metricsEndpoint)
              .timeout(const Duration(seconds: 2));
          if (candidate.statusCode == 200 && candidate.body.isNotEmpty) {
            metricsResp = candidate;
            usedBase = base;
            try {
              recordsResp = await http
                  .get(Uri.parse('$base/records'))
                  .timeout(const Duration(seconds: 2));
            } catch (_) {}
            break;
          }
        } catch (_) {
          continue;
        }
      }

      if (metricsResp == null || usedBase == null) {
        final bool iotUp = iotReadings.isNotEmpty;
        updateLiveInspection(
          goodEggs: liveGoodEggs,
          crackedEggs: liveCrackedEggs,
          dirtyEggs: liveDirtyEggs,
          status: iotUp
              ? liveInspectionStatus
              : (backendReachable
                  ? 'Farm PC is online. Waiting for ESP32-CAM heartbeat.'
                  : 'Cannot reach live inspection on port 8000.'),
          lastLabel: liveLastLabel,
          lastConfidence: liveLastConfidence,
          connected: iotUp,
        );
        return;
      }

      if (usedBase != backendBaseUrl) {
        backendBaseUrl = usedBase;
        _authApi = AuthApi(baseUrl: usedBase);
        backendReachable = true;
      }

      final Object? parsed = jsonDecode(metricsResp.body);
      if (parsed is! Map) {
        return;
      }
      final Map<String, dynamic> data = Map<String, dynamic>.from(parsed);

      final bool backendConnected = data['connected'] == true;
      final bool hardwareOnline = data['hardwareOnline'] == true;
      final bool iotUp = iotReadings.isNotEmpty;
      final bool live = backendConnected || hardwareOnline || iotUp;

      final double backendWeight =
          (data['lastWeightGrams'] as num?)?.toDouble() ?? 0.0;
      // Prefer a real scale reading over a zero/empty metrics weight.
      final double lastWeight = backendWeight >= 5.0
          ? backendWeight
          : (liveLastWeightGrams >= 5.0 ? liveLastWeightGrams : backendWeight);
      final EggSizeClass lastSize = _sizeClassFromString(
        data['lastSizeClass'] as String? ?? '',
        fallback: EggSizeClass.fromGrams(lastWeight),
      );

      updateLiveInspection(
        goodEggs: data['goodEggs'] as int? ?? liveGoodEggs,
        crackedEggs: data['crackedEggs'] as int? ?? liveCrackedEggs,
        dirtyEggs: data['dirtyEggs'] as int? ?? liveDirtyEggs,
        status: live
            ? (data['status'] as String? ?? 'Live inspection running')
            : 'Farm PC is online. Waiting for ESP32-CAM heartbeat.',
        lastLabel: data['lastLabel'] as String? ?? liveLastLabel,
        lastConfidence:
            (data['lastConfidence'] as num?)?.toDouble() ?? liveLastConfidence,
        connected: live,
        lastWeightGrams: lastWeight,
        lastSizeClass: lastSize,
      );

      final http.Response? records = recordsResp;
      if (records != null &&
          records.statusCode == 200 &&
          records.body.isNotEmpty) {
        final Object? raw = jsonDecode(records.body);
        if (raw is List) {
          detectionRecords = raw
              .whereType<Map>()
              .map(
                (Map<dynamic, dynamic> row) => DetectionRecord.fromJson(
                  Map<String, dynamic>.from(row),
                ),
              )
              .toList();
        }
      }
    } catch (_) {
      updateLiveInspection(
        goodEggs: liveGoodEggs,
        crackedEggs: liveCrackedEggs,
        dirtyEggs: liveDirtyEggs,
        status: iotReadings.isNotEmpty
            ? liveInspectionStatus
            : (backendReachable
                ? 'Farm PC is online. Waiting for ESP32-CAM heartbeat.'
                : 'Backend offline'),
        lastLabel: liveLastLabel,
        lastConfidence: liveLastConfidence,
        connected: iotReadings.isNotEmpty,
      );
    }
  }

  void updateLiveInspection({
    required int goodEggs,
    required int crackedEggs,
    required int dirtyEggs,
    required String status,
    required String lastLabel,
    required double lastConfidence,
    required bool connected,
    double lastWeightGrams = 0.0,
    EggSizeClass? lastSizeClass,
  }) {
    liveGoodEggs = goodEggs;
    liveCrackedEggs = crackedEggs;
    liveDirtyEggs = dirtyEggs;
    liveInspectionStatus = status;
    liveLastLabel = lastLabel;
    liveLastConfidence = lastConfidence;
    liveInspectionConnected = connected;
    liveLastWeightGrams = lastWeightGrams;
    liveLastSizeClass =
        lastSizeClass ?? EggSizeClass.fromGrams(lastWeightGrams);
    notifyListeners();
  }

  /// Convert the snake_case string returned by the backend into the local enum.
  static EggSizeClass _sizeClassFromString(
    String raw, {
    required EggSizeClass fallback,
  }) {
    switch (raw) {
      case 'peewee':
        return EggSizeClass.peewee;
      case 'small':
        return EggSizeClass.small;
      case 'medium':
        return EggSizeClass.medium;
      case 'large':
        return EggSizeClass.large;
      case 'extraLarge':
        return EggSizeClass.extraLarge;
      case 'jumbo':
        return EggSizeClass.jumbo;
      default:
        return fallback;
    }
  }

  /// POSTs /reset to the backend, zeroes local counters, and clears the
  /// detection log immediately so the UI reacts before the next poll cycle.
  Future<void> resetCounters() async {
    final Uri endpoint = Uri.parse('$liveInspectionBackendUrl/reset');
    try {
      await http.post(endpoint).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Ignore network errors — local reset still applies.
    }
    detectionRecords = const <DetectionRecord>[];
    updateLiveInspection(
      goodEggs: 0,
      crackedEggs: 0,
      dirtyEggs: 0,
      status: 'Counters reset',
      lastLabel: 'N/A',
      lastConfidence: 0.0,
      connected: liveInspectionConnected,
      lastWeightGrams: 0.0,
      lastSizeClass: EggSizeClass.medium,
    );
    unawaited(persistFarm());
  }

  List<ProductionRecord> productionRecords = <ProductionRecord>[];

  List<GradingRecord> gradingRecords = <GradingRecord>[];

  final List<GradingSummary> gradingSummary = const <GradingSummary>[
    GradingSummary(label: 'Good', quantity: 0, color: Colors.green),
    GradingSummary(label: 'Cracked', quantity: 0, color: Colors.orange),
    GradingSummary(label: 'Rejected', quantity: 0, color: Colors.red),
  ];

  List<InventoryItem> inventoryItems = const <InventoryItem>[
    InventoryItem(
      id: 'inv-egg-a',
      name: 'Grade A Eggs',
      sku: 'EGG-A-001',
      category: 'Sellable Eggs',
      zoneId: 'zone-cold-1',
      quantity: 0,
      minThreshold: 0,
      maxCapacity: 4000,
      unit: 'eggs',
    ),
    InventoryItem(
      id: 'inv-egg-b',
      name: 'Grade B Eggs',
      sku: 'EGG-B-002',
      category: 'Sellable Eggs',
      zoneId: 'zone-cold-1',
      quantity: 0,
      minThreshold: 0,
      maxCapacity: 2600,
      unit: 'eggs',
    ),
    InventoryItem(
      id: 'inv-cracked',
      name: 'Cracked Eggs',
      sku: 'EGG-C-010',
      category: 'Non-Sellable',
      zoneId: 'zone-qc',
      quantity: 0,
      minThreshold: 0,
      maxCapacity: 900,
      unit: 'eggs',
    ),
    InventoryItem(
      id: 'inv-reject',
      name: 'Rejected Eggs',
      sku: 'EGG-R-015',
      category: 'Waste',
      zoneId: 'zone-qc',
      quantity: 0,
      minThreshold: 0,
      maxCapacity: 250,
      unit: 'eggs',
    ),
    InventoryItem(
      id: 'inv-trays',
      name: 'Trays',
      sku: 'SUP-TRAY-020',
      category: 'Packaging',
      zoneId: 'zone-pack',
      quantity: 0,
      minThreshold: 0,
      maxCapacity: 400,
      unit: 'trays',
    ),
    InventoryItem(
      id: 'inv-feed',
      name: 'Feed Stock',
      sku: 'SUP-FEED-100',
      category: 'Supplies',
      zoneId: 'zone-feed',
      quantity: 0,
      minThreshold: 0,
      maxCapacity: 300,
      unit: 'bags',
    ),
  ];

  List<InventoryZone> inventoryZones = const <InventoryZone>[
    InventoryZone(id: 'zone-cold-1', name: 'Cold Room 1'),
    InventoryZone(id: 'zone-pack', name: 'Packing Area'),
    InventoryZone(id: 'zone-qc', name: 'Quality Control'),
    InventoryZone(id: 'zone-feed', name: 'Feed Warehouse'),
  ];

  List<InventoryMovement> inventoryMovements = const <InventoryMovement>[];

  List<InventoryDevice> inventoryDevices = const <InventoryDevice>[
    InventoryDevice(
      id: 'dev-1',
      deviceId: 'machine-01',
      name: 'Sorting Line A',
      zoneId: 'zone-qc',
      isActive: false,
      lastSeenLabel: 'waiting',
    ),
    InventoryDevice(
      id: 'dev-2',
      deviceId: 'machine-02',
      name: 'Cold Room Counter',
      zoneId: 'zone-cold-1',
      isActive: false,
      lastSeenLabel: 'waiting',
    ),
    InventoryDevice(
      id: 'dev-3',
      deviceId: 'machine-03',
      name: 'Feed Release Hopper',
      zoneId: 'zone-feed',
      isActive: false,
      lastSeenLabel: 'waiting',
    ),
  ];

  final List<AlertMessage> alerts = const <AlertMessage>[];

  final List<InsightNote> reportInsights = const <InsightNote>[];

  final List<ReportTrendPoint> reportTrendPoints = const <ReportTrendPoint>[];

  final List<ReportModuleSummary>
  reportModuleSummaries = const <ReportModuleSummary>[
    ReportModuleSummary(
      module: 'Production',
      icon: Icons.egg_alt_outlined,
      color: Colors.amber,
      metrics: <ReportMetric>[
        ReportMetric(label: 'Total Produced', value: '0', change: 0),
        ReportMetric(label: 'Avg Daily', value: '0', change: 0),
        ReportMetric(label: 'Peak Day', value: '0', change: 0),
      ],
    ),
    ReportModuleSummary(
      module: 'Sales',
      icon: Icons.bar_chart_rounded,
      color: Colors.green,
      metrics: <ReportMetric>[
        ReportMetric(label: 'Total Revenue', value: 'PHP 0', change: 0),
        ReportMetric(label: 'Eggs Sold', value: '0', change: 0),
        ReportMetric(label: 'Avg Price/Tray', value: 'PHP 0', change: 0),
      ],
    ),
    ReportModuleSummary(
      module: 'Inventory',
      icon: Icons.inventory_2_outlined,
      color: Colors.lightBlue,
      metrics: <ReportMetric>[
        ReportMetric(label: 'Current Stock', value: '0', change: 0),
        ReportMetric(label: 'Turnover Rate', value: '0', change: 0),
        ReportMetric(label: 'Low Stock Alerts', value: '0', change: 0),
      ],
    ),
    ReportModuleSummary(
      module: 'Grading',
      icon: Icons.star_outline_rounded,
      color: Colors.orange,
      metrics: <ReportMetric>[
        ReportMetric(label: 'Grade A Rate', value: '0%', change: 0),
        ReportMetric(label: 'Cracked', value: '0%', change: 0),
        ReportMetric(label: 'Total Graded', value: '0', change: 0),
      ],
    ),
    ReportModuleSummary(
      module: 'Losses',
      icon: Icons.warning_amber_rounded,
      color: Colors.redAccent,
      metrics: <ReportMetric>[
        ReportMetric(label: 'Total Lost', value: '0', change: 0),
        ReportMetric(label: 'Loss Rate', value: '0%', change: 0),
        ReportMetric(label: 'Top Cause', value: 'None', change: 0),
      ],
    ),
    ReportModuleSummary(
      module: 'Collection',
      icon: Icons.schedule_outlined,
      color: Colors.deepPurpleAccent,
      metrics: <ReportMetric>[
        ReportMetric(label: 'Completion Rate', value: '0%', change: 0),
        ReportMetric(label: 'On-Time %', value: '0%', change: 0),
        ReportMetric(label: 'Missed Rounds', value: '0', change: 0),
      ],
    ),
  ];

  final List<ReportBreakdownRow> reportWeeklyBreakdown = const <ReportBreakdownRow>[];

  int get todayProductionTotal {
    if (productionRecords.isEmpty) {
      return 0;
    }
    final String today = _isoDate(DateTime.now());
    final int todaySum = productionRecords
        .where((ProductionRecord record) => record.date == today)
        .fold<int>(0, (int sum, ProductionRecord record) => sum + record.count);
    if (todaySum > 0) {
      return todaySum;
    }
    final List<String> dates =
        productionRecords.map((ProductionRecord r) => r.date).toSet().toList()
          ..sort();
    final String latest = dates.last;
    return productionRecords
        .where((ProductionRecord record) => record.date == latest)
        .fold<int>(0, (int sum, ProductionRecord record) => sum + record.count);
  }

  int get totalInventoryUnits =>
      inventoryItems.fold<int>(0, (sum, item) => sum + item.quantity);

  int get lowStockCount => inventoryItems
      .where((item) => item.minThreshold > 0 && item.quantity <= item.minThreshold)
      .length;

  static String _isoDate(DateTime date) {
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  Future<void> restoreLocalSession() async {
    try {
      await _loadFarmFromDisk();
    } catch (_) {}
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? token = prefs.getString(_sessionStorageKey);
      if (token == null || token.isEmpty) {
        return;
      }
      await _restoreOfflineSession(token, notify: false);
    } catch (_) {}
  }

  Future<void> startBackgroundServices() async {
    await connectBackend(silent: true);
    _startConnectivityWatch();
    startLiveInspectionPolling();
    await _clearIotReadingsOnce();
    startIotReadingsListener();
    final String? token = _sessionToken;
    if (token != null) {
      unawaited(_refreshSessionFromServer(token));
    }
  }

  Future<bool> connectBackend({bool silent = false}) async {
    final String? found = await ApiConfig.discover(preferred: backendBaseUrl);
    if (found == null) {
      backendReachable = false;
      if (!silent) {
        throw AuthException(
          'Cannot reach the farm computer. Put this phone on the same Wi-Fi as the PC and keep the auth server running on port 8000.',
          code: 'backend_unreachable',
        );
      }
      return false;
    }
    if (found != backendBaseUrl) {
      backendBaseUrl = found;
      _authApi = AuthApi(baseUrl: found);
    }
    backendReachable = true;
    return true;
  }

  Future<void> _clearIotReadingsOnce() async {
    const String flag = 'egg_system.iot_cleared_once';
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(flag) == true || Firebase.apps.isEmpty) {
      return;
    }
    try {
      final QuerySnapshot<Map<String, dynamic>> snap = await FirebaseFirestore
          .instance
          .collection('egg_readings')
          .get();
      for (int i = 0; i < snap.docs.length; i += 400) {
        final WriteBatch batch = FirebaseFirestore.instance.batch();
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
            in snap.docs.skip(i).take(400)) {
          batch.delete(doc.reference);
        }
        await batch.commit();
      }
      await prefs.setBool(flag, true);
      iotReadings = <IotEggReading>[];
      liveLastWeightGrams = 0;
      notifyListeners();
    } catch (_) {}
  }

  void startIotReadingsListener() {
    _iotSubscription?.cancel();
    if (Firebase.apps.isEmpty) {
      return;
    }
    try {
      _iotSubscription = FirebaseFirestore.instance
          .collection('egg_readings')
          .limit(40)
          .snapshots()
          .listen(
            (QuerySnapshot<Map<String, dynamic>> snapshot) {
              final List<IotEggReading> next = snapshot.docs
                  .map(IotEggReading.fromDoc)
                  .toList()
                ..sort(
                  (IotEggReading a, IotEggReading b) =>
                      b.createdAt.compareTo(a.createdAt),
                );
              iotReadings = next;
              if (next.isNotEmpty) {
                final IotEggReading latest = next.first;
                if (latest.weightGrams >= 5.0) {
                  liveLastWeightGrams = latest.weightGrams;
                  liveLastSizeClass =
                      EggSizeClass.fromGrams(latest.weightGrams);
                  liveInspectionStatus =
                      'IoT scale: ${latest.weightGrams.toStringAsFixed(1)} g (${latest.grade})';
                  liveInspectionConnected = true;
                }
              }
              notifyListeners();
            },
            onError: (Object error) {
              liveInspectionStatus = 'Firestore IoT error: $error';
              notifyListeners();
            },
          );
    } catch (_) {}
  }

  Future<void> restoreSession() => restoreLocalSession();

  Future<void> _refreshSessionFromServer(String token) async {
    try {
      final result = await _authApi.me(
        token,
        timeout: const Duration(seconds: 3),
      );
      _applySession(DemoUser.fromJson(result.user), result.session);
      backendReachable = true;
      await _persistCachedUser();
      await _pullRemoteFarmIfAny();
      await _pushFarmIfDirty();
    } on AuthException catch (error) {
      if (error.isUnauthorized) {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.remove(_sessionStorageKey);
        await OfflineStore.clearCachedUser();
        _clearSession(notify: true);
      }
    } catch (_) {}
  }

  Future<void> _restoreOfflineSession(
    String token, {
    bool notify = true,
  }) async {
    final cached = await OfflineStore.loadCachedUser();
    if (cached == null) {
      return;
    }
    _currentUser = DemoUser.fromJson(cached.user);
    _sessionToken = token;
    _sessionExpiresAt = cached.expiresAt.isAfter(DateTime.now().toUtc())
        ? cached.expiresAt
        : DateTime.now().toUtc().add(const Duration(hours: 12));
    _armSessionTimers(_sessionExpiresAt!);
    backendReachable = false;
    if (notify) {
      notifyListeners();
    }
  }

  void _startConnectivityWatch() {
    _connectivityTimer?.cancel();
    unawaited(_refreshConnectivity());
    _connectivityTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_refreshConnectivity()),
    );
  }

  Future<void> _refreshConnectivity() async {
    final bool online = await OfflineStore.ping(liveInspectionBackendUrl);
    final bool changed = online != backendReachable;
    backendReachable = online;
    if (online) {
      await _pushFarmIfDirty();
      if (_sessionToken != null) {
        try {
          final result = await _authApi.me(_sessionToken!);
          _currentUser = DemoUser.fromJson(result.user);
          _sessionExpiresAt = result.session.expiresAt;
          await _persistCachedUser();
        } catch (_) {}
      }
    }
    if (changed) {
      notifyListeners();
    }
  }

  Future<void> _loadFarmFromDisk() async {
    final Map<String, dynamic>? stored = await OfflineStore.loadFarm();
    if (stored == null) {
      await persistFarm(markDirty: false, notify: false);
      return;
    }
    _applyFarmSnapshot(stored);
    farmSyncPending = await OfflineStore.isDirty();
  }

  Map<String, dynamic> _farmSnapshot() {
    return <String, dynamic>{
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'production': productionRecords.map((ProductionRecord r) => r.toJson()).toList(),
      'grading': gradingRecords.map((GradingRecord r) => r.toJson()).toList(),
      'inventory': inventoryItems.map((InventoryItem r) => r.toJson()).toList(),
      'zones': inventoryZones.map((InventoryZone r) => r.toJson()).toList(),
      'movements':
          inventoryMovements.map((InventoryMovement r) => r.toJson()).toList(),
      'devices': inventoryDevices.map((InventoryDevice r) => r.toJson()).toList(),
      'workerTodayCollection': workerTodayCollection,
      'workerSubmissions': workerSubmissions,
      'workerTasks': workerTasks,
      'liveGoodEggs': liveGoodEggs,
      'liveCrackedEggs': liveCrackedEggs,
      'liveDirtyEggs': liveDirtyEggs,
    };
  }

  void _applyFarmSnapshot(Map<String, dynamic> stored) {
    final List<dynamic> production = stored['production'] as List<dynamic>? ?? <dynamic>[];
    if (production.isNotEmpty) {
      productionRecords = production
          .whereType<Map<String, dynamic>>()
          .map(ProductionRecord.fromJson)
          .toList();
    }
    final List<dynamic> grading = stored['grading'] as List<dynamic>? ?? <dynamic>[];
    if (grading.isNotEmpty) {
      gradingRecords = grading
          .whereType<Map<String, dynamic>>()
          .map(GradingRecord.fromJson)
          .toList();
    }
    final List<dynamic> inventory = stored['inventory'] as List<dynamic>? ?? <dynamic>[];
    if (inventory.isNotEmpty) {
      inventoryItems = inventory
          .whereType<Map<String, dynamic>>()
          .map(InventoryItem.fromJson)
          .toList();
    }
    final List<dynamic> zones = stored['zones'] as List<dynamic>? ?? <dynamic>[];
    if (zones.isNotEmpty) {
      inventoryZones = zones
          .whereType<Map<String, dynamic>>()
          .map(InventoryZone.fromJson)
          .toList();
    }
    final List<dynamic> movements = stored['movements'] as List<dynamic>? ?? <dynamic>[];
    if (movements.isNotEmpty) {
      inventoryMovements = movements
          .whereType<Map<String, dynamic>>()
          .map(InventoryMovement.fromJson)
          .toList();
    }
    final List<dynamic> devices = stored['devices'] as List<dynamic>? ?? <dynamic>[];
    if (devices.isNotEmpty) {
      inventoryDevices = devices
          .whereType<Map<String, dynamic>>()
          .map(InventoryDevice.fromJson)
          .toList();
    }
    workerTodayCollection =
        stored['workerTodayCollection'] as int? ?? workerTodayCollection;
    final Object? submissions = stored['workerSubmissions'];
    if (submissions is Map) {
      workerSubmissions = submissions.map(
        (Object? key, Object? value) =>
            MapEntry<String, bool>(key.toString(), value == true),
      );
    }
    final Object? tasks = stored['workerTasks'];
    if (tasks is Map) {
      workerTasks = tasks.map(
        (Object? key, Object? value) =>
            MapEntry<String, bool>(key.toString(), value == true),
      );
    }
    liveGoodEggs = stored['liveGoodEggs'] as int? ?? liveGoodEggs;
    liveCrackedEggs = stored['liveCrackedEggs'] as int? ?? liveCrackedEggs;
    liveDirtyEggs = stored['liveDirtyEggs'] as int? ?? liveDirtyEggs;
  }

  Future<void> persistFarm({bool markDirty = true, bool notify = true}) async {
    await OfflineStore.saveFarm(_farmSnapshot());
    if (!markDirty) {
      await OfflineStore.markSynced();
      farmSyncPending = false;
    } else {
      farmSyncPending = true;
      if (backendReachable) {
        unawaited(_pushFarmIfDirty());
      }
    }
    if (notify) {
      notifyListeners();
    }
  }

  void replaceProductionRecords(List<ProductionRecord> records) {
    productionRecords = List<ProductionRecord>.from(records);
    unawaited(persistFarm());
  }

  void replaceGradingRecords(List<GradingRecord> records) {
    gradingRecords = List<GradingRecord>.from(records);
    unawaited(persistFarm());
  }

  void replaceInventoryState({
    required List<InventoryItem> items,
    required List<InventoryMovement> movements,
    required List<InventoryDevice> devices,
    List<InventoryZone>? zones,
  }) {
    inventoryItems = List<InventoryItem>.from(items);
    inventoryMovements = List<InventoryMovement>.from(movements);
    inventoryDevices = List<InventoryDevice>.from(devices);
    if (zones != null) {
      inventoryZones = List<InventoryZone>.from(zones);
    }
    unawaited(persistFarm());
  }

  Future<void> _pushFarmIfDirty() async {
    final String? token = _sessionToken;
    if (token == null || !backendReachable) {
      return;
    }
    final bool dirty = await OfflineStore.isDirty();
    if (!dirty && !farmSyncPending) {
      return;
    }
    try {
      await _authApi.saveFarmSnapshot(token: token, snapshot: _farmSnapshot());
      await OfflineStore.markSynced();
      farmSyncPending = false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _pullRemoteFarmIfAny() async {
    final String? token = _sessionToken;
    if (token == null) {
      return;
    }
    try {
      final Map<String, dynamic>? remote = await _authApi.loadFarmSnapshot(token);
      if (remote == null || remote.isEmpty) {
        await _pushFarmIfDirty();
        return;
      }
      final String localUpdated = (_farmSnapshot()['updatedAt'] as String?) ?? '';
      final String remoteUpdated = remote['updatedAt'] as String? ?? '';
      if (remoteUpdated.compareTo(localUpdated) > 0) {
        _applyFarmSnapshot(remote);
        await OfflineStore.saveFarm(remote);
        await OfflineStore.markSynced();
        farmSyncPending = false;
        notifyListeners();
      } else {
        await _pushFarmIfDirty();
      }
    } catch (_) {}
  }

  Future<void> login({required String email, required String password}) async {
    final bool online = await connectBackend(silent: true);
    if (online) {
      try {
        final result = await _authApi.login(email: email, password: password);
        await _persistSession(result.session.token);
        _applySession(DemoUser.fromJson(result.user), result.session);
        backendReachable = true;
        await _persistCachedUser();
        await OfflineStore.saveLoginFingerprint(email, password);
        await _pullRemoteFarmIfAny();
        return;
      } on AuthException {
        rethrow;
      } catch (_) {}
    }
    await _loginWithoutFarmServer(email: email, password: password);
  }

  Future<void> _loginWithoutFarmServer({
    required String email,
    required String password,
  }) async {
    final String normalized = email.trim().toLowerCase();
    final String fingerprint = OfflineStore.loginFingerprint(
      normalized,
      password,
    );
    final String? stored = await OfflineStore.loadLoginFingerprint();
    if (stored != null && stored != fingerprint) {
      throw AuthException(
        'Wrong email or password.',
        code: 'invalid_credentials',
      );
    }

    DemoUser user;
    final cached = await OfflineStore.loadCachedUser();
    if (cached != null &&
        (cached.user['email'] as String? ?? '').trim().toLowerCase() ==
            normalized) {
      user = DemoUser.fromJson(<String, dynamic>{
        ...cached.user,
        'role': 'admin',
        'emailVerified': true,
      });
    } else if (stored != null && cached == null) {
      throw AuthException(
        'Wrong email or password.',
        code: 'invalid_credentials',
      );
    } else {
      final String localName = email.trim().split('@').first;
      user = DemoUser(
        name: localName.isEmpty ? 'Admin' : localName,
        email: email.trim(),
        role: AppRole.admin,
        assignedZone: 'Farm',
        emailVerified: true,
      );
    }

    final DateTime expires = DateTime.now().toUtc().add(const Duration(hours: 12));
    final AuthSession session = AuthSession(
      token: 'local-${expires.millisecondsSinceEpoch}',
      expiresAt: expires,
      idleTimeoutSeconds: 12 * 60 * 60,
    );
    await _persistSession(session.token);
    _applySession(user, session);
    backendReachable = false;
    await _persistCachedUser();
    await OfflineStore.saveLoginFingerprint(email, password);
    notifyListeners();
  }

  Future<AuthMailResult> signup({
    required String name,
    required String email,
    required String password,
    String role = 'worker',
  }) async {
    final bool online = await connectBackend(silent: true);
    if (online) {
      final AuthMailResult result = await _authApi.signup(
        name: name,
        email: email,
        password: password,
        role: role,
      );
      if (result.signedIn) {
        await _persistSession(result.session!.token);
        _applySession(DemoUser.fromJson(result.user!), result.session!);
        backendReachable = true;
        await _persistCachedUser();
        await OfflineStore.saveLoginFingerprint(email, password);
        await _pullRemoteFarmIfAny();
      }
      return result;
    }
    await _loginWithoutFarmServer(email: email, password: password);
    return AuthMailResult(
      message: 'Signed in on this device. Camera and port 8000 are optional.',
      user: _currentUser?.toJson(),
      session: AuthSession(
        token: _sessionToken ?? 'local',
        expiresAt:
            _sessionExpiresAt ??
            DateTime.now().toUtc().add(const Duration(hours: 12)),
        idleTimeoutSeconds: 12 * 60 * 60,
      ),
    );
  }

  Future<String> verifyEmail(String token) => _authApi.verifyEmail(token);

  Future<AuthMailResult> resendVerification(String email, {String? password}) {
    return _authApi.resendVerification(email, password: password);
  }

  Future<String> forgotPassword(String email) => _authApi.forgotPassword(email);

  Future<String> resetPassword({
    required String token,
    required String password,
  }) {
    return _authApi.resetPassword(token: token, password: password);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final String? token = _sessionToken;
    if (token == null) {
      throw AuthException('Session expired or invalid', code: 'unauthorized');
    }
    try {
      final Map<String, dynamic> user = await _authApi.changePassword(
        token: token,
        currentPassword: currentPassword,
        newPassword: newPassword,
      );
      if (user.isNotEmpty) {
        _currentUser = DemoUser.fromJson(user);
        notifyListeners();
      }
    } on AuthException catch (error) {
      if (error.isUnauthorized) {
        await signOut();
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    final String? token = _sessionToken;
    final bool hadSession = _currentUser != null || token != null;
    _clearSession(notify: true);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionStorageKey);
    await OfflineStore.clearCachedUser();
    await _authApi.logout(token);
    if (hadSession) {
      onUnauthenticated?.call();
    }
  }

  void _applySession(DemoUser user, AuthSession session) {
    _currentUser = user;
    _sessionToken = session.token;
    _sessionExpiresAt = session.expiresAt;
    _armSessionTimers(session.expiresAt);
    unawaited(_persistCachedUser());
    notifyListeners();
  }

  Future<void> _persistCachedUser() async {
    final DemoUser? user = _currentUser;
    final DateTime? expires = _sessionExpiresAt;
    if (user == null || expires == null) {
      return;
    }
    await OfflineStore.saveCachedUser(
      user: user.toJson(),
      expiresAt: expires.toIso8601String(),
    );
  }

  Future<void> _persistSession(String token) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionStorageKey, token);
  }

  void _clearSession({required bool notify}) {
    _sessionExpiryTimer?.cancel();
    _sessionHeartbeatTimer?.cancel();
    _sessionExpiryTimer = null;
    _sessionHeartbeatTimer = null;
    _currentUser = null;
    _sessionToken = null;
    _sessionExpiresAt = null;
    if (notify) {
      notifyListeners();
    }
  }

  void _armSessionTimers(DateTime expiresAt) {
    _sessionExpiryTimer?.cancel();
    _sessionHeartbeatTimer?.cancel();
    final Duration remaining = expiresAt.difference(DateTime.now().toUtc());
    if (remaining.isNegative || remaining == Duration.zero) {
      if (!backendReachable) {
        _sessionExpiresAt =
            DateTime.now().toUtc().add(const Duration(hours: 12));
        unawaited(_persistCachedUser());
        _armSessionTimers(_sessionExpiresAt!);
        return;
      }
      unawaited(signOut());
      return;
    }
    _sessionExpiryTimer = Timer(remaining, () {
      if (!backendReachable) {
        _sessionExpiresAt =
            DateTime.now().toUtc().add(const Duration(hours: 12));
        unawaited(_persistCachedUser());
        _armSessionTimers(_sessionExpiresAt!);
        return;
      }
      unawaited(signOut());
    });
    _sessionHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(_heartbeatSession()),
    );
  }

  Future<void> _heartbeatSession() async {
    final String? token = _sessionToken;
    if (token == null) {
      return;
    }
    try {
      final result = await _authApi.me(token);
      _currentUser = DemoUser.fromJson(result.user);
      _sessionExpiresAt = result.session.expiresAt;
      notifyListeners();
    } on AuthException catch (error) {
      if (error.isUnauthorized) {
        await signOut();
      }
    } catch (_) {
      // Ignore transient network errors; expiry timer still enforces logout.
    }
  }
}
