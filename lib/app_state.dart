import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

/// Only this Gmail may use the admin dashboard (matches AUTH_ADMIN_EMAIL).
const String kSoleAdminEmail = 'katefaithr@gmail.com';

AppRole roleForEmail(String email, String? roleName) {
  final String normalized = email.trim().toLowerCase();
  if (normalized == kSoleAdminEmail) {
    return AppRole.admin;
  }
  final AppRole role = appRoleFromName(roleName);
  if (role == AppRole.admin) {
    return AppRole.worker;
  }
  return role;
}

class DemoUser {
  const DemoUser({
    required this.name,
    required this.email,
    required this.role,
    required this.assignedZone,
    this.emailVerified = false,
    this.disabled = false,
    this.passwordChangedAt,
  });

  factory DemoUser.fromJson(Map<String, dynamic> json) {
    final String email = json['email'] as String? ?? '';
    return DemoUser(
      name: json['name'] as String? ?? '',
      email: email,
      role: roleForEmail(email, json['role'] as String?),
      assignedZone: json['assignedZone'] as String? ?? 'Unassigned',
      emailVerified: json['emailVerified'] as bool? ?? false,
      disabled: json['disabled'] as bool? ?? false,
      passwordChangedAt: json['passwordChangedAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'email': email,
        'role': appRoleName(role),
        'assignedZone': assignedZone,
        'emailVerified': emailVerified,
        'disabled': disabled,
        'passwordChangedAt': passwordChangedAt,
      };

  final String name;
  final String email;
  final AppRole role;
  final String assignedZone;
  final bool emailVerified;
  final bool disabled;
  final String? passwordChangedAt;

  DemoUser copyWith({
    String? name,
    String? email,
    AppRole? role,
    String? assignedZone,
    bool? emailVerified,
    bool? disabled,
    String? passwordChangedAt,
  }) {
    return DemoUser(
      name: name ?? this.name,
      email: email ?? this.email,
      role: role ?? this.role,
      assignedZone: assignedZone ?? this.assignedZone,
      emailVerified: emailVerified ?? this.emailVerified,
      disabled: disabled ?? this.disabled,
      passwordChangedAt: passwordChangedAt ?? this.passwordChangedAt,
    );
  }
}

// ── Worker model classes ───────────────────────────────────────────────────

enum WorkerNotificationType { warning, success, info }

class WorkerNotification {
  WorkerNotification({
    required this.id,
    required this.message,
    required this.type,
    required this.read,
  });

  final String id;
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
    this.id = '',
    this.awaitingWeight = false,
    this.sizeClassRaw = '',
  });

  factory DetectionRecord.fromJson(Map<String, dynamic> json) {
    final double? rawW = (json['weightGrams'] as num?)?.toDouble();
    final double w = rawW ?? 0.0;
    final bool awaiting = json['awaitingWeight'] == true ||
        (json['sizeClass'] as String?)?.toLowerCase() == 'pending';
    final String sizeRaw =
        (json['sizeClass'] as String? ?? (awaiting ? 'pending' : '')).trim();
    final String ts = json['timestamp'] as String? ?? '';
    final String lab = json['label'] as String? ?? '';
    final String rid = (json['id'] as String? ?? '').trim().isNotEmpty
        ? (json['id'] as String).trim()
        : 'cache-${ts}_$lab'.replaceAll(' ', '_');
    return DetectionRecord(
      id: rid,
      timestamp: ts,
      label: lab,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      category: json['category'] as String? ?? '',
      weightGrams: w,
      sizeClass: (!awaiting && w >= 5.0)
          ? EggSizeClass.fromGrams(w)
          : EggSizeClass.medium,
      awaitingWeight: awaiting,
      sizeClassRaw: sizeRaw,
    );
  }

  final String id;
  final String timestamp;
  final String label;
  final double confidence;
  final String category;
  final double weightGrams;
  final EggSizeClass sizeClass;
  final bool awaitingWeight;
  final String sizeClassRaw;

