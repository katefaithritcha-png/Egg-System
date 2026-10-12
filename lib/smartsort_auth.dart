import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'auth_api.dart';

/// Firebase Authentication for SMARTSORT.
///
/// Passwords stay inside Firebase Auth. This file never writes a password,
/// password hash, or ID token to Firestore.
class SmartsortAuth {
  SmartsortAuth._();

  static const String fixedAdminEmail = 'katefaithr@gmail.com';
  static const String genericLoginError = 'Wrong email or password.';
  static const String resetNotice =
      'If that email is registered, a password reset link has been sent.';
  static const String verifyNotice =
      'Verify your email before signing in. A verification message has been sent.';

  static const Set<String> secretFields = <String>{
    'password',
    'passwordHash',
    'password_hash',
    'token',
    'idToken',
    'appPassword',
  };

  static Map<String, dynamic> workerProfileFields({
    required String email,
    required String name,
  }) {
    return <String, dynamic>{
      'email': email.trim().toLowerCase(),
      'name': name.trim(),
      'role': 'worker',
      'assignedZone': 'Unassigned',
    };
  }

  /// A user may keep their own role. Only an admin may change someone else.
  static bool roleChangeAllowed({
    required String actorRole,
    required String actorUid,
    required String targetUid,
    required String currentRole,
    required String nextRole,
  }) {
    if (nextRole != 'admin' && nextRole != 'worker') {
      return false;
    }
    if (actorUid == targetUid) {
      return nextRole == currentRole;
    }
    return actorRole == 'admin';
  }

  static String roleForAccount({
    required String email,
    required String? storedRole,
  }) {
    if (email.trim().toLowerCase() == fixedAdminEmail) {
      return 'admin';
    }
    return storedRole == 'admin' ? 'admin' : 'worker';
  }

  static bool profileHasSecret(Map<String, dynamic> data) {
    for (final String key in data.keys) {
      if (secretFields.contains(key)) {
        return true;
      }
    }
    return false;
  }

  static Future<SmartsortProfile> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final UserCredential credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final User? user = credential.user;
      if (user == null) {
        throw AuthException(genericLoginError, code: 'invalid_credentials');
      }
      await user.reload();
      final User current = FirebaseAuth.instance.currentUser ?? user;
      if (!current.emailVerified) {
        await current.sendEmailVerification();
        await FirebaseAuth.instance.signOut();
        throw AuthException(verifyNotice, code: 'unverified_email');
      }
      final SmartsortProfile profile = await _loadOrCreateProfile(current);
      await _audit('login', success: true);
      return profile;
    } on AuthException {
      rethrow;
    } on FirebaseAuthException {
      await _audit('login_failed', success: false);
      throw AuthException(genericLoginError, code: 'invalid_credentials');
    } catch (_) {
      throw AuthException(genericLoginError, code: 'invalid_credentials');
    }
  }

  static Future<String> signUp({
    required String name,
    required String email,
    required String password,
  }) async {
    if (email.trim().toLowerCase() == fixedAdminEmail) {
      throw AuthException(
        'The admin account is exclusive and cannot be created here.',
        code: 'admin_fixed',
      );
    }
    try {
      final UserCredential credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final User? user = credential.user;
      if (user == null) {
        throw AuthException(
          'Unable to create account.',
          code: 'signup_failed',
        );
      }
      final String trimmedName = name.trim();
      if (trimmedName.isNotEmpty) {
        await user.updateDisplayName(trimmedName);
      }
      await user.sendEmailVerification();
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        <String, dynamic>{
          ...workerProfileFields(
            email: user.email ?? email,
            name: trimmedName.isEmpty ? 'Worker' : trimmedName,
          ),
          'createdAt': FieldValue.serverTimestamp(),
        },
      );
      await _audit('signup', success: true);
      await FirebaseAuth.instance.signOut();
      return verifyNotice;
    } on FirebaseAuthException catch (error) {
      if (error.code == 'email-already-in-use') {
        throw AuthException(
          'Unable to create account with that email.',
          code: 'email_taken',
        );
      }
      if (error.code == 'weak-password') {
        throw AuthException(
          'Choose a stronger password.',
          code: 'weak_password',
        );
      }
      throw AuthException('Unable to create account.', code: 'signup_failed');
    }
  }

  static Future<String> sendPasswordReset(String email) async {
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException {
      // Same response whether or not the address exists.
    } catch (_) {}
    return resetNotice;
  }

  static Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final User? user = FirebaseAuth.instance.currentUser;
    final String? email = user?.email;
    if (user == null || email == null || email.isEmpty) {
      throw AuthException('Session expired or invalid', code: 'unauthorized');
    }
    try {
      final AuthCredential credential = EmailAuthProvider.credential(
        email: email,
        password: currentPassword,
      );
      await user.reauthenticateWithCredential(credential);
      await user.updatePassword(newPassword);
      await _audit('password_changed', success: true);
    } on FirebaseAuthException {
      throw AuthException(
        'Current password is incorrect.',
        code: 'invalid_credentials',
      );
    }
  }

  static Future<SmartsortProfile?> restoreProfile() async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return null;
    }
    await user.reload();
    final User? fresh = FirebaseAuth.instance.currentUser;
    if (fresh == null || !fresh.emailVerified) {
      return null;
    }
    return _loadOrCreateProfile(fresh);
  }

  static Future<void> signOut() async {
    final bool hadUser = FirebaseAuth.instance.currentUser != null;
    if (hadUser) {
      await _audit('logout', success: true);
    }
    await FirebaseAuth.instance.signOut();
  }

  static Future<SmartsortProfile> _loadOrCreateProfile(User user) async {
    final DocumentReference<Map<String, dynamic>> ref =
        FirebaseFirestore.instance.collection('users').doc(user.uid);
    final DocumentSnapshot<Map<String, dynamic>> snap = await ref.get();
    Map<String, dynamic> data = snap.data() ?? <String, dynamic>{};
    if (!snap.exists) {
      data = workerProfileFields(
        email: user.email ?? '',
        name: user.displayName ?? 'Worker',
      );
      await ref.set(<String, dynamic>{
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    if (profileHasSecret(data)) {
      throw AuthException(
        'Account profile is invalid.',
        code: 'invalid_profile',
      );
    }
    final String email = (data['email'] as String? ?? user.email ?? '').trim();
    return SmartsortProfile(
      uid: user.uid,
      name: data['name'] as String? ?? user.displayName ?? 'Kate Faith',
      email: email,
      role: roleForAccount(
        email: user.email ?? email,
        storedRole: data['role'] as String?,
      ),
      assignedZone: data['assignedZone'] as String? ?? 'Unassigned',
    );
  }

  static Future<void> _audit(String action, {required bool success}) async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return;
    }
    try {
      await FirebaseFirestore.instance.collection('audit_logs').add(
        <String, dynamic>{
          'uid': uid,
          'action': action,
          'success': success,
          'createdAt': FieldValue.serverTimestamp(),
        },
      );
    } catch (_) {
      // Audit failure must not block sign-in or sign-out.
    }
  }
}

class SmartsortProfile {
  const SmartsortProfile({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    required this.assignedZone,
  });

  final String uid;
  final String name;
  final String email;
  final String role;
  final String assignedZone;
}
