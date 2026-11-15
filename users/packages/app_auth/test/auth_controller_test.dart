import 'dart:async';

import 'package:app_auth/app_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

Future<void> flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'restored student session survives profile network failure and retries',
    () async {
      final repo = FakeAuthRepository(initial: alice)..failProfile = true;
      final c = AuthController(repo);
      await flush();
      expect(c.canEnter, isTrue);
      expect(c.profilePending, isTrue);
      expect(c.profile, isNull);
      repo.failProfile = false;
      await c.refreshProfile();
      expect(c.profile?['uid'], 'alice');
      expect(c.profilePending, isFalse);
      c.dispose();
      await repo.close();
    },
  );
  test('late profile result cannot cross UID or logout boundary', () async {
    final pending = Completer<Map<String, dynamic>>();
    final repo = FakeAuthRepository(initial: alice)..profileResult = pending;
    final c = AuthController(repo);
    await flush();
    repo.profileResult = null;
    repo.emit(bob);
    await flush();
    pending.complete({'uid': 'alice', 'name': 'Private Alice'});
    await flush();
    expect(c.identity?.uid, 'bob');
    expect(c.profile?['uid'], 'bob');
    await c.signOut();
    await flush();
    expect(c.profile, isNull);
    expect(c.identity, isNull);
    expect(c.canEnter, isFalse);
    c.dispose();
    await repo.close();
  });
  test('guest has no private identity and cannot enter admin', () async {
    final repo = FakeAuthRepository();
    final c = AuthController(repo);
    await flush();
    c.enterGuest();
    expect(c.canEnter, isTrue);
    expect(c.profile, isNull);
    expect(c.identity, isNull);
    c.dispose();
    final admin = AuthController(repo, adminOnly: true);
    await flush();
    admin.enterGuest();
    expect(admin.canEnter, isFalse);
    admin.dispose();
    await repo.close();
  });
  test(
    'admin needs successful online check and loses access on failure',
    () async {
      final repo = FakeAuthRepository(initial: bob);
      final c = AuthController(repo, adminOnly: true);
      await flush();
      expect(c.canEnter, isFalse);
      repo.allowAdmin = true;
      await c.refreshProfile();
      expect(c.canEnter, isTrue);
      repo.failProfile = true;
      await c.refreshProfile();
      expect(c.canEnter, isFalse);
      c.dispose();
      await repo.close();
    },
  );
  test('verification cooldown prevents repeated requests', () async {
    final repo = FakeAuthRepository(initial: alice);
    final c = AuthController(repo);
    await flush();
    await c.sendVerification();
    await c.sendVerification();
    expect(repo.verificationCalls, 1);
    expect(c.canResend, isFalse);
    c.dispose();
    await repo.close();
  });
  test('email and name validators reject invalid input', () {
    expect(validateEmail('learner@example.com'), isNull);
    expect(validateEmail('bad@'), isNotNull);
    expect(validateName('   '), isNotNull);
    expect(validateName('Learner'), isNull);
  });
  test(
    'explicit logout clears private data before ending the session',
    () async {
      final repo = FakeAuthRepository(initial: alice);
      String? cleared;
      final c = AuthController(
        repo,
        clearPrivate: (uid) async {
          expect(repo.current?.uid, 'alice');
          cleared = uid;
        },
      );
      await flush();
      await c.signOut();
      await flush();
      expect(cleared, 'alice');
      expect(repo.current, isNull);
      expect(c.profile, isNull);
      c.dispose();
      await repo.close();
    },
  );
  test('registration starts verification resend cooldown', () async {
    final repo = FakeAuthRepository();
    final c = AuthController(repo);
    await flush();
    await c.register('Alice', 'alice@example.test', 'test-password');
    await flush();
    expect(c.identity?.uid, 'alice');
    expect(c.canResend, isFalse);
    c.dispose();
    await repo.close();
  });
}
