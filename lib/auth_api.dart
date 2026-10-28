import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthException implements Exception {
  AuthException(this.message, {this.code, this.verificationCode});

  final String message;
  final String? code;
  final String? verificationCode;

  bool get isUnauthorized =>
      code == 'unauthorized' || code == 'invalid_credentials';

  bool get isUnverified =>
      code == 'email_unverified' ||
      code == 'unverified' ||
      code == 'unverified_email';

  bool get isMfaRequired => code == 'mfa_required';

  @override
  String toString() => message;
}

class AuthSession {
  const AuthSession({
    required this.token,
    required this.expiresAt,
    this.idleTimeoutSeconds = 1800,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    final String? rawExpiry = json['expiresAt'] as String?;
    return AuthSession(
      token: json['token'] as String? ?? '',
      expiresAt: DateTime.tryParse(rawExpiry ?? '')?.toUtc() ??
          DateTime.now().toUtc().add(const Duration(hours: 12)),
      idleTimeoutSeconds: json['idleTimeoutSeconds'] as int? ?? 1800,
    );
  }

  final String token;
  final DateTime expiresAt;
  final int idleTimeoutSeconds;
}

class AuthLoginResult {
  const AuthLoginResult({required this.user, required this.session});

  final Map<String, dynamic> user;
  final AuthSession session;
}

class AuthMailResult {
  const AuthMailResult({
    required this.message,
    this.user,
    this.session,
    this.verificationCode,
    this.emailSent = false,
    this.mfaRequired = false,
  });

  final String message;
  final Map<String, dynamic>? user;
  final AuthSession? session;
  final String? verificationCode;
  final bool emailSent;
  final bool mfaRequired;

