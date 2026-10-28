import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight device helpers (session UI cache + connectivity ping only).
/// Accounts, farm ledger, and live board are stored in Firebase — never locally.
class OfflineStore {
  OfflineStore._();

  static const String farmKey = 'egg_system.farm_v3';
  static const String liveDetectionsKey = 'egg_system.live_detections_v1';
  static const String userKey = 'egg_system.cached_user';
  static const String expiresKey = 'egg_system.session_expires';
  static const String pendingSyncKey = 'egg_system.farm_dirty';
  static const String loginFpKey = 'egg_system.login_fp';
  static const String localAccountsKey = 'egg_system.local_accounts_v1';
  static const String salesEmailsKey = 'egg_system.sales_emails_v1';
  static const String notificationReadKey = 'egg_system.notification_read_v1';

  static Future<SharedPreferences> get _prefs async =>
      SharedPreferences.getInstance();

  static Future<Map<String, dynamic>?> loadFarm() async {
    // Firebase is the only farm ledger — never hydrate from device storage.
    return null;
  }

  static Future<void> saveFarm(
    Map<String, dynamic> snapshot, {
    bool allowEmptyLiveBoard = false,
  }) async {
    // No-op: farm snapshot is saved via /farm/snapshot → Firestore.
  }

  static Future<void> clearFarmCache() async {
    final SharedPreferences prefs = await _prefs;
    await prefs.remove(farmKey);
    await prefs.remove(liveDetectionsKey);
    await prefs.remove(pendingSyncKey);
    await prefs.remove(localAccountsKey);
    await prefs.remove(salesEmailsKey);
    await prefs.remove(loginFpKey);
  }

  static Future<List<Map<String, dynamic>>> loadLiveDetections() async {
    return const <Map<String, dynamic>>[];
  }

  static Future<void> saveLiveDetections(
    List<Map<String, dynamic>> rows,
  ) async {
    // No-op: live board is saved in Firebase (farm_live/board).
  }

  static Future<void> clearLiveDetections() async {
    final SharedPreferences prefs = await _prefs;
    await prefs.remove(liveDetectionsKey);
  }

  static Future<void> clearLocalAccounts() async {
    final SharedPreferences prefs = await _prefs;
    await prefs.remove(localAccountsKey);
    await prefs.remove(salesEmailsKey);
    await prefs.remove(loginFpKey);
  }

  static Future<void> markSynced() async {
    final SharedPreferences prefs = await _prefs;
    await prefs.setBool(pendingSyncKey, false);
  }

  static Future<bool> isDirty() async {
    final SharedPreferences prefs = await _prefs;
    return prefs.getBool(pendingSyncKey) ?? false;
  }

  static Future<void> saveCachedUser({
    required Map<String, dynamic> user,
    required String expiresAt,
  }) async {
    final SharedPreferences prefs = await _prefs;
    await prefs.setString(userKey, jsonEncode(user));
    await prefs.setString(expiresKey, expiresAt);
  }

  static Future<({Map<String, dynamic> user, DateTime expiresAt})?>
      loadCachedUser() async {
    final SharedPreferences prefs = await _prefs;
    final String? raw = prefs.getString(userKey);
    final String? expiresRaw = prefs.getString(expiresKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Object? parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) {
        return null;
      }
      final DateTime expiresAt =
          DateTime.tryParse(expiresRaw ?? '')?.toUtc() ??
              DateTime.now().toUtc().add(const Duration(hours: 12));
      return (user: parsed, expiresAt: expiresAt);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCachedUser() async {
    final SharedPreferences prefs = await _prefs;
    await prefs.remove(userKey);
    await prefs.remove(expiresKey);
  }

  static String loginFingerprint(String email, String password) {
    final List<int> bytes = utf8.encode(
      '${email.trim().toLowerCase()}::$password',
    );
    int hash = 5381;
    for (final int b in bytes) {
      hash = ((hash << 5) + hash + b) & 0x7fffffff;
    }
    return hash.toString();
  }

  static Future<void> saveLoginFingerprint(String email, String password) async {
    final SharedPreferences prefs = await _prefs;
    await prefs.setString(loginFpKey, loginFingerprint(email, password));
  }

  static Future<String?> loadLoginFingerprint() async {
    final SharedPreferences prefs = await _prefs;
    return prefs.getString(loginFpKey);
  }

  static Future<Map<String, Map<String, dynamic>>> _loadLocalAccountsMap() async {
    final SharedPreferences prefs = await _prefs;
    final String? raw = prefs.getString(localAccountsKey);
    if (raw == null || raw.isEmpty) {
      return <String, Map<String, dynamic>>{};
    }
    try {
      final Object? parsed = jsonDecode(raw);
      if (parsed is! Map) {
        return <String, Map<String, dynamic>>{};
      }
      final Map<String, Map<String, dynamic>> out = <String, Map<String, dynamic>>{};
      parsed.forEach((Object? key, Object? value) {
        if (key is String && value is Map) {
          out[key] = Map<String, dynamic>.from(value);
        }
      });
      return out;
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  static Future<void> saveLocalAccount({
    required String email,
    required String password,
    required String role,
    required String name,
  }) async {
    // No-op: accounts live in Firebase Auth + farm_users only.
  }

  static Future<Map<String, dynamic>?> loadLocalAccount(String email) async {
    return null;
  }

  static Future<bool> verifyLocalAccount(String email, String password) async {
    return false;
  }

  static Future<void> rememberSalesEmail(String email) async {
    final SharedPreferences prefs = await _prefs;
    final Set<String> emails = prefs.getStringList(salesEmailsKey)?.toSet() ??
        <String>{};
    emails.add(email.trim().toLowerCase());
    await prefs.setStringList(salesEmailsKey, emails.toList());
  }

  static Future<bool> isSalesEmail(String email) async {
    final SharedPreferences prefs = await _prefs;
    final List<String> emails = prefs.getStringList(salesEmailsKey) ?? <String>[];
    return emails.contains(email.trim().toLowerCase());
  }

  static Future<int> localAccountCount() async {
    final Map<String, Map<String, dynamic>> accounts = await _loadLocalAccountsMap();
    return accounts.length;
  }

  static Future<bool> ping(String baseUrl) async {
    // Prefer public /health (Worker + tunnel). Fall back to /auth/health.
    for (final String path in <String>['/health', '/auth/health']) {
      try {
        final http.Response response = await http
            .get(Uri.parse('$baseUrl$path'))
            .timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          return true;
        }
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// Read notification keys (web + mobile SharedPreferences).
  static Future<Set<String>> loadNotificationReadKeys() async {
    final SharedPreferences prefs = await _prefs;
    final List<String> keys =
        prefs.getStringList(notificationReadKey) ?? <String>[];
    return keys.toSet();
  }

  static Future<void> saveNotificationReadKeys(Set<String> keys) async {
    final SharedPreferences prefs = await _prefs;
    final List<String> trimmed = keys.toList()
      ..sort()
      ..removeWhere((String k) => k.trim().isEmpty);
    // Cap growth so prefs stay small on web/mobile.
    final List<String> kept =
        trimmed.length > 200 ? trimmed.sublist(trimmed.length - 200) : trimmed;
    await prefs.setStringList(notificationReadKey, kept);
  }
}
