import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Session token storage: Keystore/Keychain on mobile; SharedPreferences on web
/// so a browser refresh keeps you signed in.
class SecureSessionStore {
  SecureSessionStore._();

  static const String _key = 'egg_system.session_token';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// In-memory mirror for the current tab (fast path).
  static String? _webMemoryToken;

  static Future<void> write(String token) async {
    if (kIsWeb) {
      _webMemoryToken = token;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, token);
      return;
    }
    await _storage.write(key: _key, value: token);
  }

  static Future<String?> read() async {
    if (kIsWeb) {
      if (_webMemoryToken != null && _webMemoryToken!.isNotEmpty) {
        return _webMemoryToken;
      }
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? stored = prefs.getString(_key);
      if (stored != null && stored.isNotEmpty) {
        _webMemoryToken = stored;
      }
      return stored;
    }
    return _storage.read(key: _key);
  }

  static Future<void> clear() async {
    if (kIsWeb) {
      _webMemoryToken = null;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      return;
    }
    await _storage.delete(key: _key);
  }
}