  bool get isPendingWeight =>
      awaitingWeight || sizeClassRaw.toLowerCase() == 'pending';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'timestamp': timestamp,
        'label': label,
        'confidence': confidence,
        'category': category,
        'weightGrams': weightGrams,
        'sizeClass': sizeClassRaw.isNotEmpty
            ? sizeClassRaw
            : (awaitingWeight ? 'pending' : sizeClass.name),
        'awaitingWeight': awaitingWeight,
      };
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

  /// Hosted web uses the farm tunnel API (not workers.dev — that 429s).
  /// Never LAN http from an HTTPS page (mixed content).
  String get liveInspectionBackendUrl {
    if (ApiConfig.isHostedHttpsWeb) {
      return ApiConfig.apiBaseUrl;
    }
    return backendBaseUrl;
  }

  /// Called after a live session is cleared so the UI can return to sign-in.
  VoidCallback? onUnauthenticated;

  // ── Live inspection ─────────────────────────────────────────────────────
  int liveGoodEggs = 0;
  int liveCrackedEggs = 0;
  int liveDirtyEggs = 0;
  String liveInspectionStatus = 'Waiting for live inspection data';
  String liveLastLabel = 'N/A';
  double liveLastConfidence = 0.0;
  bool liveAwaitingWeight = false;
  String livePendingEggId = '';
  bool liveInspectionConnected = false;

  double liveLastWeightGrams = 0.0;
  EggSizeClass liveLastSizeClass = EggSizeClass.medium;
  /// calibrated | uncalibrated | simulated — from backend /weight IoT path.
  String liveLastMeasurementStatus = 'uncalibrated';

  List<DetectionRecord> detectionRecords = const <DetectionRecord>[];

  /// After admin Reset, ignore cached board / max() until farm confirms zeros.
  bool _liveBoardHardReset = false;
  DateTime? _liveBoardHardResetAt;

  // ── Worker state ─────────────────────────────────────────────────────────
  /// Today's egg collection total (worker-editable via Production screen).
  int workerTodayCollection = 0;

  /// Contextual notifications for all roles (web + mobile).
  List<WorkerNotification> workerNotifications = <WorkerNotification>[];
  final Set<String> _notificationReadIds = <String>{};

  int get workerUnreadCount =>
      workerNotifications.where((WorkerNotification n) => !n.read).length;

  int get workerDamagedCount => liveCrackedEggs + liveDirtyEggs;

  /// Mark all notifications as read (persisted for web + mobile).
  void markAllNotificationsRead() {
    for (final WorkerNotification n in workerNotifications) {
      n.read = true;
      _notificationReadIds.add(n.id);
      }
      notifyListeners();
    unawaited(OfflineStore.saveNotificationReadKeys(_notificationReadIds));
  }

  void markNotificationRead(String id) {
    if (id.trim().isEmpty) {
      return;
    }
    _notificationReadIds.add(id);
    for (final WorkerNotification n in workerNotifications) {
      if (n.id == id) {
        n.read = true;
      }
    }
    notifyListeners();
    unawaited(OfflineStore.saveNotificationReadKeys(_notificationReadIds));
  }

  Future<void> _loadNotificationReadState() async {
    final Set<String> keys = await OfflineStore.loadNotificationReadKeys();
    _notificationReadIds
      ..clear()
      ..addAll(keys);
    refreshOperationalNotifications();
  }

  int get _dirtyFromBoard {
    int fromRecords = 0;
    for (final DetectionRecord row in detectionRecords) {
      final String label = row.label.toLowerCase();
      final String category = row.category.toLowerCase();
      if (label.contains('dirty') || category.contains('dirty')) {
        fromRecords += 1;
      }
    }
    return liveDirtyEggs > fromRecords ? liveDirtyEggs : fromRecords;
  }

  /// Keep the notification tray filled from live farm signals (web + mobile).
  void refreshOperationalNotifications({bool notify = true}) {
    final List<WorkerNotification> next = <WorkerNotification>[];
    void addNote(String id, String message, WorkerNotificationType type) {
      final bool wasRead = _notificationReadIds.contains(id) ||
          workerNotifications.any(
            (WorkerNotification n) => n.id == id && n.read,
          );
      next.add(
        WorkerNotification(
          id: id,
          message: message,
          type: type,
          read: wasRead,
        ),
      );
    }

    if (!backendReachable) {
      addNote(
        'farm_offline',
        'Farm PC offline — start backend + tunnel for live inspection.',
        WorkerNotificationType.warning,
      );
    } else if (!liveInspectionConnected) {
      addNote(
        'cam_waiting',
        'Farm online. Waiting for ESP32-CAM — point at an egg to inspect.',
        WorkerNotificationType.info,
      );
    } else {
      final int dirty = _dirtyFromBoard;
      addNote(
        'live_running',
        'Live inspection running: Good $liveGoodEggs · Cracked $liveCrackedEggs'
            '${dirty > 0 ? ' · Dirty $dirty' : ''}.',
        WorkerNotificationType.success,
      );
    }

    if (liveCrackedEggs > 0) {
      addNote(
        'cracked_$liveCrackedEggs',
        '$liveCrackedEggs cracked egg(s) detected — check reject bin / QC.',
        WorkerNotificationType.warning,
      );
    }

    final int dirtyCount = _dirtyFromBoard;
    if (dirtyCount > 0) {
      addNote(
        'dirty_$dirtyCount',
        '$dirtyCount dirty egg(s) detected — review quality divert.',
        WorkerNotificationType.warning,
      );
    }

    if (!isSales && todayProductionTotal == 0) {
      addNote(
        'production_empty',
        'No production logged today — add a collection in Production.',
        WorkerNotificationType.info,
      );
    }

    if (isAdmin && lowStockCount > 0) {
      addNote(
        'low_stock_$lowStockCount',
        '$lowStockCount inventory item(s) are at or below threshold.',
        WorkerNotificationType.warning,
      );
    }

    if (isSales && lowStockCount > 0) {
      addNote(
        'sales_low_stock_$lowStockCount',
        'Low tray stock on $lowStockCount item(s) — check with admin.',
        WorkerNotificationType.warning,
      );
    }

    // Unread first, then read.
    next.sort((WorkerNotification a, WorkerNotification b) {
      if (a.read == b.read) {
        return 0;
      }
      return a.read ? 1 : -1;
    });
    workerNotifications = next;
    if (notify) {
    notifyListeners();
    }
  }

  Timer? _livePollingTimer;
  bool _metricsPollInFlight = false;
  /// Keep LIVE badge sticky for brief tunnel blips after camera was seen online.
  DateTime? _lastCameraLiveAt;
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
  bool get isAdmin {
    final DemoUser? user = _currentUser;
    if (user == null) {
      return false;
    }
    return user.role == AppRole.admin &&
        user.email.trim().toLowerCase() == kSoleAdminEmail;
  }

  bool get isSales {
    final DemoUser? user = _currentUser;
    if (user == null || isAdmin) {
      return false;
    }
    return user.role == AppRole.sales;
  }

  bool get isWorker {
    final DemoUser? user = _currentUser;
    if (user == null) {
      return false;
    }
    return !isAdmin && !isSales;
  }

  AppRole? get role {
    final DemoUser? user = _currentUser;
    if (user == null) {
      return null;
    }
    if (isAdmin) {
      return AppRole.admin;
    }
    if (isSales) {
      return AppRole.sales;
    }
    return AppRole.worker;
  }
  DateTime? get sessionExpiresAt => _sessionExpiresAt;

  void startLiveInspectionPolling({
    Duration interval = const Duration(milliseconds: 200),
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
    // Prefer /health — public through the Worker tunnel. /status needs auth on CF.
    http.Response response = await http
        .get(Uri.parse('$base/health'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200 || response.body.isEmpty) {
      response = await http
          .get(Uri.parse('$base/live-status'))
          .timeout(const Duration(seconds: 6));
    }
    if (response.statusCode != 200 || response.body.isEmpty) {
      response = await http
        .get(Uri.parse('$base/status'))
          .timeout(const Duration(seconds: 4));
    }
    if (response.statusCode != 200 || response.body.isEmpty) {
      return false;
    }
    final Object? parsed = jsonDecode(response.body);
    if (parsed is! Map) {
      return false;
    }
    final Map<String, dynamic> data = Map<String, dynamic>.from(parsed);
    final bool hardwareOnline = data['hardwareOnline'] == true;
    // /health uses cameraConnected; /metrics and /live-status use connected.
    final bool cameraConnected = data['connected'] == true ||
        data['cameraConnected'] == true ||
        data['frameLive'] == true;
    final bool live = hardwareOnline || cameraConnected;
    if (live) {
      _lastCameraLiveAt = DateTime.now();
    }
    final double weight = (data['lastWeightGrams'] as num?)?.toDouble() ?? 0.0;
    final String meas =
        (data['lastMeasurementStatus'] as String? ?? liveLastMeasurementStatus)
            .toLowerCase();
    updateLiveInspection(
      goodEggs: (data['goodEggs'] as int? ?? liveGoodEggs) +
          (data['dirtyEggs'] as int? ?? 0),
      crackedEggs: data['crackedEggs'] as int? ?? liveCrackedEggs,
      dirtyEggs: 0,
      status: live
          ? 'Camera online — waiting for egg'
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

  bool get _cameraRecentlyLive {
    final DateTime? at = _lastCameraLiveAt;
    if (at == null) {
      return false;
    }
    return DateTime.now().difference(at) < const Duration(seconds: 45);
  }

  Future<void> _pollLiveInspectionMetrics() async {
    // Hosted LIVE board is public GET — keep polling even during brief auth gaps.
    if (_sessionToken == null && !ApiConfig.isHostedHttpsWeb) {
      return;
    }
    if (_metricsPollInFlight) {
      return;
    }
      _metricsPollInFlight = true;
    // Hosted HTTPS: farm tunnel only — workers.dev returns 429 and breaks LIVE.
    final List<String> urls = ApiConfig.isHostedHttpsWeb
        ? <String>[ApiConfig.apiBaseUrl]
        : <String>[backendBaseUrl];
    http.Response? metricsResp;
    http.Response? recordsResp;
    String? usedBase;
    try {
      for (final String base in urls) {
        try {
          // Hosted tunnel path is slower than LAN — 2s caused false "offline"
          // and empty boards (requests aborted → context canceled in cloudflared).
          final Duration timeout = ApiConfig.isHostedHttpsWeb
              ? const Duration(seconds: 8)
              : const Duration(seconds: 4);
          // Cache-bust so browsers/CDN never serve a stale empty board.
          final int bust = DateTime.now().millisecondsSinceEpoch;
          // Do NOT send Cache-Control/Pragma — those force a CORS preflight
          // that the farm tunnel rejects, so Live Inspection looks offline
          // even when /metrics is healthy. Cache-bust with ?_= only.
          final Future<http.Response> metricsFut = http
              .get(
                Uri.parse('$base/metrics?_=$bust'),
                headers: _authHeaders,
              )
              .timeout(timeout);
          final Future<http.Response?> recordsFut = http
              .get(
                Uri.parse('$base/records?_=$bust'),
                headers: _authHeaders,
              )
              .timeout(timeout)
              .then<http.Response?>((http.Response r) => r)
              .catchError((_) => null);
          final List<Object?> pair = await Future.wait<Object?>(
            <Future<Object?>>[metricsFut, recordsFut],
          );
          final http.Response candidate = pair[0]! as http.Response;
          if (candidate.statusCode == 200 && candidate.body.isNotEmpty) {
            metricsResp = candidate;
            usedBase = base;
            final Object? rec = pair[1];
            if (rec is http.Response) {
              recordsResp = rec;
            }
            break;
          }
        } catch (_) {
          continue;
        }
      }

      // Local / offline session: still pull public /status if metrics blocked.
      if (metricsResp == null || usedBase == null) {
        try {
          if (await _pullPublicStatus(backendBaseUrl)) {
            return;
          }
        } catch (_) {}
        final bool iotUp = iotReadings.isNotEmpty;
        final bool keepLive = iotUp || _cameraRecentlyLive;
        updateLiveInspection(
          goodEggs: liveGoodEggs,
          crackedEggs: liveCrackedEggs,
          dirtyEggs: liveDirtyEggs,
          status: keepLive
              ? (liveInspectionStatus.isEmpty ||
                      liveInspectionStatus == 'Waiting for live inspection data'
                  ? 'Camera online — waiting for egg'
                  : liveInspectionStatus)
              : (backendReachable
                  ? 'System open. Waiting for ESP32-CAM (IoT can be offline).'
                  : 'System open. Farm PC offline — dashboard still works.'),
          lastLabel: liveLastLabel,
          lastConfidence: liveLastConfidence,
          connected: keepLive,
        );
        return;
      }

      // Always mark farm reachable when /metrics succeeds — even if the URL
      // already matched (hosted workers.dev). Old code only flipped the flag
      // on URL change, so the dashboard stayed "farm PC offline" forever.
      backendReachable = true;
      if (usedBase != backendBaseUrl) {
        backendBaseUrl = usedBase;
        _authApi = AuthApi(baseUrl: usedBase);
      }

      final Object? parsed = jsonDecode(metricsResp.body);
      if (parsed is! Map) {
        return;
      }
      final Map<String, dynamic> data = Map<String, dynamic>.from(parsed);

      final bool backendConnected = data['connected'] == true;
      final bool hardwareOnline = data['hardwareOnline'] == true;
      final bool iotUp = iotReadings.isNotEmpty;
      final bool live =
          backendConnected || hardwareOnline || iotUp || _cameraRecentlyLive;
      if (backendConnected || hardwareOnline) {
        _lastCameraLiveAt = DateTime.now();
      }

      final double backendWeight =
          (data['lastWeightGrams'] as num?)?.toDouble() ?? 0.0;
      final bool awaitingWeight = data['awaitingWeight'] == true;
      final String pendingId =
          (data['pendingEggId'] as String? ?? '').trim();
      final String sizeRaw =
          (data['lastSizeClass'] as String? ?? '').trim().toLowerCase();
      // Trust the farm PC scale reading. 0 means empty bar / cleared.
      // Clean camera commit keeps weight at 0 until the pad reports grams.
      final double lastWeight =
          backendWeight >= 5.0 ? backendWeight : 0.0;
      final EggSizeClass lastSize = lastWeight >= 5.0
          ? EggSizeClass.fromGrams(lastWeight)
          : EggSizeClass.medium;
      String nextLabel = data['lastLabel'] as String? ?? liveLastLabel;
      if (awaitingWeight) {
        final String pipeCam =
            (data['pipeCamera'] as String? ?? '').trim().toLowerCase();
        final String low = nextLabel.toLowerCase();
        if (nextLabel.isEmpty ||
            nextLabel == 'N/A' ||
            low == 'empty model' ||
            low == 'scanning' ||
            low == 'egg') {
          if (pipeCam.contains('crack')) {
            nextLabel = 'Crack Egg';
          } else {
            nextLabel = 'Clean Egg';
          }
        }
      }

      // Instant counts from farm /metrics (camera commit). Take max with Firebase
      // so a slow Firestore snapshot never rolls the UI backwards.
      // Dirty/dust is not a grade — fold any legacy dirtyEggs into Good.
      final int mGood = (data['goodEggs'] as int? ?? 0) +
          (data['dirtyEggs'] as int? ?? 0);
      final int mCrack = data['crackedEggs'] as int? ?? 0;
      if (!_liveBoardHardReset && iotReadings.isNotEmpty) {
        _applyTodaysCountsFromIot(iotReadings);
      }
      // Also count Live Egg Records — backend restart can zero /metrics while
      // the board list is still on screen (cached / restored rows).
      // After admin Reset, trust farm metrics only so cached rows cannot revive.
      final ({int good, int cracked}) fromBoard = _countsFromDetectionRecords();
      final int useGood = _liveBoardHardReset
          ? mGood
          : <int>[liveGoodEggs, mGood, fromBoard.good]
              .reduce((int a, int b) => a > b ? a : b);
      final int useCrack = _liveBoardHardReset
          ? mCrack
          : <int>[liveCrackedEggs, mCrack, fromBoard.cracked]
              .reduce((int a, int b) => a > b ? a : b);
      if (_liveBoardHardReset &&
          mGood == 0 &&
          mCrack == 0 &&
          (_liveBoardHardResetAt == null ||
              DateTime.now().difference(_liveBoardHardResetAt!) >
                  const Duration(seconds: 3))) {
        _liveBoardHardReset = false;
        _liveBoardHardResetAt = null;
      }
      String liveStatus =
          data['status'] as String? ?? 'Live inspection running';
      if (live &&
          (nextLabel.isEmpty ||
              nextLabel == 'N/A' ||
              liveStatus.toLowerCase() == 'running')) {
        liveStatus = 'Camera online — waiting for egg';
      }
      updateLiveInspection(
        goodEggs: useGood,
        crackedEggs: useCrack,
        dirtyEggs: 0,
        status: live
            ? liveStatus
            : 'Farm PC is online. Waiting for ESP32-CAM heartbeat.',
        lastLabel: nextLabel,
        lastConfidence:
            (data['lastConfidence'] as num?)?.toDouble() ?? liveLastConfidence,
        connected: live,
        lastWeightGrams: lastWeight,
        lastSizeClass: lastSize,
        lastMeasurementStatus:
            (data['lastMeasurementStatus'] as String? ?? liveLastMeasurementStatus)
                .toLowerCase(),
        awaitingWeight: awaitingWeight || sizeRaw == 'pending',
        pendingEggId: pendingId,
      );

      // Prefer recentRecords inside /metrics — same tick as the camera commit.
      final Object? embedded = data['recentRecords'];
      bool boardApplied = false;
      if (embedded is List) {
        boardApplied = _applyServerDetectionRows(embedded);
      }
      final http.Response? records = recordsResp;
      if (!boardApplied &&
          records != null &&
          records.statusCode == 200 &&
          records.body.isNotEmpty) {
        final Object? raw = jsonDecode(records.body);
        if (raw is List) {
          boardApplied = _applyServerDetectionRows(raw);
        }
      }
      // Board rows can reveal Dirty labels after counts update — refresh tray.
      if (boardApplied) {
        refreshOperationalNotifications();
      }
    } catch (_) {
      final bool keepLive = iotReadings.isNotEmpty || _cameraRecentlyLive;
      updateLiveInspection(
        goodEggs: liveGoodEggs,
        crackedEggs: liveCrackedEggs,
        dirtyEggs: liveDirtyEggs,
        status: keepLive
            ? (liveInspectionStatus.isEmpty
                ? 'Camera online — waiting for egg'
                : liveInspectionStatus)
            : (backendReachable
                ? 'Farm PC is online. Waiting for ESP32-CAM heartbeat.'
                : 'Backend offline'),
        lastLabel: liveLastLabel,
        lastConfidence: liveLastConfidence,
        connected: keepLive,
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
    bool? awaitingWeight,
    String? pendingEggId,
  }) {
    liveGoodEggs = goodEggs;
    liveCrackedEggs = crackedEggs;
    liveDirtyEggs = dirtyEggs;
    if (goodEggs + crackedEggs > 0) {
      _syncTodayProductionFromLive();
    }
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
    if (awaitingWeight != null) {
      liveAwaitingWeight = awaitingWeight;
    }
    if (pendingEggId != null) {
      livePendingEggId = pendingEggId;
    }
    refreshOperationalNotifications(notify: false);
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

  /// Reset today's live counts: farm /reset + delete today's Firestore eggs.
  /// Returns true when the farm accepted the reset (or local clear completed).
  Future<bool> resetCounters() async {
    _liveBoardHardReset = true;
    _liveBoardHardResetAt = DateTime.now();
    bool farmOk = false;
    final Uri endpoint = Uri.parse('$liveInspectionBackendUrl/reset');
    try {
      final http.Response response = await http
          .post(
            endpoint,
            headers: <String, String>{
              ..._authHeaders,
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
      farmOk = response.statusCode >= 200 && response.statusCode < 300;
    } catch (_) {
      // Local + Firestore clear still runs below.
    }
    await _deleteTodaysFirestoreEggs();
    detectionRecords = const <DetectionRecord>[];
    iotReadings = <IotEggReading>[];
    await OfflineStore.clearLiveDetections();
    // Drop today's live production rollup so the week chart also resets.
    productionRecords = productionRecords
        .where((ProductionRecord r) => r.id != 'live-inspection-today')
        .toList();
    updateLiveInspection(
      goodEggs: 0,
      crackedEggs: 0,
      dirtyEggs: 0,
      status: 'Day counters reset',
      lastLabel: 'N/A',
      lastConfidence: 0.0,
      connected: liveInspectionConnected,
      lastWeightGrams: 0.0,
      lastSizeClass: EggSizeClass.medium,
      awaitingWeight: false,
      pendingEggId: '',
    );
    await persistFarm(clearLiveBoard: true);
    notifyListeners();
    return farmOk;
  }

  /// Merge farm board rows into UI state. Returns true when rows were applied.
  bool _applyServerDetectionRows(List<dynamic> raw) {
    final List<DetectionRecord> next = raw
        .whereType<Map>()
        .map(
          (Map<dynamic, dynamic> row) => DetectionRecord.fromJson(
            Map<String, dynamic>.from(row),
          ),
        )
        .toList();
    // Admin Reset: always accept the farm's empty board (do not rehydrate).
    if (next.isEmpty && _liveBoardHardReset) {
      detectionRecords = const <DetectionRecord>[];
      notifyListeners();
      return true;
    }
    // Never wipe a full board with []. Only Reset clears the list.
    if (next.isEmpty && detectionRecords.isNotEmpty) {
      unawaited(_rehydrateFarmRecords());
      return false;
    }
    if (next.isEmpty) {
      return false;
    }
    if (_liveBoardHardReset) {
      // After reset, replace with whatever the farm returns (usually empty).
      // New camera rows after Reset must notify — otherwise UI stays empty
      // until a hard refresh (updateLiveInspection already notified earlier
      // with the old board).
      detectionRecords = next;
      if (next.isNotEmpty) {
        _liveBoardHardReset = false;
        _liveBoardHardResetAt = null;
      }
      notifyListeners();
      unawaited(_persistLiveDetectionsOnly());
      unawaited(_rememberDetections(raw));
      return true;
    }
    final int before = detectionRecords.length;
    final String beforeTop =
        detectionRecords.isEmpty ? '' : detectionRecords.first.id;
    detectionRecords = _mergeDetectionRecords(detectionRecords, next);
    final ({int good, int cracked}) boardCounts = _countsFromDetectionRecords();
    if (boardCounts.good > liveGoodEggs) {
      liveGoodEggs = boardCounts.good;
    }
    if (boardCounts.cracked > liveCrackedEggs) {
      liveCrackedEggs = boardCounts.cracked;
    }
    _syncTodayProductionFromLive();
    unawaited(_persistLiveDetectionsOnly());
    DetectionRecord? pending;
    for (final DetectionRecord row in detectionRecords) {
      if (row.isPendingWeight) {
        pending = row;
        break;
      }
    }
    if (pending != null) {
      liveAwaitingWeight = true;
      livePendingEggId = pending.timestamp;
      final String pl = pending.label.trim();
      final String lowLab = liveLastLabel.toLowerCase();
      if (liveLastLabel.isEmpty ||
          liveLastLabel == 'N/A' ||
          lowLab == 'empty model' ||
          lowLab == 'scanning') {
        liveLastLabel = pl.toLowerCase().contains('egg')
            ? pl
            : (pl.isEmpty ? 'Clean Egg' : '$pl Egg');
      }
      if (liveLastConfidence < 1.0) {
        liveLastConfidence = pending.confidence;
      }
      if (liveLastWeightGrams < 5.0) {
        liveLastWeightGrams = 0.0;
      }
      if (!liveInspectionStatus.toLowerCase().contains('waiting for weight')) {
        liveInspectionStatus = '${pending.label} recorded — waiting for weight';
      }
    }
    notifyListeners();
    if (detectionRecords.isNotEmpty) {
      unawaited(persistFarm(markDirty: false, notify: false));
    }
    unawaited(_rememberDetections(raw));
    final bool changed = detectionRecords.length != before ||
        (detectionRecords.isNotEmpty && detectionRecords.first.id != beforeTop);
    return changed || next.isNotEmpty;
  }

  List<DetectionRecord> _mergeDetectionRecords(
    List<DetectionRecord> local,
    List<DetectionRecord> remote,
  ) {
    final Map<String, DetectionRecord> byId = <String, DetectionRecord>{};
    for (final DetectionRecord row in <DetectionRecord>[...local, ...remote]) {
      final String key = row.id.isNotEmpty
          ? row.id
          : 'cache-${row.timestamp}_${row.label}'.replaceAll(' ', '_');
      final DetectionRecord? prev = byId[key];
      if (prev == null) {
        byId[key] = row;
        continue;
      }
      // Prefer the row that already has real grams.
      if (row.weightGrams >= 5.0 && prev.weightGrams < 5.0) {
        byId[key] = row;
      } else if (row.weightGrams < 5.0 && prev.weightGrams >= 5.0) {
        byId[key] = prev;
      } else {
        byId[key] = row;
      }
    }
    final List<DetectionRecord> merged = byId.values.toList()
      ..sort((DetectionRecord a, DetectionRecord b) =>
          b.timestamp.compareTo(a.timestamp));
    if (merged.length > 200) {
      return merged.sublist(0, 200);
    }
    return merged;
  }

  Future<void> _persistLiveDetectionsOnly() async {
    // Live board is persisted by the farm backend → Firebase (farm_live/board).
  }

  /// Keep the week production chart in sync with Live Egg Records / counts.
  void _syncTodayProductionFromLive() {
    final ({int good, int cracked}) board = _countsFromDetectionRecords();
    final int total = <int>[
      board.good + board.cracked,
      liveGoodEggs + liveCrackedEggs,
    ].reduce((int a, int b) => a > b ? a : b);
    if (total <= 0) {
      return;
    }
    final String today = _isoDate(DateTime.now());
    const String liveId = 'live-inspection-today';
    final List<ProductionRecord> next = productionRecords
        .where((ProductionRecord r) => r.id != liveId)
        .toList();
    next.insert(
      0,
      ProductionRecord(
        id: liveId,
        date: today,
        timeSlot: 'Live inspection',
        source: 'ESP32-CAM',
        count: total,
        method: 'IoT',
      ),
    );
    productionRecords = next;
  }

  Future<void> _rehydrateFarmRecords() async {
    if (detectionRecords.isEmpty) {
      return;
    }
    try {
      final Uri endpoint =
          Uri.parse('$liveInspectionBackendUrl/records/restore');
      await http
          .post(
            endpoint,
            headers: <String, String>{
              ..._authHeaders,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'records': detectionRecords
                  .map((DetectionRecord r) => r.toJson())
                  .toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _deleteTodaysFirestoreEggs() async {
    if (Firebase.apps.isEmpty) {
      return;
    }
    try {
      final DateTime now = DateTime.now().toUtc();
      final DateTime start = DateTime.utc(now.year, now.month, now.day);
      final QuerySnapshot<Map<String, dynamic>> snap =
          await FirebaseFirestore.instance.collection('egg_readings').limit(300).get();
      WriteBatch? batch;
      int n = 0;
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) {
        final IotEggReading reading = IotEggReading.fromDoc(doc);
        if (reading.createdAt.isBefore(start)) {
          continue;
        }
        batch ??= FirebaseFirestore.instance.batch();
        batch.delete(doc.reference);
        n += 1;
        if (n >= 400) {
          break;
        }
      }
      if (batch != null && n > 0) {
        await batch.commit();
      }
    } catch (_) {}
  }

  ({int good, int cracked}) _countsFromDetectionRecords() {
    int good = 0;
    int cracked = 0;
    for (final DetectionRecord row in detectionRecords) {
      final String cat = row.category.toLowerCase();
      final String lab = row.label.toLowerCase();
      final bool isCrack = cat == 'crackedeggs' ||
          (lab.contains('crack') && !lab.contains('no crack'));
      if (isCrack) {
        cracked += 1;
      } else {
        good += 1;
      }
    }
    return (good: good, cracked: cracked);
  }

  void _applyTodaysCountsFromIot(List<IotEggReading> readings) {
    final DateTime now = DateTime.now().toUtc();
    final DateTime start = DateTime.utc(now.year, now.month, now.day);
    int good = 0;
    int cracked = 0;
    for (final IotEggReading r in readings) {
      if (r.createdAt.isBefore(start)) {
        continue;
      }
      final String g = r.displayGrade.toLowerCase();
      final String raw =
          '${r.grade} ${r.cameraResult ?? ''}'.toLowerCase();
      if (g == 'cracked' || raw.contains('crack')) {
        cracked += 1;
      } else if (g == 'good' ||
          g == 'rejected' ||
          raw.contains('good') ||
          raw.contains('clean') ||
          raw.contains('no crack') ||
          raw.contains('dirt')) {
        // Dirty/dust is not a grade — count as Good.
        good += 1;
      }
    }
    // Never let a late/empty Firestore snapshot roll farm /metrics backwards.
    // Clean pending eggs often hit the board before egg_readings syncs.
    if (good > liveGoodEggs) {
      liveGoodEggs = good;
    }
    if (cracked > liveCrackedEggs) {
      liveCrackedEggs = cracked;
    }
    liveDirtyEggs = 0;
  }

  List<ProductionRecord> productionRecords = <ProductionRecord>[];

  List<GradingRecord> gradingRecords = <GradingRecord>[];
  List<EggSale> eggSales = <EggSale>[];

  /// Hard-deleted sale ids — kept so shared-farm merge cannot resurrect them.
  Set<String> deletedEggSaleIds = <String>{};

  /// Calendar day (yyyy-MM-dd) when admin last set trays available for sale.
  String todayTrayStockDate = '';
  int todayTrayStockSet = 0;

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
  ];

  List<InventoryZone> inventoryZones = const <InventoryZone>[
    InventoryZone(id: 'zone-cold-1', name: 'Cold Room 1'),
    InventoryZone(id: 'zone-pack', name: 'Packing Area'),
    InventoryZone(id: 'zone-qc', name: 'Quality Control'),
  ];

  List<InventoryMovement> inventoryMovements = const <InventoryMovement>[];

  List<InventoryDevice> inventoryDevices = const <InventoryDevice>[];

  String _saleDayIso(EggSale sale) {
    final DateTime? parsed = DateTime.tryParse(sale.createdAt);
    if (parsed == null) {
      return '';
    }
    return _isoDate(parsed.toLocal());
  }

  int get todaySalesEggCount {
    final String today = _isoDate(DateTime.now());
    return eggSales
        .where((EggSale s) => _saleDayIso(s) == today)
        .fold<int>(0, (int sum, EggSale s) => sum + s.eggCount);
  }

  double get todaySalesRevenue {
    final String today = _isoDate(DateTime.now());
    return eggSales
        .where((EggSale s) => _saleDayIso(s) == today)
        .fold<double>(0, (double sum, EggSale s) => sum + s.total);
  }

  List<ReportTrendPoint> get reportTrendPoints {
    final DateTime now = DateTime.now();
    final List<ReportTrendPoint> points = <ReportTrendPoint>[];
    for (int i = 6; i >= 0; i--) {
      final DateTime day = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: i));
      final String iso = _isoDate(day);
      final int produced = productionRecords
          .where((ProductionRecord r) => r.date == iso)
          .fold<int>(0, (int s, ProductionRecord r) => s + r.count);
      final int sold = eggSales
          .where((EggSale s) => _saleDayIso(s) == iso)
          .fold<int>(0, (int s, EggSale sale) => s + sale.eggCount);
      final int graded = gradingRecords
          .where((GradingRecord r) => r.date == iso)
          .fold<int>(0, (int s, GradingRecord r) => s + r.quantity);
      final int cracked = gradingRecords
          .where(
            (GradingRecord r) =>
                r.date == iso && r.quality.toLowerCase().contains('crack'),
          )
          .fold<int>(0, (int s, GradingRecord r) => s + r.quantity);
      final int liveCrack =
          iso == _isoDate(now) ? liveCrackedEggs : 0;
      points.add(
        ReportTrendPoint(
          label: '${day.month}/${day.day}',
          production: produced > 0
              ? produced
              : (iso == _isoDate(now)
                  ? liveGoodEggs + liveCrackedEggs
                  : 0),
          sales: sold,
          losses: cracked + liveCrack,
          graded: graded > 0
              ? graded
              : (iso == _isoDate(now)
                  ? liveGoodEggs + liveCrackedEggs
                  : 0),
          collected: produced > 0
              ? produced
              : (iso == _isoDate(now) ? workerTodayCollection : 0),
        ),
      );
    }
    return points;
  }

  List<ReportBreakdownRow> get reportWeeklyBreakdown {
    return reportTrendPoints
        .map(
          (ReportTrendPoint p) => ReportBreakdownRow(
            label: p.label,
            production: p.production,
            sales: p.sales,
            losses: p.losses,
          ),
        )
        .toList();
  }

  List<InsightNote> get reportInsights {
    final List<InsightNote> notes = <InsightNote>[];
    final int liveTotal = liveGoodEggs + liveCrackedEggs;
    if (liveTotal > 0) {
      final int goodPct =
          ((liveGoodEggs / liveTotal) * 100).round().clamp(0, 100);
      notes.add(
        InsightNote(
          title: 'Live inspection quality',
          description:
              '$goodPct% good today ($liveGoodEggs clean, $liveCrackedEggs cracked).',
        ),
      );
    }
    if (todayProductionTotal > 0) {
      notes.add(
        InsightNote(
          title: 'Production logged',
          description:
              '$todayProductionTotal eggs recorded in production for today.',
        ),
      );
    }
    if (todaySalesEggCount > 0) {
      notes.add(
        InsightNote(
          title: 'Sales moving',
          description:
              '$todaySalesEggCount eggs sold today (₱${todaySalesRevenue.toStringAsFixed(0)}).',
        ),
      );
    }
    if (notes.isEmpty) {
      notes.add(
        const InsightNote(
          title: 'Waiting for farm activity',
          description:
              'Insights appear after production, inspection, or sales records are logged.',
        ),
      );
    }
    return notes;
  }

  List<ReportModuleSummary> get reportModuleSummaries {
    final int produced = productionRecords.fold<int>(
      0,
      (int s, ProductionRecord r) => s + r.count,
    );
    final int soldEggs = eggSales.fold<int>(
      0,
      (int s, EggSale sale) => s + sale.eggCount,
    );
    final double revenue = eggSales.fold<double>(
      0,
      (double s, EggSale sale) => s + sale.total,
    );
    final int stock = totalInventoryUnits;
    final int lowStock = inventoryItems
        .where((InventoryItem i) => i.quantity <= i.minThreshold)
        .length;
    final int graded = gradingRecords.fold<int>(
      0,
      (int s, GradingRecord r) => s + r.quantity,
    );
    final int liveTotal = liveGoodEggs + liveCrackedEggs;
    final int goodRate = liveTotal == 0
        ? 0
        : ((liveGoodEggs / liveTotal) * 100).round();
    final int crackRate = liveTotal == 0
        ? 0
        : ((liveCrackedEggs / liveTotal) * 100).round();
    return <ReportModuleSummary>[
    ReportModuleSummary(
      module: 'Production',
      icon: Icons.egg_alt_outlined,
      color: Colors.amber,
      metrics: <ReportMetric>[
          ReportMetric(label: 'Total Produced', value: '$produced', change: 0),
          ReportMetric(
            label: 'Today',
            value: '$todayProductionTotal',
            change: 0,
          ),
          ReportMetric(
            label: 'Live inspected',
            value: '$liveTotal',
            change: 0,
          ),
      ],
    ),
    ReportModuleSummary(
      module: 'Sales',
      icon: Icons.bar_chart_rounded,
      color: Colors.green,
      metrics: <ReportMetric>[
          ReportMetric(
            label: 'Total Revenue',
            value: 'PHP ${revenue.toStringAsFixed(0)}',
            change: 0,
          ),
          ReportMetric(label: 'Eggs Sold', value: '$soldEggs', change: 0),
          ReportMetric(
            label: 'Today',
            value: '$todaySalesEggCount',
            change: 0,
          ),
      ],
    ),
    ReportModuleSummary(
      module: 'Inventory',
      icon: Icons.inventory_2_outlined,
      color: Colors.lightBlue,
      metrics: <ReportMetric>[
          ReportMetric(label: 'Current Stock', value: '$stock', change: 0),
          ReportMetric(
            label: 'SKUs tracked',
            value: '${inventoryItems.length}',
            change: 0,
          ),
          ReportMetric(
            label: 'Low Stock Alerts',
            value: '$lowStock',
            change: 0,
          ),
      ],
    ),
    ReportModuleSummary(
      module: 'Grading',
      icon: Icons.star_outline_rounded,
      color: Colors.orange,
      metrics: <ReportMetric>[
          ReportMetric(label: 'Good Rate', value: '$goodRate%', change: 0),
          ReportMetric(label: 'Cracked', value: '$crackRate%', change: 0),
          ReportMetric(
            label: 'Total Graded',
            value: '${graded > 0 ? graded : liveTotal}',
            change: 0,
          ),
      ],
    ),
    ReportModuleSummary(
      module: 'Losses',
      icon: Icons.warning_amber_rounded,
      color: Colors.redAccent,
      metrics: <ReportMetric>[
          ReportMetric(
            label: 'Cracked today',
            value: '$liveCrackedEggs',
            change: 0,
          ),
          ReportMetric(label: 'Loss Rate', value: '$crackRate%', change: 0),
          const ReportMetric(label: 'Top Cause', value: 'Crack', change: 0),
      ],
    ),
    ReportModuleSummary(
      module: 'Collection',
      icon: Icons.schedule_outlined,
      color: Colors.deepPurpleAccent,
      metrics: <ReportMetric>[
          ReportMetric(
            label: 'Today collected',
            value: '$workerTodayCollection',
            change: 0,
          ),
          ReportMetric(
            label: 'Unread alerts',
            value: '$workerUnreadCount',
            change: 0,
          ),
      ],
    ),
  ];
  }

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

  int get availableTrays {
    for (final InventoryItem item in inventoryItems) {
      if (item.id == 'inv-trays') {
        return item.quantity;
      }
    }
    return 0;
  }

  int get availableSellableEggs {
    int total = 0;
    for (final InventoryItem item in inventoryItems) {
      if (item.category == 'Sellable Eggs') {
        total += item.quantity;
      }
    }
    return total;
  }

  bool get hasTodayTrayStock {
    return todayTrayStockDate == _isoDate(DateTime.now()) &&
        todayTrayStockSet > 0;
  }

  InventoryItem _withQuantity(InventoryItem item, int quantity) {
    return InventoryItem(
      id: item.id,
      name: item.name,
      sku: item.sku,
      category: item.category,
      zoneId: item.zoneId,
      quantity: quantity.clamp(0, item.maxCapacity),
      minThreshold: item.minThreshold,
      maxCapacity: item.maxCapacity,
      unit: item.unit,
    );
  }

  /// Admin sets how many trays are available to sell today (1 tray = 30 eggs).
  void setTodayTrayStock(int trays) {
    final int safeTrays = trays < 0 ? 0 : trays;
    final int eggs = safeTrays * 30;
    final String stamp = DateTime.now().toUtc().toIso8601String();
    final String day = _isoDate(DateTime.now());
    final List<InventoryMovement> moves = <InventoryMovement>[];
    final List<InventoryItem> next = <InventoryItem>[];

    for (final InventoryItem item in inventoryItems) {
      if (item.id == 'inv-trays') {
        next.add(_withQuantity(item, safeTrays));
        moves.add(
          InventoryMovement(
            id: 'mov-today-trays-$stamp',
            itemId: item.id,
            movementType: 'stock_in',
            source: 'Admin today trays',
            quantityDelta: safeTrays - item.quantity,
            quantityAfter: safeTrays.clamp(0, item.maxCapacity),
            timestamp: stamp,
            note: 'Set $safeTrays tray(s) available for $day',
          ),
        );
        continue;
      }
      if (item.id == 'inv-egg-a') {
        next.add(_withQuantity(item, eggs));
        moves.add(
          InventoryMovement(
            id: 'mov-today-eggs-$stamp',
            itemId: item.id,
            movementType: 'stock_in',
            source: 'Admin today trays',
            quantityDelta: eggs - item.quantity,
            quantityAfter: eggs.clamp(0, item.maxCapacity),
            timestamp: stamp,
            note: '$safeTrays tray(s) × 30 = $eggs Grade A eggs for $day',
          ),
        );
        continue;
      }
      next.add(item);
    }

    inventoryItems = next;
    inventoryMovements = <InventoryMovement>[...moves, ...inventoryMovements]
        .take(500)
        .toList();
    todayTrayStockDate = day;
    todayTrayStockSet = safeTrays;
    unawaited(persistFarm());
    notifyListeners();
  }

  /// Hard-deletes today's tray allocation from UI + shared farm DB (stock → 0).
  void deleteTodayTrayStock() {
    final String stamp = DateTime.now().toUtc().toIso8601String();
    final String day = todayTrayStockDate.isNotEmpty
        ? todayTrayStockDate
        : _isoDate(DateTime.now());
    final List<InventoryMovement> moves = <InventoryMovement>[];
    final List<InventoryItem> next = <InventoryItem>[];

    for (final InventoryItem item in inventoryItems) {
      if (item.id == 'inv-trays' || item.id == 'inv-egg-a') {
        final int before = item.quantity;
        next.add(_withQuantity(item, 0));
        if (before != 0) {
          moves.add(
            InventoryMovement(
              id: 'mov-del-${item.id}-$stamp',
              itemId: item.id,
              movementType: 'stock_out',
              source: 'Admin delete trays',
              quantityDelta: -before,
              quantityAfter: 0,
              timestamp: stamp,
              note: 'Hard-deleted today tray stock for $day',
            ),
          );
        }
        continue;
      }
      next.add(item);
    }

    inventoryItems = next;
    if (moves.isNotEmpty) {
      inventoryMovements = <InventoryMovement>[...moves, ...inventoryMovements]
          .take(500)
          .toList();
    }
    todayTrayStockDate = '';
    todayTrayStockSet = 0;
    unawaited(persistFarm());
    notifyListeners();
  }

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
      // Token alone used to leave the app stuck on /auth when the cached
      // profile was missing (refresh / new browser). Recover via /auth/me.
      if (_currentUser == null && !_isLocalSessionToken(token)) {
        try {
          backendBaseUrl = ApiConfig.apiBaseUrl;
          _authApi = AuthApi(baseUrl: backendBaseUrl);
          final result = await _authApi.me(
            token,
            timeout: const Duration(seconds: 12),
          );
          _applySession(
            await _respectSalesDesk(DemoUser.fromJson(result.user)),
            result.session,
          );
          backendReachable = true;
          await _persistCachedUser();
        } on AuthException catch (error) {
          if (error.isUnauthorized) {
            await SecureSessionStore.clear();
            _clearSession(notify: false);
          }
        } catch (_) {}
      }
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
    // Farm SQLite accepted the row; cloud upload may still be pending.
    if (parsed is Map && parsed['ok'] == true) {
      final Object? status = parsed['syncStatus'];
      if (status == 'pending' || status == 'local') {
        return EggPushResult.synced;
      }
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
                  ? 'Good'
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
    workerTodayCollection = todayProductionTotal > workerTodayCollection
        ? todayProductionTotal
        : workerTodayCollection;
    await _loadNotificationReadState();
    refreshOperationalNotifications();
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
    // Hosted web → farm tunnel API (workers.dev rate-limits /auth with 429).
    if (ApiConfig.isHostedHttpsWeb) {
      final String api = ApiConfig.apiBaseUrl;
      backendBaseUrl = api;
      _authApi = AuthApi(baseUrl: api);
      // Skip LAN discover on HTTPS — mixed content + console spam.
      bool ok = await OfflineStore.ping(api);
      if (!ok && api != ApiConfig.workersFarmUrl) {
        ok = await OfflineStore.ping(ApiConfig.workersFarmUrl);
        if (ok) {
          backendBaseUrl = ApiConfig.workersFarmUrl;
          _authApi = AuthApi(baseUrl: backendBaseUrl);
        }
      }
      backendReachable = ok;
      if (!ok && !silent) {
        throw AuthException(
          'Farm tunnel offline. On the farm PC run start-egg-tunnel-smart.bat.',
          code: 'backend_unreachable',
        );
      }
      return ok;
    }
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

  /// Farm login is separate from Firebase Auth. Ensure a Firebase session so
  /// egg_readings listeners work when older rules still require request.auth.
  Future<void> _ensureFirebaseAuthForFirestore() async {
    if (Firebase.apps.isEmpty) {
      return;
    }
    if (firebase_auth.FirebaseAuth.instance.currentUser != null) {
      return;
    }
    try {
      await firebase_auth.FirebaseAuth.instance.signInAnonymously();
    } catch (_) {
      // Anonymous Auth may be disabled — deployed rules allow public egg read.
    }
  }

  Future<void> _mirrorFirebaseEmailAuth({
    required String email,
    required String password,
  }) async {
    if (Firebase.apps.isEmpty || password.isEmpty || password == 'google') {
      return;
    }
    try {
      await firebase_auth.FirebaseAuth.instance
          .signInWithEmailAndPassword(
            email: email.trim(),
            password: password,
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      try {
        await firebase_auth.FirebaseAuth.instance
            .createUserWithEmailAndPassword(
              email: email.trim(),
              password: password,
            )
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        try {
          await _ensureFirebaseAuthForFirestore()
              .timeout(const Duration(seconds: 3));
        } catch (_) {}
      }
    }
  }

  /// Firebase + farm pull must never block the login screen from opening home.
  Future<void> _finishLoginInBackground({
    required String email,
    required String password,
  }) async {
    try {
      await _mirrorFirebaseEmailAuth(email: email, password: password);
    } catch (_) {}
    try {
      await _pullRemoteFarmIfAny().timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  void startIotReadingsListener() {
    _iotSubscription?.cancel();
    if (Firebase.apps.isEmpty) {
      return;
    }
    unawaited(() async {
      await _ensureFirebaseAuthForFirestore();
      _attachEggReadingsListener();
    }());
  }

  void _attachEggReadingsListener() {
    _iotSubscription?.cancel();
    try {
      _iotSubscription = FirebaseFirestore.instance
          .collection('egg_readings')
          .orderBy('createdAt', descending: true)
          .limit(80)
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
              _applyTodaysCountsFromIot(next);
              // Never let a late snapshot reduce live farm counts.
              // Live SIZE CLASS comes from farm /metrics (current load cell).
              if (next.isNotEmpty) {
                liveInspectionConnected = true;
              }
              // Clear stale permission banner once snapshots succeed.
              if (liveInspectionStatus.toLowerCase().contains('firestore')) {
                liveInspectionStatus = 'Live inspection running';
              }
    notifyListeners();
            },
            onError: (Object error) {
              // Fallback without orderBy if index missing — still live updates.
              _iotSubscription?.cancel();
              _iotSubscription = FirebaseFirestore.instance
                  .collection('egg_readings')
                  .limit(80)
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
                      _applyTodaysCountsFromIot(next);
                      if (next.isNotEmpty) {
                        liveInspectionConnected = true;
                      }
                      if (liveInspectionStatus
                          .toLowerCase()
                          .contains('firestore')) {
                        liveInspectionStatus = 'Live inspection running';
                      }
                      notifyListeners();
                    },
                    onError: (Object err2) {
                      // Farm /metrics + /records still drive Live Inspection.
                      if (detectionRecords.isEmpty && !liveAwaitingWeight) {
                        liveInspectionStatus =
                            'Firestore IoT error: $err2';
                      }
              notifyListeners();
                    },
                  );
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
    // Reject legacy local-only tokens — sessions must come from Firebase auth.
    if (_isLocalSessionToken(token)) {
      await SecureSessionStore.clear();
      await OfflineStore.clearCachedUser();
      await OfflineStore.clearLocalAccounts();
      return;
    }
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
      refreshOperationalNotifications();
    }
  }

  Future<void> _loadFarmFromDisk() async {
    // Farm ledger + live board live in Firebase. Do not hydrate from local cache.
    // Remote pull happens after a valid Firebase session is restored.
    farmSyncPending = false;
    await OfflineStore.clearFarmCache();
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
      'eggSales': eggSales.map((EggSale sale) => sale.toJson()).toList(),
      'deletedEggSaleIds': deletedEggSaleIds.toList(),
      'todayTrayStockDate': todayTrayStockDate,
      'todayTrayStockSet': todayTrayStockSet,
      'liveGoodEggs': liveGoodEggs,
      'liveCrackedEggs': liveCrackedEggs,
      'liveDirtyEggs': liveDirtyEggs,
      'detectionRecords':
          detectionRecords.map((DetectionRecord r) => r.toJson()).toList(),
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
    if (stored.containsKey('deletedEggSaleIds')) {
      final Object? rawDeleted = stored['deletedEggSaleIds'];
      if (rawDeleted is List) {
        deletedEggSaleIds = <String>{
          ...deletedEggSaleIds,
          ...rawDeleted
              .map((Object? e) => e.toString())
              .where((String e) => e.isNotEmpty),
        };
      }
    }
    if (stored.containsKey('eggSales')) {
      final List<dynamic> sales = stored['eggSales'] as List<dynamic>? ?? <dynamic>[];
      final List<EggSale> remoteSales = sales
          .whereType<Map>()
          .map((Map<dynamic, dynamic> item) =>
              EggSale.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      // Never drop local sales when a seller/admin snapshot arrives.
      eggSales = _mergeEggSales(eggSales, remoteSales);
    } else if (deletedEggSaleIds.isNotEmpty) {
      eggSales = eggSales
          .where((EggSale sale) => !deletedEggSaleIds.contains(sale.id))
          .toList();
    }
    if (stored.containsKey('todayTrayStockDate')) {
      todayTrayStockDate = stored['todayTrayStockDate'] as String? ?? '';
    }
    if (stored.containsKey('todayTrayStockSet')) {
      todayTrayStockSet = stored['todayTrayStockSet'] as int? ?? 0;
    }
    liveGoodEggs = (stored['liveGoodEggs'] as int? ?? liveGoodEggs) +
        (stored['liveDirtyEggs'] as int? ?? 0);
    liveCrackedEggs = stored['liveCrackedEggs'] as int? ?? liveCrackedEggs;
    liveDirtyEggs = 0;
    if (workerTodayCollection <= 0) {
      workerTodayCollection = todayProductionTotal;
    }
    final List<dynamic> detections =
        stored['detectionRecords'] as List<dynamic>? ?? <dynamic>[];
    if (_liveBoardHardReset) {
      // Keep the admin Reset empty board; do not revive rows from farm cache.
      detectionRecords = const <DetectionRecord>[];
      liveGoodEggs = 0;
      liveCrackedEggs = 0;
      liveDirtyEggs = 0;
    } else if (detections.isNotEmpty) {
      final List<DetectionRecord> fromSnap = detections
          .whereType<Map>()
          .map(
            (Map<dynamic, dynamic> row) => DetectionRecord.fromJson(
              Map<String, dynamic>.from(row),
            ),
          )
          .toList();
      detectionRecords = _mergeDetectionRecords(detectionRecords, fromSnap);
      // Cached board rows still count even if /metrics was reset on farm restart.
      final ({int good, int cracked}) boardCounts =
          _countsFromDetectionRecords();
      if (boardCounts.good > liveGoodEggs) {
        liveGoodEggs = boardCounts.good;
      }
      if (boardCounts.cracked > liveCrackedEggs) {
        liveCrackedEggs = boardCounts.cracked;
      }
    }
  }

  Future<void> persistFarm({
    bool markDirty = true,
    bool notify = true,
    bool clearLiveBoard = false,
  }) async {
    // Firebase is the only store — push via /farm/snapshot (no SharedPreferences ledger).
    if (clearLiveBoard || _liveBoardHardReset) {
      await OfflineStore.clearLiveDetections();
    }
    if (!markDirty) {
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
    workerTodayCollection = todayProductionTotal;
    refreshOperationalNotifications();
    unawaited(persistFarm());
  }

  String? _sellableInventoryIdForSale(EggSale sale) {
    final String size = sale.size.trim().toLowerCase();
    for (final InventoryItem item in inventoryItems) {
      if (item.category != 'Sellable Eggs') {
        continue;
      }
      final String hay =
          '${item.name} ${item.sku} ${item.id}'.toLowerCase();
      if (size.isNotEmpty && hay.contains(size)) {
        return item.id;
      }
    }
    for (final InventoryItem item in inventoryItems) {
      if (item.id == 'inv-egg-a' || item.category == 'Sellable Eggs') {
        return item.id;
      }
    }
    return null;
  }

  void _applySaleToInventory(EggSale sale, {bool reverse = false}) {
    final int eggsOut = sale.eggCount;
    if (eggsOut <= 0) {
      return;
    }
    final int eggDelta = reverse ? eggsOut : -eggsOut;
    final String? itemId = _sellableInventoryIdForSale(sale);
    if (itemId == null) {
      return;
    }
    final List<InventoryItem> nextItems = <InventoryItem>[];
    int eggsAfter = 0;
    for (final InventoryItem item in inventoryItems) {
      if (item.id != itemId) {
        nextItems.add(item);
        continue;
      }
      eggsAfter = (item.quantity + eggDelta).clamp(0, item.maxCapacity);
      nextItems.add(_withQuantity(item, eggsAfter));
    }
    inventoryItems = nextItems;

    final String stamp = DateTime.now().toUtc().toIso8601String();
    final List<InventoryMovement> nextMoves = <InventoryMovement>[
      InventoryMovement(
        id: reverse ? 'mov-sale-del-${sale.id}' : 'mov-sale-${sale.id}',
        itemId: itemId,
        movementType: reverse ? 'stock_in' : 'stock_out',
        source: reverse ? 'Sale deleted' : 'Egg Sales',
        quantityDelta: eggDelta,
        quantityAfter: eggsAfter,
        timestamp: reverse ? stamp : sale.createdAt,
        note: reverse
            ? 'Restored after hard-deleting sale ${sale.id}'
            : '${sale.perTray ? '${sale.quantity} tray(s)' : '${sale.quantity} pc'} '
                '${sale.size} • ${sale.sellerName.isEmpty ? sale.sellerEmail : sale.sellerName}'
                '${sale.buyer.isEmpty ? '' : ' → ${sale.buyer}'}',
      ),
      ...inventoryMovements,
    ];

    if (sale.perTray && sale.quantity > 0) {
      final int trayDelta = reverse ? sale.quantity : -sale.quantity;
      final List<InventoryItem> withTrays = <InventoryItem>[];
      for (final InventoryItem item in inventoryItems) {
        if (item.id != 'inv-trays') {
          withTrays.add(item);
          continue;
        }
        final int traysAfter =
            (item.quantity + trayDelta).clamp(0, item.maxCapacity);
        withTrays.add(_withQuantity(item, traysAfter));
        nextMoves.insert(
          0,
          InventoryMovement(
            id: reverse ? 'mov-tray-del-${sale.id}' : 'mov-tray-${sale.id}',
            itemId: item.id,
            movementType: reverse ? 'stock_in' : 'stock_out',
            source: reverse ? 'Sale deleted' : 'Egg Sales',
            quantityDelta: trayDelta,
            quantityAfter: traysAfter,
            timestamp: reverse ? stamp : sale.createdAt,
            note: reverse
                ? 'Restored trays after deleting ${sale.id}'
                : 'Trays sold with ${sale.id}',
          ),
        );
      }
      inventoryItems = withTrays;
    }

    inventoryMovements = nextMoves.take(500).toList();
  }

  List<EggSale> _mergeEggSales(List<EggSale> a, List<EggSale> b) {
    final Map<String, EggSale> byId = <String, EggSale>{};
    for (final EggSale sale in <EggSale>[...a, ...b]) {
      if (sale.id.isEmpty || deletedEggSaleIds.contains(sale.id)) {
        continue;
      }
      byId.putIfAbsent(sale.id, () => sale);
    }
    final List<EggSale> merged = byId.values.toList()
      ..sort((EggSale x, EggSale y) => y.createdAt.compareTo(x.createdAt));
    return merged;
  }

  void addEggSale(EggSale sale) {
    if (deletedEggSaleIds.contains(sale.id) ||
        eggSales.any((EggSale existing) => existing.id == sale.id)) {
      return;
    }
    eggSales = <EggSale>[sale, ...eggSales];
    _applySaleToInventory(sale);
    unawaited(persistFarm());
    notifyListeners();
  }

  /// Permanently removes a sale from UI + shared farm DB and restores stock.
  void deleteEggSale(String id) {
    final String saleId = id.trim();
    if (saleId.isEmpty) {
      return;
    }
    EggSale? found;
    for (final EggSale sale in eggSales) {
      if (sale.id == saleId) {
        found = sale;
        break;
      }
    }
    deletedEggSaleIds = <String>{...deletedEggSaleIds, saleId};
    if (found != null) {
      eggSales =
          eggSales.where((EggSale sale) => sale.id != saleId).toList();
      _applySaleToInventory(found, reverse: true);
      // Drop the original stock-out rows tied to this sale id.
      inventoryMovements = inventoryMovements
          .where(
            (InventoryMovement m) =>
                m.id != 'mov-sale-$saleId' && m.id != 'mov-tray-$saleId',
          )
          .toList();
    } else {
      eggSales =
          eggSales.where((EggSale sale) => sale.id != saleId).toList();
    }
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
      final List<EggSale> keepSales = List<EggSale>.from(eggSales);
      final List<DetectionRecord> keepBoard = detectionRecords;
      final List<InventoryItem> keepInventory =
          List<InventoryItem>.from(inventoryItems);
      if (remoteUpdated.compareTo(localUpdated) > 0) {
        _applyFarmSnapshot(remote);
      } else {
        // Still merge sales/inventory ledgers so seller updates reach admin.
        final Object? remoteSales = remote['eggSales'];
        if (remoteSales is List) {
          eggSales = _mergeEggSales(
            eggSales,
            remoteSales
                .whereType<Map>()
                .map(
                  (Map<dynamic, dynamic> item) =>
                      EggSale.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList(),
          );
        }
        final Object? remoteInventory = remote['inventory'];
        if (remoteInventory is List && remoteInventory.isNotEmpty) {
          final List<InventoryItem> incoming = remoteInventory
              .whereType<Map>()
              .map(
                (Map<dynamic, dynamic> item) =>
                    InventoryItem.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList();
          if (incoming.isNotEmpty) {
            inventoryItems = incoming;
          }
        }
        final Object? remoteMoves = remote['movements'];
        if (remoteMoves is List && remoteMoves.isNotEmpty) {
          final Map<String, InventoryMovement> byId =
              <String, InventoryMovement>{};
          for (final InventoryMovement move in inventoryMovements) {
            byId[move.id] = move;
          }
          for (final Object? row in remoteMoves) {
            if (row is! Map) {
              continue;
            }
            final InventoryMovement move = InventoryMovement.fromJson(
              Map<String, dynamic>.from(row),
            );
            if (move.id.isNotEmpty) {
              byId.putIfAbsent(move.id, () => move);
            }
          }
          inventoryMovements = byId.values.toList()
            ..sort(
              (InventoryMovement a, InventoryMovement b) =>
                  b.timestamp.compareTo(a.timestamp),
            );
        }
      }
      eggSales = _mergeEggSales(keepSales, eggSales);
      if (keepBoard.isNotEmpty) {
        detectionRecords = _mergeDetectionRecords(keepBoard, detectionRecords);
      }
      // Seller desks often have empty default stock — don't wipe admin inventory.
      if (isSales &&
          keepInventory.any((InventoryItem i) => i.quantity > 0) &&
          inventoryItems.every((InventoryItem i) => i.quantity <= 0)) {
        inventoryItems = keepInventory;
      }
      final bool gainedSales = eggSales.length > keepSales.length;
      if (gainedSales) {
        farmSyncPending = true;
        await _pushFarmIfDirty();
      } else {
        farmSyncPending = false;
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<DemoUser> _respectSalesDesk(DemoUser user) async {
    // Role comes from Firebase (farm_users) via the auth API — no local override.
    return user;
  }

  /// Real Gmail only — reject @eggsystem.local and any non-Gmail host.
  static bool isRealGmail(String email) {
    final String normalized = email.trim().toLowerCase();
    if (normalized.isEmpty ||
        normalized.contains(' ') ||
        normalized.split('@').length != 2) {
      return false;
    }
    return normalized.endsWith('@gmail.com') ||
        normalized.endsWith('@googlemail.com');
  }

  Future<void> login({required String email, required String password}) async {
    if (!isRealGmail(email)) {
      throw AuthException(
        'Use a real Gmail account (@gmail.com). Local emails are not allowed.',
        code: 'gmail_required',
      );
    }
    // Hosted web → farm tunnel (workers.dev returns 429 on /auth/login).
    // LAN/desktop → farm PC URL. Accounts live in Firebase only — no offline login.
    backendBaseUrl = ApiConfig.apiBaseUrl;
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
      await OfflineStore.clearLocalAccounts();
      unawaited(
        _finishLoginInBackground(email: email, password: password),
      );
      return;
    } on AuthException catch (error) {
      // Retry via Worker once if the tunnel path is what failed with 429/5xx.
      if (ApiConfig.isHostedHttpsWeb &&
          backendBaseUrl == ApiConfig.farmTunnelUrl &&
          (error.message.contains('429') ||
              error.message.contains('502') ||
              error.message.contains('503'))) {
        try {
          backendBaseUrl = ApiConfig.workersFarmUrl;
          _authApi = AuthApi(baseUrl: backendBaseUrl);
          final result = await _authApi.login(email: email, password: password);
          final DemoUser user = await _respectSalesDesk(
            DemoUser.fromJson(result.user),
          );
          await _persistSession(result.session.token);
          _applySession(user, result.session);
          backendReachable = true;
          await _persistCachedUser();
          await OfflineStore.clearLocalAccounts();
          unawaited(
            _finishLoginInBackground(email: email, password: password),
          );
          return;
        } on AuthException catch (retryError) {
          throw AuthException(
            'Farm server unreachable. Accounts are stored in Firebase — '
            'start the backend / tunnel, then sign in again. (${retryError.message})',
            code: 'backend_unreachable',
          );
        }
      }
      rethrow;
    } catch (error) {
      throw AuthException(
        'Cannot reach the farm server. Accounts are stored in Firebase only — '
        'no offline sign-in. Start the backend, then try again.',
        code: 'backend_unreachable',
      );
    }
  }

  Future<void> completeLoginWithCode(
    String code, {
    String? password,
  }) async {
    final bool online = await connectBackend(silent: true);
    if (!online) {
      backendBaseUrl = ApiConfig.apiBaseUrl;
      _authApi = AuthApi(baseUrl: backendBaseUrl);
    }
    final result = await _authApi.verifyLogin(code);
    final DemoUser user = await _respectSalesDesk(DemoUser.fromJson(result.user));
    await _persistSession(result.session.token);
    _applySession(user, result.session);
    backendReachable = true;
    await _persistCachedUser();
    await OfflineStore.clearLocalAccounts();
    if (password != null && password.isNotEmpty) {
      unawaited(
        _finishLoginInBackground(email: user.email, password: password),
      );
    } else {
      unawaited(
        _pullRemoteFarmIfAny().timeout(const Duration(seconds: 8)),
      );
    }
  }

  Future<AuthMailResult> signup({
    required String name,
    required String email,
    required String password,
    String role = 'worker',
  }) async {
    if (!isRealGmail(email)) {
      throw AuthException(
        'Use a real Gmail account (@gmail.com). Local emails are not allowed.',
        code: 'gmail_required',
      );
    }
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
      await OfflineStore.clearLocalAccounts();
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

  /// Admin directory of real Gmail accounts (Firebase farm_users).
  Future<List<DemoUser>> listFarmAccounts() async {
    final String? token = _sessionToken;
    if (token == null || token.isEmpty || _isLocalSessionToken(token)) {
      throw AuthException(
        'Sign in online as admin to load accounts.',
        code: 'backend_unreachable',
      );
    }
    final List<Map<String, dynamic>> rows = await _authApi.listUsers(token);
    return rows.map(DemoUser.fromJson).toList();
  }

  Future<DemoUser> updateFarmAccount({
    required String email,
    String? role,
    bool? disabled,
  }) async {
    final String? token = _sessionToken;
    if (token == null || token.isEmpty || _isLocalSessionToken(token)) {
      throw AuthException(
        'Sign in online as admin to manage accounts.',
        code: 'backend_unreachable',
      );
    }
    final Map<String, dynamic> body = await _authApi.adminUpdateUser(
      token: token,
      email: email,
      role: role,
      disabled: disabled,
    );
    final Object? user = body['user'];
    if (user is! Map) {
      throw AuthException(
        body['message'] as String? ?? 'Update failed.',
        code: body['code'] as String?,
      );
    }
    return DemoUser.fromJson(Map<String, dynamic>.from(user));
  }

  /// Admin creates a worker in Firebase. Returns status + verification code to share.
  Future<({String message, String? verificationCode, bool emailSent})>
      createWorkerAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    return _adminCreateFarmAccount(
      name: name,
      email: email,
      password: password,
      role: 'worker',
    );
  }

  /// Admin creates a sales-only account in Firebase (not auto-verified).
  Future<({String message, String? verificationCode, bool emailSent})>
      createSalesAccount({
    required String name,
    required String email,
    required String password,
  }) async {
    return _adminCreateFarmAccount(
      name: name,
      email: email,
      password: password,
      role: 'sales',
    );
  }

  Future<({String message, String? verificationCode, bool emailSent})>
      _adminCreateFarmAccount({
    required String name,
    required String email,
    required String password,
    required String role,
  }) async {
    if (!isRealGmail(email)) {
      throw AuthException(
        'Use a real Gmail account (@gmail.com).',
        code: 'gmail_required',
      );
    }
    final String? token = _sessionToken;
    if (token == null || token.isEmpty || _isLocalSessionToken(token)) {
      throw AuthException(
        'Sign in as admin first. Accounts are stored in Firebase only.',
        code: 'backend_unreachable',
      );
    }
    final bool online = await connectBackend(silent: true);
    if (!online) {
      throw AuthException(
        'Cannot reach the farm server. Accounts are stored in Firebase only.',
        code: 'backend_unreachable',
      );
    }
    final AuthMailResult result = await _authApi.adminCreateUser(
      token: token,
      name: name,
      email: email,
      password: password,
      role: role,
    );
    final String? code = (result.verificationCode ?? '').trim().isEmpty
        ? null
        : result.verificationCode!.trim();
    return (
      message: result.message,
      verificationCode: code,
      emailSent: result.emailSent,
    );
  }

  Future<String> verifyEmail(String token) => _authApi.verifyEmail(token);

  Future<AuthMailResult> resendVerification(String email, {String? password}) {
    return _authApi.resendVerification(email, password: password);
  }

  /// After the user opens the Firebase verification link in Gmail.
  Future<void> confirmFirebaseEmail({
    required String email,
    required String password,
  }) async {
    if (!isRealGmail(email)) {
      throw AuthException(
        'Use a real Gmail account (@gmail.com). Local emails are not allowed.',
        code: 'gmail_required',
      );
    }
    final result = await _authApi.confirmFirebaseEmail(
      email: email,
      password: password,
    );
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
    unawaited(
      _finishLoginInBackground(email: email, password: password),
    );
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
    // Web: SecureSessionStore already mirrors into SharedPreferences.
    // Mobile: drop the legacy plaintext key after writing to secure storage.
    if (!kIsWeb) {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionStorageKey);
    }
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
