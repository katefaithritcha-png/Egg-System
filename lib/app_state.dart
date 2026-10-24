import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:firebase_core/firebase_core.dart';

import 'auth_api.dart';
import 'api_config.dart';
import 'egg_record.dart';
import 'egg_record_store.dart';
import 'egg_sync_engine.dart';
import 'iot_egg_reading.dart';
import 'offline_store.dart';
import 'secure_session_store.dart';

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

class EggSale {
  const EggSale({
    required this.id,
    required this.createdAt,
    required this.soldBy,
    required this.size,
    required this.quantity,
    required this.unitPrice,
    required this.buyer,
    required this.payment,
    required this.sellerName,
    required this.sellerEmail,
  });

  factory EggSale.fromJson(Map<String, dynamic> json) {
    return EggSale(
      id: json['id'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      soldBy: json['soldBy'] as String? ?? 'tray',
      size: json['size'] as String? ?? 'Large',
      quantity: json['quantity'] as int? ?? 0,
      unitPrice: (json['unitPrice'] as num?)?.toDouble() ?? 0,
      buyer: json['buyer'] as String? ?? '',
      payment: json['payment'] as String? ?? 'Cash',
      sellerName: json['sellerName'] as String? ?? '',
      sellerEmail: json['sellerEmail'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'createdAt': createdAt,
        'soldBy': soldBy,
        'size': size,
        'quantity': quantity,
        'unitPrice': unitPrice,
        'buyer': buyer,
        'payment': payment,
        'sellerName': sellerName,
        'sellerEmail': sellerEmail,
      };

  final String id;
  final String createdAt;
  final String soldBy;
  final String size;
  final int quantity;
  final double unitPrice;
  final String buyer;
  final String payment;
  final String sellerName;
  final String sellerEmail;

  bool get perTray => soldBy == 'tray';

  int get eggCount => perTray ? quantity * 30 : quantity;

  double get total => quantity * unitPrice;
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

enum AppRole { admin, worker, sales }

String appRoleName(AppRole role) {
  switch (role) {
    case AppRole.admin:
      return 'admin';
    case AppRole.sales:
      return 'sales';
    case AppRole.worker:
      return 'worker';
  }
}

AppRole appRoleFromName(String? name) {
  switch ((name ?? '').trim().toLowerCase()) {
    case 'admin':
      return AppRole.admin;
    case 'sales':
      return AppRole.sales;
    default:
      return AppRole.worker;
  }
}

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
    return DemoUser(
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
      role: appRoleFromName(json['role'] as String?),
      assignedZone: json['assignedZone'] as String? ?? 'Unassigned',
      emailVerified: json['emailVerified'] as bool? ?? false,
      passwordChangedAt: json['passwordChangedAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'email': email,
        'role': appRoleName(role),
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
  ///   Small    under 47.0 g
  ///   Medium   47.1 – 54.0 g
  ///   Large    54.1 – 61.3 g
  ///   XL       61.4 – 68.5 g
  ///   Jumbo    > 68.5 g
  static EggSizeClass fromGrams(double g) {
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
  // Kept only in memory for email verify — never put passwords in route args.
  String? _pendingVerifyPassword;

  void setPendingVerifyPassword(String? password) {
    _pendingVerifyPassword = password;
  }

  String? takePendingVerifyPassword() {
    final String? value = _pendingVerifyPassword;
    _pendingVerifyPassword = null;
    return value;
  }

  String? get sessionToken => _sessionToken;

  Map<String, String> get _authHeaders {
    final String? token = _sessionToken;
    if (token == null || token.isEmpty || _isLocalSessionToken(token)) {
      return const <String, String>{};
    }
    return <String, String>{'Authorization': 'Bearer $token'};
  }

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
  /// calibrated | uncalibrated | simulated — from backend /weight IoT path.
  String liveLastMeasurementStatus = 'uncalibrated';

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
  bool _metricsPollInFlight = false;
  Timer? _connectivityTimer;
  bool backendReachable = false;
  bool farmSyncPending = false;
  int eggPendingCount = 0;
  int eggSyncedCount = 0;
  List<IotEggReading> iotReadings = <IotEggReading>[];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _iotSubscription;
  EggRecordStore? _eggStore;
  EggSyncEngine? _eggSync;
  Timer? _eggSyncTimer;

  AppState();

  String get connectionLabel {
    final String counts = '$eggPendingCount pending · $eggSyncedCount synced';
    if (backendReachable) {
      return eggPendingCount > 0
          ? 'Online — uploading egg records · $counts'
          : 'Online — $counts';
    }
    return 'Offline — egg records stay on this device · $counts';
  }

  DemoUser? get currentUser => _currentUser;
  bool get isAuthenticated =>
      _currentUser != null &&
      _sessionToken != null &&
      (_sessionExpiresAt == null ||
          _sessionExpiresAt!.isAfter(DateTime.now().toUtc()));
  bool get isAdmin => _currentUser?.role == AppRole.admin;
  bool get isSales => _currentUser?.role == AppRole.sales;
  AppRole? get role => _currentUser?.role;
  DateTime? get sessionExpiresAt => _sessionExpiresAt;

  void startLiveInspectionPolling({
    Duration interval = const Duration(milliseconds: 500),
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

  Future<bool> _pullPublicStatus(String base) async {
    final http.Response response = await http
        .get(Uri.parse('$base/status'))
        .timeout(const Duration(seconds: 2));
    if (response.statusCode != 200 || response.body.isEmpty) {
      return false;
    }
    final Object? parsed = jsonDecode(response.body);
    if (parsed is! Map) {
      return false;
    }
    final Map<String, dynamic> data = Map<String, dynamic>.from(parsed);
    final bool hardwareOnline = data['hardwareOnline'] == true;
    final bool cameraConnected = data['connected'] == true;
    final bool live = hardwareOnline || cameraConnected;
    final double weight = (data['lastWeightGrams'] as num?)?.toDouble() ?? 0.0;
    final String meas =
        (data['lastMeasurementStatus'] as String? ?? liveLastMeasurementStatus)
            .toLowerCase();
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
      lastWeightGrams: weight >= 5.0 ? weight : 0.0,
      lastSizeClass: weight >= 5.0
          ? EggSizeClass.fromGrams(weight)
          : liveLastSizeClass,
      lastMeasurementStatus: meas,
    );
    backendReachable = true;
    if (base != backendBaseUrl) {
      backendBaseUrl = base;
      _authApi = AuthApi(baseUrl: base);
    }
    return true;
  }

  Future<void> _pollLiveInspectionMetrics() async {
    // No session yet: do not scan every host. That flood blocks sign-in.
    if (_sessionToken == null) {
      return;
    }
    if (_metricsPollInFlight) {
      return;
    }
    if (_isLocalSessionToken(_sessionToken)) {
      _metricsPollInFlight = true;
      try {
        await _pullPublicStatus(backendBaseUrl);
      } catch (_) {} finally {
        _metricsPollInFlight = false;
      }
      return;
    }
    _metricsPollInFlight = true;
    final List<String> urls = <String>[backendBaseUrl];
    http.Response? metricsResp;
    http.Response? recordsResp;
    String? usedBase;
    try {
      for (final String base in urls) {
        try {
          final Uri metricsEndpoint = Uri.parse('$base/metrics');
          final http.Response candidate = await http
              .get(metricsEndpoint, headers: _authHeaders)
              .timeout(const Duration(seconds: 2));
          if (candidate.statusCode == 200 && candidate.body.isNotEmpty) {
            metricsResp = candidate;
            usedBase = base;
            try {
              recordsResp = await http
                  .get(Uri.parse('$base/records'), headers: _authHeaders)
                  .timeout(const Duration(seconds: 2));
            } catch (_) {}
            break;
          }
        } catch (_) {
          continue;
        }
      }

      if (metricsResp == null || usedBase == null) {
        try {
          if (await _pullPublicStatus(backendBaseUrl)) {
            return;
          }
        } catch (_) {}
        final bool iotUp = iotReadings.isNotEmpty;
        updateLiveInspection(
          goodEggs: liveGoodEggs,
          crackedEggs: liveCrackedEggs,
          dirtyEggs: liveDirtyEggs,
          status: iotUp
              ? liveInspectionStatus
              : (backendReachable
                  ? 'System open. Waiting for ESP32-CAM (IoT can be offline).'
                  : 'System open. Farm PC offline — dashboard still works.'),
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
      // Trust the farm PC scale reading. 0 means empty bar / cleared.
      final double lastWeight =
          backendWeight >= 5.0 ? backendWeight : 0.0;
      final EggSizeClass lastSize = lastWeight >= 5.0
          ? EggSizeClass.fromGrams(lastWeight)
          : EggSizeClass.medium;

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
        lastMeasurementStatus:
            (data['lastMeasurementStatus'] as String? ?? liveLastMeasurementStatus)
                .toLowerCase(),
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
          unawaited(_rememberDetections(raw));
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
    } finally {
      _metricsPollInFlight = false;
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
    String? lastMeasurementStatus,
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
    if (lastMeasurementStatus != null && lastMeasurementStatus.isNotEmpty) {
      liveLastMeasurementStatus = lastMeasurementStatus.toLowerCase();
    }
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
      await http
          .post(endpoint, headers: _authHeaders)
          .timeout(const Duration(seconds: 5));
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
  List<EggSale> eggSales = <EggSale>[];

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
      String? token = await SecureSessionStore.read();
      if (token == null || token.isEmpty) {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        token = prefs.getString(_sessionStorageKey);
        if (token != null && token.isNotEmpty) {
          await SecureSessionStore.write(token);
          await prefs.remove(_sessionStorageKey);
        }
      }
      if (token == null || token.isEmpty) {
        return;
      }
      await _restoreOfflineSession(token, notify: false);
    } catch (_) {}
  }

  Future<void> _startEggSync() async {
    try {
      final EggRecordStore store = EggRecordStore();
      await store.open();
      _eggStore = store;
      _eggSync = EggSyncEngine(store, push: _pushEggRecord);
      await _refreshEggCounts();
      _eggSyncTimer?.cancel();
      _eggSyncTimer = Timer.periodic(
        const Duration(seconds: 8),
        (_) => unawaited(_syncEggs()),
      );
      unawaited(_syncEggs());
    } catch (_) {}
  }

  Future<void> _refreshEggCounts() async {
    final EggRecordStore? store = _eggStore;
    if (store == null) {
      return;
    }
    final counts = await store.counts();
    if (counts.pending == eggPendingCount && counts.synced == eggSyncedCount) {
      return;
    }
    eggPendingCount = counts.pending;
    eggSyncedCount = counts.synced;
    notifyListeners();
  }

  Future<EggPushResult> _pushEggRecord(EggRecord record) async {
    final String? token = _sessionToken;
    if (token == null || _isLocalSessionToken(token)) {
      return EggPushResult.failed;
    }
    final http.Response response = await http
        .post(
          Uri.parse('$backendBaseUrl/api/egg-records'),
          headers: <String, String>{
            ..._authHeaders,
            'Content-Type': 'application/json',
          },
          body: jsonEncode(record.toJson()),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      return EggPushResult.failed;
    }
    final Object? parsed = jsonDecode(response.body);
    if (parsed is Map && parsed['syncStatus'] == 'synced') {
      return EggPushResult.synced;
    }
    if (parsed is Map && parsed['ok'] == true) {
      return EggPushResult.pending;
    }
    return EggPushResult.failed;
  }

  Future<void> _syncEggs() async {
    final EggSyncEngine? engine = _eggSync;
    if (engine == null) {
      return;
    }
    final String? token = _sessionToken;
    engine.serverReachable = backendReachable &&
        token != null &&
        !_isLocalSessionToken(token);
    try {
      await engine.syncOnce();
    } catch (_) {}
    await _refreshEggCounts();
  }

  String _stableEggId(Map<String, dynamic> row) {
    final String given = (row['id'] as String?)?.trim() ?? '';
    if (RegExp(r'^[A-Za-z0-9_-]{8,80}$').hasMatch(given)) {
      return given;
    }
    final String raw =
        '${row['timestamp']}|${row['weightGrams']}|${row['label']}|${row['category']}';
    var hash = 2166136261;
    for (final int byte in utf8.encode(raw)) {
      hash ^= byte;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    return 'egg${hash.toRadixString(16)}';
  }

  Future<void> _rememberDetections(List<dynamic> raw) async {
    final EggRecordStore? store = _eggStore;
    if (store == null) {
      return;
    }
    final DateTime due = DateTime.now().toUtc();
    for (final dynamic item in raw) {
      if (item is! Map) {
        continue;
      }
      final Map<String, dynamic> row = Map<String, dynamic>.from(item);
      final double weight = (row['weightGrams'] as num?)?.toDouble() ?? 0;
      if (weight <= 0 || weight >= 500) {
        continue;
      }
      final String category = row['category'] as String? ?? '';
      final String sorting = category == 'goodEggs'
          ? 'Good'
          : category == 'crackedEggs'
              ? 'Cracked'
              : category == 'dirtyEggs'
                  ? 'Dirty'
                  : 'UNSORTED';
      final String size = (row['sizeClass'] as String?)?.trim().isNotEmpty == true
          ? row['sizeClass'] as String
          : EggSizeClass.fromGrams(weight).name;
      final DateTime created =
          DateTime.tryParse(row['timestamp'] as String? ?? '')?.toUtc() ?? due;
      await store.insertIgnore(
        EggRecord(
          id: _stableEggId(row),
          createdAt: created,
          weight: weight,
          size: size,
          cameraResult: (row['label'] as String?) ?? '',
          sortingResult: sorting,
          syncStatus: 'pending',
          attempts: 0,
          nextAttemptAt: due,
        ),
      );
    }
    await _syncEggs();
  }

  Future<void> startBackgroundServices() async {
    await connectBackend(silent: true);
    _startConnectivityWatch();
    await _startEggSync();
    startLiveInspectionPolling();
    // Do not mass-delete egg_readings from the client (IDOR / data wipe).
    startIotReadingsListener();
    final String? token = _sessionToken;
    if (token != null && !_isLocalSessionToken(token)) {
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
    // Retained as no-op: wiping Firestore from the client is an IDOR risk.
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
              // Live SIZE CLASS comes from farm /metrics (current load cell).
              // Firestore list is history only — do not override live weight here.
              if (next.isNotEmpty) {
                liveInspectionConnected = true;
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
    if (_isLocalSessionToken(token)) {
      return;
    }
    try {
      final result = await _authApi.me(
        token,
        timeout: const Duration(seconds: 3),
      );
      _applySession(
        await _respectSalesDesk(DemoUser.fromJson(result.user)),
        result.session,
      );
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
        onUnauthenticated?.call();
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
      unawaited(_syncEggs());
      if (_sessionToken != null) {
        try {
          final result = await _authApi.me(_sessionToken!);
          _currentUser = await _respectSalesDesk(DemoUser.fromJson(result.user));
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
      'eggSales': eggSales.map((EggSale sale) => sale.toJson()).toList(),
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
    if (stored.containsKey('eggSales')) {
      final List<dynamic> sales = stored['eggSales'] as List<dynamic>? ?? <dynamic>[];
      eggSales = sales
          .whereType<Map>()
          .map((Map<dynamic, dynamic> item) =>
              EggSale.fromJson(Map<String, dynamic>.from(item)))
          .toList();
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

  void addEggSale(EggSale sale) {
    eggSales = <EggSale>[sale, ...eggSales];
    unawaited(persistFarm());
    notifyListeners();
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

  Future<DemoUser> _respectSalesDesk(DemoUser user) async {
    if (user.role == AppRole.sales) {
      return user;
    }
    final bool marked = await OfflineStore.isSalesEmail(user.email);
    final Map<String, dynamic>? local =
        await OfflineStore.loadLocalAccount(user.email);
    final bool localSales = local != null && local['role'] == 'sales';
    if (!marked && !localSales) {
      return user;
    }
    return DemoUser(
      name: user.name,
      email: user.email,
      role: AppRole.sales,
      assignedZone: user.assignedZone,
      emailVerified: user.emailVerified,
      passwordChangedAt: user.passwordChangedAt,
    );
  }

  Future<void> login({required String email, required String password}) async {
    // Same farm URL the ESP32 uses. 127.0.0.1 is only a fallback inside ApiConfig.
    backendBaseUrl = ApiConfig.initialUrl;
    _authApi = AuthApi(baseUrl: backendBaseUrl);
    try {
      final result = await _authApi.login(email: email, password: password);
      final DemoUser user = await _respectSalesDesk(
        DemoUser.fromJson(result.user),
      );
      await _persistSession(result.session.token);
      _applySession(user, result.session);
      backendReachable = true;
      await _persistCachedUser();
      await OfflineStore.saveLocalAccount(
        email: email,
        password: password,
        role: appRoleName(user.role),
        name: user.name,
      );
      await _pullRemoteFarmIfAny();
      return;
    } on AuthException catch (error) {
      if (error.isUnauthorized &&
          await OfflineStore.verifyLocalAccount(email, password)) {
        await _reopenSavedSystem(email: email, password: password);
        return;
      }
      rethrow;
    } catch (_) {}
    await _reopenSavedSystem(email: email, password: password);
  }

  /// Farm PC and IoT are optional. Reopen a saved account, or open a local
  /// session the first time this browser is used while they are offline.
  Future<void> _reopenSavedSystem({
    required String email,
    required String password,
  }) async {
    final bool match = await OfflineStore.verifyLocalAccount(email, password);
    Map<String, dynamic>? known = await OfflineStore.loadLocalAccount(email);
    if (known != null && !match) {
      throw AuthException('Wrong password.', code: 'invalid_credentials');
    }
    if (known == null) {
      final String trimmed = email.trim();
      final String name =
          trimmed.contains('@') ? trimmed.split('@').first : trimmed;
      await OfflineStore.saveLocalAccount(
        email: trimmed,
        password: password,
        role: 'admin',
        name: name,
      );
      known = await OfflineStore.loadLocalAccount(email);
    }
    final Map<String, dynamic> account = known!;
    final AppRole resolvedRole = appRoleFromName(account['role'] as String?);
    final String resolvedName =
        (account['name'] as String?) ?? email.split('@').first;
    final DemoUser user = DemoUser(
      name: resolvedName,
      email: (account['email'] as String?) ?? email.trim(),
      role: resolvedRole,
      assignedZone: 'Farm',
      emailVerified: true,
    );
    final AuthSession session = AuthSession(
      token: 'local-${email.trim().toLowerCase()}',
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      idleTimeoutSeconds: 86400,
    );
    await _persistSession(session.token);
    _applySession(user, session);
    backendReachable = false;
    await _persistCachedUser();
  }

  Future<void> completeLoginWithCode(
    String code, {
    String? password,
  }) async {
    final bool online = await connectBackend(silent: true);
    if (!online) {
      backendBaseUrl = ApiConfig.initialUrl;
      _authApi = AuthApi(baseUrl: backendBaseUrl);
    }
    final result = await _authApi.verifyLogin(code);
    final DemoUser user = await _respectSalesDesk(DemoUser.fromJson(result.user));
    await _persistSession(result.session.token);
    _applySession(user, result.session);
    backendReachable = true;
    await _persistCachedUser();
    if (password != null && password.isNotEmpty) {
      await OfflineStore.saveLocalAccount(
        email: user.email,
        password: password,
        role: appRoleName(user.role),
        name: user.name,
      );
    }
    await _pullRemoteFarmIfAny();
  }

  Future<void> loginWithGoogle({
    String role = 'worker',
    bool setRole = false,
  }) async {
    final bool online = await connectBackend(silent: true);
    if (!online) {
      if (Firebase.apps.isEmpty) {
        throw AuthException(
          'Firebase is not initialized. Restart the app and try again.',
          code: 'firebase_unavailable',
        );
      }
      final firebase_auth.UserCredential credential =
          await firebase_auth.FirebaseAuth.instance.signInWithPopup(
        firebase_auth.GoogleAuthProvider(),
      );
      final String email = credential.user?.email ?? '';
      if (email.isEmpty) {
        throw AuthException('Google did not return an email');
      }
      await _reopenSavedSystem(email: email, password: 'google');
      return;
    }
    if (Firebase.apps.isEmpty) {
      throw AuthException(
        'Firebase is not initialized. Restart the app and try again.',
        code: 'firebase_unavailable',
      );
    }
    final firebase_auth.UserCredential credential =
        await firebase_auth.FirebaseAuth.instance.signInWithPopup(
      firebase_auth.GoogleAuthProvider(),
    );
    final String? idToken = await credential.user?.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw AuthException('Google did not return a sign-in token');
    }
    final result = await _authApi.firebaseLogin(
      idToken: idToken,
      role: role,
      setRole: setRole,
    );
    final DemoUser user = await _respectSalesDesk(DemoUser.fromJson(result.user));
    await _persistSession(result.session.token);
    _applySession(user, result.session);
    backendReachable = true;
    await _persistCachedUser();
    await OfflineStore.saveLocalAccount(
      email: user.email,
      password: 'google',
      role: appRoleName(user.role),
      name: user.name,
    );
    await _pullRemoteFarmIfAny();
  }

  Future<AuthMailResult> signup({
    required String name,
    required String email,
    required String password,
    String role = 'worker',
  }) async {
    final bool online = await connectBackend(silent: true);
    if (!online) {
      throw AuthException(
        'Cannot reach the farm server on port 8000. Start the backend, then create the account.',
        code: 'backend_unreachable',
      );
    }
    final AuthMailResult result = await _authApi.signup(
      name: name,
      email: email,
      password: password,
      role: role,
    );
    final AuthMailResult effective = result;
    if (effective.signedIn) {
      final DemoUser user = DemoUser.fromJson(effective.user!);
      await _persistSession(effective.session!.token);
      _applySession(user, effective.session!);
      backendReachable = true;
      await _persistCachedUser();
      await OfflineStore.saveLocalAccount(
        email: email,
        password: password,
        role: appRoleName(user.role),
        name: user.name,
      );
      await _pullRemoteFarmIfAny();
    }
    // Also mirror into Firebase Auth so the account appears in the console.
    try {
      if (Firebase.apps.isNotEmpty) {
        await firebase_auth.FirebaseAuth.instance
            .createUserWithEmailAndPassword(email: email, password: password);
      }
    } catch (_) {
      try {
        if (Firebase.apps.isNotEmpty) {
          await firebase_auth.FirebaseAuth.instance
              .signInWithEmailAndPassword(email: email, password: password);
        }
      } catch (_) {}
    }
    return effective;
  }

  /// Creates a worker account and leaves the current admin session in place.
  Future<String> createWorkerAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    await OfflineStore.saveLocalAccount(
      email: email,
      password: password,
      role: 'worker',
      name: name,
    );
    final bool online = await connectBackend(silent: true);
    if (!online) {
      return 'Worker account saved on this device for ${email.trim()}. They can sign in here even if the farm PC is off.';
    }
    try {
      final AuthMailResult result = await _authApi.signup(
        name: name,
        email: email,
        password: password,
        role: 'worker',
      );
      if (result.signedIn) {
        return 'That email already has an account. They can sign in on this browser as a worker.';
      }
      if ((result.verificationCode ?? '').trim().isNotEmpty) {
        return 'Worker account created for ${email.trim()}. The verification code was sent to that Gmail address.';
      }
    } on AuthException catch (error) {
      return 'Worker account saved on this device for ${email.trim()}. ${error.message}';
    }
    return 'Worker account created for ${email.trim()}. Check email for the verification code.';
  }

  /// Creates a sales-only account and leaves the current admin session in place.
  Future<String> createSalesAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    await OfflineStore.saveLocalAccount(
      email: email,
      password: password,
      role: 'sales',
      name: name,
    );
    final bool online = await connectBackend(silent: true);
    if (!online) {
      return 'Sales account saved on this device for ${email.trim()}. They can sign in here even if the farm PC is off.';
    }
    try {
      final AuthMailResult result = await _authApi.signup(
        name: name,
        email: email,
        password: password,
        role: 'worker',
      );
      if (result.signedIn) {
        return 'That email already has an account. On this browser it opens the sales desk.';
      }
      final String? code = result.verificationCode;
      if (code != null && code.trim().isNotEmpty) {
        await _authApi.verifyEmail(code);
      }
    } on AuthException catch (error) {
      return 'Sales account saved on this device for ${email.trim()}. ${error.message}';
    }
    return 'Sales account created for ${email.trim()}.';
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
    await SecureSessionStore.clear();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionStorageKey);
    await OfflineStore.clearCachedUser();
    if (!_isLocalSessionToken(token)) {
      await _authApi.logout(token);
    }
    try {
      if (Firebase.apps.isNotEmpty) {
        await firebase_auth.FirebaseAuth.instance.signOut();
      }
    } catch (_) {}
    if (hadSession) {
      onUnauthenticated?.call();
    }
  }

  static bool _isLocalSessionToken(String? token) {
    return token != null && token.startsWith('local-');
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
    await SecureSessionStore.write(token);
    // Migrate away from legacy plaintext SharedPreferences token.
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionStorageKey);
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
    final bool localSession = _isLocalSessionToken(_sessionToken);
    if (remaining.isNegative || remaining == Duration.zero) {
      if (!backendReachable || localSession) {
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
      if (!backendReachable || _isLocalSessionToken(_sessionToken)) {
        _sessionExpiresAt =
            DateTime.now().toUtc().add(const Duration(hours: 12));
        unawaited(_persistCachedUser());
        _armSessionTimers(_sessionExpiresAt!);
        return;
      }
      unawaited(signOut());
    });
    if (localSession) {
      return;
    }
    _sessionHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(_heartbeatSession()),
    );
  }

  Future<void> _heartbeatSession() async {
    final String? token = _sessionToken;
    if (token == null || _isLocalSessionToken(token)) {
      return;
    }
    try {
      final result = await _authApi.me(token);
      _currentUser = await _respectSalesDesk(DemoUser.fromJson(result.user));
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
