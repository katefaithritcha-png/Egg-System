import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Session token storage: Keystore/Keychain on mobile; encrypted prefs on web.
/// Never put JWTs in plain SharedPreferences / localStorage.
class SecureSessionStore {
  SecureSessionStore._();

  static const String _key = 'egg_system.session_token';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Web: keep token in memory only for the tab lifetime (no localStorage).
  static String? _webMemoryToken;

  static Future<void> write(String token) async {
    if (kIsWeb) {
      _webMemoryToken = token;
      return;
    }
    await _storage.write(key: _key, value: token);
  }

  static Future<String?> read() async {
    if (kIsWeb) {
      return _webMemoryToken;
    }
    return _storage.read(key: _key);
  }

  static Future<void> clear() async {
    if (kIsWeb) {
      _webMemoryToken = null;
      return;
    }
    await _storage.delete(key: _key);
  }
}
