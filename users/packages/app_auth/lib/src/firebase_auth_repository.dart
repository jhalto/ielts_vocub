import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import 'auth_repository.dart';

class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({FirebaseAuth? auth, http.Client? client})
    : _auth = auth ?? FirebaseAuth.instance,
      _client = client ?? http.Client();
  final FirebaseAuth _auth;
  final http.Client _client;
  Future<void>? _googleInitialization;
  Identity? _identity(User? user) => user == null
      ? null
      : Identity(
          uid: user.uid,
          email: user.email ?? '',
          name: user.displayName ?? '',
          verified: user.emailVerified,
          providers: List.unmodifiable(
            user.providerData.map((p) => p.providerId),
          ),
          createdAt: user.metadata.creationTime,
        );
  @override
  Stream<Identity?> get identities => _auth.userChanges().map(_identity);
  @override
  bool get supportsGoogle =>
      kIsWeb ||
      [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ].contains(defaultTargetPlatform);
  Future<T> _firebase<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on FirebaseAuthException catch (e) {
      throw AuthProblem(e.code, _authMessage(e.code));
    } on GoogleSignInException catch (e) {
      throw AuthProblem(
        e.code.name,
        e.code == GoogleSignInExceptionCode.canceled
            ? 'Google sign-in cancelled.'
            : 'Google sign-in failed. Check your platform configuration and try again.',
      );
    }
  }

  @override
  Future<void> login(String email, String password) => _firebase(() async {
    await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  });
  @override
  Future<void> register(String name, String email, String password) =>
      _firebase(() async {
        if (validateName(name) != null ||
            validateEmail(email) != null ||
            password.isEmpty) {
          throw const AuthProblem(
            'invalid-input',
            'Check your name, email and password.',
          );
        }
        // Firebase enforces the configured password policy. No passwords are persisted.
        final credential = await _auth.createUserWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        await credential.user!.updateDisplayName(name.trim());
        // Profile initialization runs on session changes; its UI offers explicit retry.
        await credential.user!.sendEmailVerification();
      });
  @override
  Future<void> google() => _firebase(() async {
    if (!supportsGoogle) {
      throw const AuthProblem(
        'unsupported-platform',
        'Google sign-in is unavailable on Windows. Use email and password.',
      );
    }
    if (kIsWeb) {
      await _auth.signInWithPopup(
        GoogleAuthProvider()..setCustomParameters({'prompt': 'select_account'}),
      );
    } else {
      await (_googleInitialization ??= GoogleSignIn.instance.initialize());
      final account = await GoogleSignIn.instance.authenticate();
      final token = account.authentication.idToken;
      if (token == null) {
        throw const AuthProblem(
          'missing-token',
          'Google did not return an identity token.',
        );
      }
      await _auth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: token),
      );
    }
    // No email-based linking or account merge is performed by the application.
  });
  @override
  Future<void> resetPassword(String email) => _firebase(() async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      if (e.code != 'user-not-found') rethrow;
    }
  });
  @override
  Future<void> sendVerification() => _firebase(() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthProblem('unauthenticated', 'Sign in first.');
    }
    await user.sendEmailVerification();
  });
  @override
  Future<void> reload() => _firebase(() async {
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      await user.reload();
      await _auth.currentUser?.getIdToken(true);
    } on FirebaseAuthException catch (e) {
      if ([
        'user-disabled',
        'user-token-expired',
        'invalid-user-token',
        'user-not-found',
      ].contains(e.code)) {
        await _auth.signOut();
      }
      rethrow;
    }
  });
  @override
  Future<void> logout() => _firebase(() async {
    await _auth.signOut();
    if (!kIsWeb && supportsGoogle && _googleInitialization != null) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        /* Firebase session is already cleared. */
      }
    }
  });
  @override
  Future<Map<String, dynamic>> initializeProfile({String? name}) =>
      _request('initializeProfile', name: name);
  @override
  Future<String> checkAdmin() async {
    final result = await _request('adminAccess');
    return result['role'] as String;
  }

  Future<Map<String, dynamic>> _request(String action, {String? name}) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AuthProblem('unauthenticated', 'Sign in first.');
    }
    const emulator = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
    const host = String.fromEnvironment(
      'FIREBASE_EMULATOR_HOST',
      defaultValue: 'localhost',
    );
    const functionsPort = int.fromEnvironment(
      'FUNCTIONS_EMULATOR_PORT',
      defaultValue: 5001,
    );
    const region = String.fromEnvironment(
      'FIREBASE_FUNCTIONS_REGION',
      defaultValue: 'us-central1',
    );
    final project = Firebase.app().options.projectId;
    final uri = Uri.parse(
      emulator
          ? 'http://$host:$functionsPort/$project/$region/accountApi'
          : 'https://$region-$project.cloudfunctions.net/accountApi',
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _firebase(() => user.getIdToken(attempt > 0));
      if (_auth.currentUser?.uid != user.uid) {
        throw const AuthProblem(
          'account-changed',
          'Account changed. Try again.',
        );
      }
      final response = await _client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'action': action, 'name': ?name}),
          )
          .timeout(const Duration(seconds: 15));
      if (_auth.currentUser?.uid != user.uid) {
        throw const AuthProblem(
          'account-changed',
          'Account changed. Try again.',
        );
      }
      if (response.statusCode == 401 && attempt == 0) continue;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        Map<String, dynamic>? data;
        try {
          data = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          /* Safe generic error below. */
        }
        final code = data?['code'] as String? ?? 'service-unavailable';
        if (['session-revoked', 'user-disabled'].contains(code)) {
          await _auth.signOut();
        }
        throw AuthProblem(code, switch (code) {
          'permission-denied' =>
            'This account does not have administrator access.',
          'email-unverified' => 'Verify your email, then refresh your session.',
          'claims-stale' =>
            'Your role changed. Refresh your session and try again.',
          'rate-limited' => 'Too many requests. Wait a minute and try again.',
          'session-revoked' || 'user-disabled' =>
            'Your session is no longer authorized. Sign in again.',
          _ => 'Account service unavailable. Check your connection and retry.',
        });
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw const AuthProblem('unauthenticated', 'Sign in again.');
  }

  String _authMessage(String code) => switch (code) {
    'invalid-credential' ||
    'wrong-password' ||
    'user-not-found' => 'Email or password is incorrect.',
    'email-already-in-use' =>
      'An account already exists. Sign in or reset your password.',
    'weak-password' || 'password-does-not-meet-requirements' =>
      'Password does not meet this project\'s password policy.',
    'invalid-email' => 'Enter a valid email address.',
    'user-disabled' => 'This account is disabled.',
    'too-many-requests' => 'Too many attempts. Wait and try again.',
    'network-request-failed' =>
      'Internet is required for this action. Check your connection.',
    'account-exists-with-different-credential' || 'credential-already-in-use' => 'Use your existing sign-in method. Accounts are not automatically linked.',
    'popup-closed-by-user' ||
    'cancelled-popup-request' => 'Google sign-in cancelled.',
    'operation-not-allowed' =>
      'This sign-in provider must be enabled in Firebase.',
    'requires-recent-login' => 'Sign in again before continuing.',
    _ => 'Authentication failed. Please try again.',
  };
}
