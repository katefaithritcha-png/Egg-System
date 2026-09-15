import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// On-device database for farm records. Works with no signal.
/// When the backend is reachable, the same snapshot is copied there.
class OfflineStore {
  OfflineStore._();

  static const String farmKey = 'egg_system.farm_v3';
  static const String userKey = 'egg_system.cached_user';
  static const String expiresKey = 'egg_system.session_expires';
  static const String pendingSyncKey = 'egg_system.farm_dirty';
  static const String loginFpKey = 'egg_system.login_fp';

  static Future<SharedPreferences> get _prefs async =>
      SharedPreferences.getInstance();

  static Future<Map<String, dynamic>?> loadFarm() async {
    try {
      final SharedPreferences prefs = await _prefs;
      final String? raw = prefs.getString(farmKey);
      if (raw == null || raw.isEmpty) {
        return null;
      }
      final Object? parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
      if (parsed is Map) {
        return Map<String, dynamic>.from(parsed);
      }
    } catch (_) {}
    return null;
  }

  static Future<void> saveFarm(Map<String, dynamic> snapshot) async {
    final SharedPreferences prefs = await _prefs;
    await prefs.setString(farmKey, jsonEncode(snapshot));
    await prefs.setBool(pendingSyncKey, true);
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

  static Future<bool> ping(String baseUrl) async {
    try {
      final http.Response response = await http
          .get(Uri.parse('$baseUrl/auth/health'))
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      try {
        final http.Response response = await http
            .get(Uri.parse('$baseUrl/metrics'))
          .timeout(const Duration(seconds: 2));
        return response.statusCode == 200;
      } catch (_) {
        return false;
      }
    }
  }
}