  bool get signedIn =>
      user != null && session != null && session!.token.isNotEmpty;
}

class AuthApi {
  AuthApi({required this.baseUrl});

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _jsonHeaders([String? token]) {
    return <String, String>{
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  AuthException _failure(http.Response response) {
    Map<String, dynamic> body = <String, dynamic>{};
    try {
      final Object? parsed = jsonDecode(response.body);
      if (parsed is Map) {
        body = Map<String, dynamic>.from(parsed);
      }
    } catch (_) {}
    return AuthException(
      body['error'] as String? ?? 'Request failed (${response.statusCode})',
      code: body['code'] as String?,
      verificationCode: body['verificationCode'] as String? ??
          body['token'] as String?,
    );
  }

  Map<String, dynamic> _object(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failure(response);
    }
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    final Object? parsed = jsonDecode(response.body);
    if (parsed is Map) {
      return Map<String, dynamic>.from(parsed);
    }
    return <String, dynamic>{};
  }

  AuthLoginResult _loginResult(Map<String, dynamic> body) {
    final Object? user = body['user'];
    final Object? session = body['session'];
    if (user is! Map || session is! Map) {
      throw AuthException(
        body['error'] as String? ?? 'Sign-in did not return a session.',
        code: body['code'] as String?,
      );
    }
    return AuthLoginResult(
      user: Map<String, dynamic>.from(user),
      session: AuthSession.fromJson(Map<String, dynamic>.from(session)),
    );
  }

  AuthMailResult _mailResult(Map<String, dynamic> body) {
    final Object? user = body['user'];
    final Object? session = body['session'];
    return AuthMailResult(
      message: body['message'] as String? ?? 'Check your email.',
      user: user is Map ? Map<String, dynamic>.from(user) : null,
      session: session is Map
          ? AuthSession.fromJson(Map<String, dynamic>.from(session))
          : null,
      verificationCode: body['verificationCode'] as String? ??
          body['token'] as String?,
      emailSent: body['emailSent'] == true,
      mfaRequired: body['mfaRequired'] == true || body['code'] == 'mfa_required',
    );
  }

  Future<AuthLoginResult> login({
    required String email,
    required String password,
  }) async {
    final http.Response response = await http
        .post(
          _uri('/auth/login'),
          headers: _jsonHeaders(),
          body: jsonEncode(
            <String, String>{'email': email, 'password': password},
          ),
        )
        .timeout(const Duration(seconds: 15));
    return _loginResult(_object(response));
  }

  Future<AuthLoginResult> me(
    String token, {
    Duration? timeout,
  }) async {
    final Future<http.Response> request = http.get(
      _uri('/auth/me'),
      headers: _jsonHeaders(token),
    );
    final http.Response response = timeout == null
        ? await request
        : await request.timeout(timeout);
    return _loginResult(_object(response));
  }

  Future<AuthMailResult> signup({
    required String name,
    required String email,
    required String password,
    String role = 'worker',
  }) async {
    final http.Response response = await http.post(
      _uri('/auth/signup'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, String>{
        'name': name,
        'email': email,
        'password': password,
        'role': role,
      }),
    );
    return _mailResult(_object(response));
  }

  Future<String> verifyEmail(String token) async {
    final http.Response response = await http.post(
      _uri('/auth/verify-email'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, String>{'token': token}),
    );
    final Map<String, dynamic> body = _object(response);
    return body['message'] as String? ?? 'Email verified.';
  }

  Future<AuthLoginResult> confirmFirebaseEmail({
    required String email,
    required String password,
  }) async {
    final http.Response response = await http.post(
      _uri('/auth/confirm-firebase-email'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, String>{
        'email': email,
        'password': password,
      }),
    );
    return _loginResult(_object(response));
  }

  Future<AuthLoginResult> verifyLogin(String code) async {
    final http.Response response = await http.post(
      _uri('/auth/verify-login'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, String>{'token': code, 'code': code}),
    );
    return _loginResult(_object(response));
  }

  Future<AuthLoginResult> firebaseLogin({
    required String idToken,
    required String role,
    required bool setRole,
  }) async {
    final http.Response response = await http.post(
      _uri('/auth/firebase-login'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, Object>{
        'idToken': idToken,
        'role': role,
        'setRole': setRole,
      }),
    );
    return _loginResult(_object(response));
  }

  Future<AuthMailResult> resendVerification(
    String email, {
    String? password,
  }) async {
    final http.Response response = await http.post(
      _uri('/auth/resend-verification'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, String>{
        'email': email,
        if (password != null) 'password': password,
      }),
    );
    return _mailResult(_object(response));
  }

  Future<String> forgotPassword(String email) async {
    final http.Response response = await http.post(
      _uri('/auth/forgot-password'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, String>{'email': email}),
    );
    final Map<String, dynamic> body = _object(response);
    return body['message'] as String? ?? 'Reset email sent.';
  }

  Future<String> resetPassword({
    required String token,
    required String password,
  }) async {
    final http.Response response = await http.post(
      _uri('/auth/reset-password'),
      headers: _jsonHeaders(),
      body: jsonEncode(<String, String>{
        'token': token,
        'password': password,
      }),
    );
    final Map<String, dynamic> body = _object(response);
    return body['message'] as String? ?? 'Password updated.';
  }

  Future<List<Map<String, dynamic>>> listUsers(String token) async {
    final http.Response response = await http.get(
      _uri('/auth/users'),
      headers: _jsonHeaders(token),
    );
    final Map<String, dynamic> body = _object(response);
    final Object? raw = body['users'];
    if (raw is! List) {
      return <Map<String, dynamic>>[];
    }
    return raw
        .whereType<Map>()
        .map((Map row) => Map<String, dynamic>.from(row))
        .toList();
  }

  /// Admin creates a worker/seller in Firebase and gets back the auth code.
  Future<AuthMailResult> adminCreateUser({
    required String token,
    required String name,
    required String email,
    required String password,
    required String role,
  }) async {
    final http.Response response = await http.post(
      _uri('/auth/admin/create-user'),
      headers: _jsonHeaders(token),
      body: jsonEncode(<String, String>{
        'name': name,
        'email': email,
        'password': password,
        'role': role,
      }),
    );
    return _mailResult(_object(response));
  }

  Future<Map<String, dynamic>> adminUpdateUser({
    required String token,
    required String email,
    String? role,
    bool? disabled,
  }) async {
    final Map<String, Object> body = <String, Object>{
      'email': email,
      if (role != null) 'role': role,
      if (disabled != null) 'disabled': disabled,
    };
    final http.Response response = await http.post(
      _uri('/auth/admin/update-user'),
      headers: _jsonHeaders(token),
      body: jsonEncode(body),
    );
    return _object(response);
  }

  Future<Map<String, dynamic>> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    final http.Response response = await http.post(
      _uri('/auth/change-password'),
      headers: _jsonHeaders(token),
      body: jsonEncode(<String, String>{
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      }),
    );
    final Map<String, dynamic> body = _object(response);
    final Object? user = body['user'];
    if (user is Map) {
      return Map<String, dynamic>.from(user);
    }
    return body;
  }

  Future<void> logout(String? token) async {
    if (token == null || token.isEmpty) {
      return;
    }
    try {
      await http.post(_uri('/auth/logout'), headers: _jsonHeaders(token));
    } catch (_) {}
  }

  Future<void> saveFarmSnapshot({
    required String token,
    required Map<String, dynamic> snapshot,
  }) async {
    final http.Response response = await http.put(
      _uri('/farm/snapshot'),
      headers: _jsonHeaders(token),
      body: jsonEncode(snapshot),
    );
    _object(response);
  }

  Future<Map<String, dynamic>?> loadFarmSnapshot(String token) async {
    final http.Response response = await http
        .get(
          _uri('/farm/snapshot'),
          headers: _jsonHeaders(token),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode == 404) {
      return null;
    }
    final Map<String, dynamic> body = _object(response);
    final Object? snapshot = body['snapshot'] ?? body['farm'];
    if (snapshot is Map) {
      return Map<String, dynamic>.from(snapshot);
    }
    return body;
  }
}
