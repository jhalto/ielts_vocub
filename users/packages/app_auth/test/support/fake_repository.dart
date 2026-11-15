import 'dart:async';

import 'package:app_auth/app_auth.dart';

const alice = Identity(
  uid: 'alice',
  email: 'alice@example.test',
  name: 'Alice',
  verified: false,
  providers: ['password'],
);
const bob = Identity(
  uid: 'bob',
  email: 'bob@example.test',
  name: 'Bob',
  verified: true,
  providers: ['google.com'],
);

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({Identity? initial}) : current = initial;
  Identity? current;
  final changes = StreamController<Identity?>.broadcast();
  int verificationCalls = 0;
  int loginCalls = 0;
  bool failProfile = false;
  bool allowAdmin = false;
  Completer<Map<String, dynamic>>? profileResult;
  @override
  bool get supportsGoogle => false;
  @override
  Stream<Identity?> get identities => Stream.multi((sink) {
    sink.add(current);
    final subscription = changes.stream.listen(
      sink.add,
      onError: sink.addError,
    );
    sink.onCancel = subscription.cancel;
  });
  void emit(Identity? identity) {
    current = identity;
    changes.add(identity);
  }

  @override
  Future<void> login(String email, String password) async {
    loginCalls++;
    emit(alice);
  }

  @override
  Future<void> register(String name, String email, String password) async {
    emit(alice);
  }

  @override
  Future<void> google() async {
    emit(bob);
  }

  @override
  Future<void> resetPassword(String email) async {}
  @override
  Future<void> sendVerification() async {
    verificationCalls++;
  }

  @override
  Future<void> reload() async {}
  @override
  Future<void> logout() async {
    emit(null);
  }

  @override
  Future<Map<String, dynamic>> initializeProfile({String? name}) async {
    if (profileResult != null) return profileResult!.future;
    if (failProfile) throw const AuthProblem('network', 'Network unavailable.');
    return {'uid': current!.uid, 'name': name ?? current!.name};
  }

  @override
  Future<String> checkAdmin() async {
    if (!allowAdmin) {
      throw const AuthProblem(
        'permission-denied',
        'Administrator access denied.',
      );
    }
    return 'super_admin';
  }

  Future<void> close() => changes.close();
}
