import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthException implements Exception {
  AuthException(
    this.message, {
    this.code,
    this.statusCode,
    this.verificationCode,
  });

  final String message;
  final String? code;
  final int? statusCode;
  final String? verificationCode;

  bool get isUnverified => code == 'unverified_email';
  bool get isRateLimited => code == 'rate_limited';
  bool get isUnauthorized =>
      code == 'unauthorized' || statusCode == 401;

  @override
  String toString() => message;
}

class AuthSession {
  const AuthSession({
    required this.token,
    required this.expiresAt,
    required this.idleTimeoutSeconds,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      token: json['token'] as String? ?? '',
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc().add(const Duration(hours: 8)),
      idleTimeoutSeconds: json['idleTimeoutSeconds'] as int? ?? 1800,
    );
  }

  final String token;
  final DateTime expiresAt;
  final int idleTimeoutSeconds;
}

class AuthMailResult {
  const AuthMailResult({
    required this.message,
    this.verificationCode,
    this.user,
    this.session,
  });

  final String message;
  final String? verificationCode;
  final Map<String, dynamic>? user;
  final AuthSession? session;

  bool get signedIn =>
      session != null &&
      session!.token.isNotEmpty &&
      user != null &&
      user!.isNotEmpty;
}

class AuthApi {
  AuthApi({required this.baseUrl, http.Client? client})
    : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 45);

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _headers({String? token}) {
    return <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> _decode(
    http.Response response, {
    required String fallback,
  }) async {
    Map<String, dynamic> body = <String, dynamic>{};
    if (response.body.isNotEmpty) {
      try {
        final Object? parsed = jsonDecode(response.body);
        if (parsed is Map) {
          body = Map<String, dynamic>.from(parsed);
        }
      } on FormatException {
        throw AuthException(fallback, statusCode: response.statusCode);
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthException(
        body['error'] as String? ?? body['message'] as String? ?? fallback,
        code: body['code'] as String?,
        statusCode: response.statusCode,
        verificationCode: body['verificationCode'] as String?,
      );
    }
    return body;
  }

  Future<http.Response> _post(
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) {
    return _client
        .post(
          _uri(path),
          headers: _headers(token: token),
          body: jsonEncode(body ?? <String, dynamic>{}),
        )
        .timeout(_timeout);
  }

  Future<({Map<String, dynamic> user, AuthSession session})> login({
    required String email,
    required String password,
  }) async {
    final http.Response response = await _post(
      '/auth/login',
      body: <String, dynamic>{'email': email, 'password': password},
    );
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to sign in',
    );
    final Map<String, dynamic> sessionJson =
        json['session'] as Map<String, dynamic>? ?? <String, dynamic>{};
    if ((sessionJson['token'] as String? ?? '').isEmpty) {
      throw AuthException('Server did not issue a session');
    }
    return (
      user: json['user'] as Map<String, dynamic>? ?? <String, dynamic>{},
      session: AuthSession.fromJson(sessionJson),
    );
  }

  Future<AuthMailResult> signup({
    required String name,
    required String email,
    required String password,
    String role = 'worker',
  }) async {
    final http.Response response = await _post(
      '/auth/signup',
      body: <String, dynamic>{
        'name': name,
        'email': email,
        'password': password,
        'role': role,
      },
    );
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to create account',
    );
    return AuthMailResult(
      message: json['message'] as String? ??
          'Account created. Verify your email before signing in.',
      verificationCode: json['verificationCode'] as String?,
    );
  }

  Future<({Map<String, dynamic> user, AuthSession session})> me(
    String token, {
    Duration timeout = _timeout,
  }) async {
    final http.Response response = await _client
        .get(_uri('/auth/me'), headers: _headers(token: token))
        .timeout(timeout);
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Session expired',
    );
    final Map<String, dynamic> sessionJson =
        json['session'] as Map<String, dynamic>? ?? <String, dynamic>{};
    return (
      user: json['user'] as Map<String, dynamic>? ?? <String, dynamic>{},
      session: AuthSession(
        token: token,
        expiresAt:
            DateTime.tryParse(sessionJson['expiresAt'] as String? ?? '')
                ?.toUtc() ??
            DateTime.now().toUtc(),
        idleTimeoutSeconds: sessionJson['idleTimeoutSeconds'] as int? ?? 1800,
      ),
    );
  }

  Future<void> logout(String? token) async {
    if (token == null || token.isEmpty) {
      return;
    }
    try {
      await _post('/auth/logout', token: token);
    } catch (_) {
      // Local sign-out still proceeds if the server is unreachable.
    }
  }

  Future<String> verifyEmail(String token) async {
    final http.Response response = await _post(
      '/auth/verify-email',
      body: <String, dynamic>{'token': token},
    );
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to verify email',
    );
    return json['message'] as String? ?? 'Email verified. You can now sign in.';
  }

  Future<AuthMailResult> resendVerification(
    String email, {
    String? password,
  }) async {
    final http.Response response = await _post(
      '/auth/resend-verification',
      body: <String, dynamic>{
        'email': email,
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to resend verification',
    );
    return AuthMailResult(
      message: json['message'] as String? ??
          'A 6-digit verification code was issued. Type it in the app.',
      verificationCode: json['verificationCode'] as String?,
    );
  }

  Future<String> forgotPassword(String email) async {
    final http.Response response = await _post(
      '/auth/forgot-password',
      body: <String, dynamic>{'email': email},
    );
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to start password reset',
    );
    return json['message'] as String? ??
        'If that email is registered, a password reset link has been sent.';
  }

  Future<String> resetPassword({
    required String token,
    required String password,
  }) async {
    final http.Response response = await _post(
      '/auth/reset-password',
      body: <String, dynamic>{'token': token, 'password': password},
    );
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to reset password',
    );
    return json['message'] as String? ??
        'Password updated. Sign in with your new password.';
  }

  Future<Map<String, dynamic>> changePassword({
    required String token,
    required String currentPassword,
    required String newPassword,
  }) async {
    final http.Response response = await _post(
      '/auth/change-password',
      body: <String, dynamic>{
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      },
      token: token,
    );
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to update password',
    );
    return json['user'] as Map<String, dynamic>? ?? <String, dynamic>{};
  }

  Future<void> saveFarmSnapshot({
    required String token,
    required Map<String, dynamic> snapshot,
  }) async {
    final http.Response response = await _post(
      '/farm/snapshot',
      body: <String, dynamic>{'snapshot': snapshot},
      token: token,
    );
    await _decode(response, fallback: 'Unable to save farm data');
  }

  Future<Map<String, dynamic>?> loadFarmSnapshot(String token) async {
    final http.Response response = await _client
        .get(_uri('/farm/snapshot'), headers: _headers(token: token))
        .timeout(_timeout);
    final Map<String, dynamic> json = await _decode(
      response,
      fallback: 'Unable to load farm data',
    );
    final Object? snapshot = json['snapshot'];
    if (snapshot is Map<String, dynamic>) {
      return snapshot;
    }
    return null;
  }
}
