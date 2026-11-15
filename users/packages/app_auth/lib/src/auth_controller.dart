import 'dart:async';

import 'package:flutter/foundation.dart';

import 'auth_repository.dart';

/// UID generations prevent late requests from exposing a previous account's data.
class AuthController extends ChangeNotifier {
  AuthController(this.repository, {this.adminOnly = false, this.clearPrivate}) {
    _subscription = repository.identities.listen(
      _identityChanged,
      onError: (Object _) {
        starting = false;
        error = 'Session restoration failed. Try again.';
        notifyListeners();
      },
    );
  }
  final AuthRepository repository;
  final bool adminOnly;
  final Future<void> Function(String uid)? clearPrivate;
  late final StreamSubscription<Identity?> _subscription;
  Identity? identity;
  Map<String, dynamic>? profile;
  bool starting = true;
  bool busy = false;
  bool guest = false;
  bool profilePending = false;
  bool adminAllowed = false;
  String? role;
  String? error;
  String? notice;
  int _generation = 0;
  bool _disposed = false;
  DateTime? verificationSentAt;
  final Map<String, DateTime> _verificationByEmail = {};
  Timer? _adminTimer;
  bool get canEnter =>
      !adminOnly ? identity != null || guest : identity != null && adminAllowed;
  bool get canResend =>
      verificationSentAt == null ||
      DateTime.now().difference(verificationSentAt!).inSeconds >= 60;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void _identityChanged(Identity? value) {
    final previousUid = identity?.uid;
    final uidChanged = previousUid != value?.uid;
    if (uidChanged && previousUid != null && clearPrivate != null) {
      unawaited(clearPrivate!(previousUid).catchError((Object _) {}));
    }
    _generation++;
    identity = value;
    starting = false;
    profile = null;
    profilePending = value != null;
    adminAllowed = false;
    role = null;
    if (uidChanged) {
      error = null;
      notice = null;
      verificationSentAt = value == null
          ? null
          : _verificationByEmail[value.email.toLowerCase()];
    }
    _adminTimer?.cancel();
    if (value != null) {
      guest = false;
      unawaited(refreshProfile());
      if (adminOnly) {
        _adminTimer = Timer.periodic(
          const Duration(seconds: 60),
          (_) => unawaited(refreshProfile()),
        );
      }
    }
    _emit();
  }

  Future<void> refreshProfile({String? name}) async {
    if (identity == null) return;
    final generation = _generation;
    final uid = identity!.uid;
    // An admin must receive a new online authorization result after each refresh.
    if (adminOnly) {
      adminAllowed = false;
      _emit();
    }
    var initialized = false;
    try {
      final result = await repository.initializeProfile(name: name);
      initialized = true;
      if (_disposed || generation != _generation || identity?.uid != uid) {
        return;
      }
      profile = result;
      profilePending = false;
      final nextRole = adminOnly ? await repository.checkAdmin() : null;
      if (_disposed || generation != _generation || identity?.uid != uid) {
        return;
      }
      profile = result;
      profilePending = false;
      role = nextRole;
      adminAllowed = adminOnly && nextRole != null;
      error = null;
    } catch (e) {
      if (_disposed || generation != _generation) return;
      profilePending = !initialized;
      adminAllowed = false;
      error = _message(e);
      if (e is AuthProblem &&
          ['session-revoked', 'user-disabled'].contains(e.code)) {
        await repository.logout();
      }
    }
    _emit();
  }

  Future<void> run(Future<void> Function() action, {String? success}) async {
    if (busy) return;
    busy = true;
    error = null;
    notice = null;
    _emit();
    final generation = _generation;
    final startingUid = identity?.uid;
    try {
      await action();
      if (!_disposed && generation == _generation) {
        notice = success;
      }
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = _message(e);
      } else if (!_disposed && startingUid == null && identity != null) {
        error = 'Signed in, but account setup did not finish. Check your name and verification, then retry profile setup.';
      }
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<void> register(String name, String email, String password) =>
      run(() async {
        await repository.register(name, email, password);
        verificationSentAt = DateTime.now();
        _verificationByEmail[email.trim().toLowerCase()] = verificationSentAt!;
        notice = 'Account created. Check your inbox to verify your email.';
      });

  Future<void> sendVerification() async {
    if (!canResend) return;
    await run(() async {
      await repository.sendVerification();
      verificationSentAt = DateTime.now();
    }, success: 'Verification email sent. Check your inbox.');
  }

  Future<void> refreshSession() => run(() async {
    await repository.reload();
    await refreshProfile();
  });
  void enterGuest() {
    if (adminOnly || busy) return;
    guest = true;
    error = null;
    _emit();
  }

  void leaveGuest() {
    guest = false;
    _emit();
  }

  Future<void> signOut() async {
    if (busy) return;
    final previousUid = identity?.uid;
    _verificationByEmail.clear();
    verificationSentAt = null;
    _generation++;
    identity = null;
    profile = null;
    role = null;
    adminAllowed = false;
    guest = false;
    await run(() async {
      try {
        if (previousUid != null) await clearPrivate?.call(previousUid);
      } finally {
        await repository.logout();
      }
    });
  }

  String _message(Object error) => error is AuthProblem
      ? error.message
      : 'Unable to complete the request. Check your connection and try again.';
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _subscription.cancel();
    _adminTimer?.cancel();
    super.dispose();
  }
}
