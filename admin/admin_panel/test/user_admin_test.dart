import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:admin_panel/features/imports/platform_types.dart';
import 'package:admin_panel/features/users/controller.dart';

import 'support/fake_user_admin.dart';

class UnavailableUserSession extends MemoryImportSession {
  bool blocked = true;
  @override
  void write(String value) {
    if (blocked) throw StateError('Synthetic storage failure');
    super.write(value);
  }
}

void main() {
  late FakeUserAdmin server;
  late MemoryImportSession storage;
  late UserAdminController c;
  late DateTime now;
  setUp(() {
    server = FakeUserAdmin();
    storage = MemoryImportSession();
    now = DateTime.utc(2026);
    c = UserAdminController(
      uid: 'bob',
      client: server.client(),
      session: storage,
      clock: () => now,
    );
  });
  tearDown(() => c.dispose());
  Future<void> select() => c.lookup('target', byEmail: false);
  test('exact UID/email lookup and safe projections never retain extra identity credentials', () async {
    server.users['target']!.addAll({
      'passwordHash': 'never-display',
      'customClaims': {'secret': 'never-display'},
    });
    await c.lookup('target@example.test', byEmail: true);
    expect(c.selected!.uid, 'target');
    expect(server.requests.single, {
      'action': 'get',
      'email': 'target@example.test',
    });
    expect(c.selected!.providers, ['password']);
    expect(c.selected!.revision, 0);
    expect(c.selected!.pending, false);
  });
  test('empty filtered native pages keep their continuation and support previous navigation', () async {
    server.pages = [
      {
        'schemaVersion': 1,
        'users': [],
        'scanned': 25,
        'nextCursor': 'cursor-1',
      },
      {
        'schemaVersion': 1,
        'users': [userDto('target')],
        'scanned': 1,
        'nextCursor': null,
      },
    ];
    await c.firstPage({'disabled': false});
    expect(c.directory!.users, isEmpty);
    expect(c.directory!.next, 'cursor-1');
    await c.nextPage();
    expect(c.directory!.users.single.uid, 'target');
    expect(server.requests.last['filters'], {'disabled': false});
    expect(server.requests.last['cursor'], 'cursor-1');
    await c.previousPage();
    expect(c.directory!.users, isEmpty);
    expect(server.requests.last.containsKey('cursor'), false);
  });
  test('failed pagination preserves the displayed page and its cursor/filter context', () async {
    server.pages = [
      {
        'schemaVersion': 1,
        'users': [],
        'scanned': 25,
        'nextCursor': 'cursor-1',
      },
    ];
    await c.firstPage({'role': 'student'});
    final old = c.directory;
    server.intercept = (_) async =>
        userReply({'code': 'service-unavailable'}, 503);
    await c.nextPage();
    expect(c.directory, same(old));
    expect(c.hasPrevious, false);
    expect(c.filters, {'role': 'student'});
  });
  test('reason, no-op, self and administrative grant eligibility prevent unsafe requests', () async {
    await select();
    await c.submit('setDisabled', true, 'bad');
    expect(server.operations, isEmpty);
    await c.submit('setRole', 'student', 'Reviewed reason');
    expect(server.operations, isEmpty);
    await c.lookup('bob', byEmail: false);
    expect(c.canChange, false);
    server.users['target']!['emailVerified'] = false;
    await select();
    await c.submit('setRole', 'super_admin', 'Reviewed reason');
    expect(server.operations, isEmpty);
  });
  test('successful change uses observed preconditions and drops cached reason after confirmation', () async {
    await select();
    final user = c.selected!;
    await c.submit('setRole', 'content_manager', 'Reviewed access reason');
    final sent = server.requests.lastWhere((r) => r['action'] == 'setRole');
    expect(sent['confirmed'], true);
    expect(sent['expectedRevision'], user.revision);
    expect(sent['expectedState'], user.authState);
    expect(c.operation!.complete, true);
    expect(c.operation!.signInAfter, isNotNull);
    expect(c.selectedStale, true);
    expect(c.frozen, isNull);
    expect(jsonDecode(storage.value!)['body'], isNull);
  });
  test('three lost acknowledgements retain exact immutable bytes across a manual retry', () async {
    server.loseMutations = 3;
    await select();
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    final body = c.frozen!.body;
    expect(c.operation, isNull);
    expect(c.rejected, false);
    expect(server.operations, hasLength(1));
    now = now.add(const Duration(seconds: 3));
    await c.retryOriginal();
    expect(c.operation!.complete, true);
    final sent = server.requests.indexed
        .where((e) => e.$2['action'] == 'setDisabled')
        .map((e) => server.bodies[e.$1])
        .toSet();
    expect(sent, {body});
    expect(server.operations, hasLength(1));
    expect(server.waits, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);
  });
  test('reload preserves unknown request identity without automatically submitting it', () async {
    server.loseMutations = 3;
    await select();
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    final count = server.requests.length;
    final recovered = UserAdminController(
      uid: 'bob',
      client: server.client(),
      session: storage,
    );
    addTearDown(recovered.dispose);
    expect(recovered.frozen!.body, c.frozen!.body);
    expect(server.requests.length, count);
    await recovered.retryOriginal();
    expect(recovered.operation!.complete, true);
  });
  test('checkpoint failure prevents mutation and preserves original ID for a safe storage retry', () async {
    final blocked = UnavailableUserSession();
    final other = UserAdminController(
      uid: 'bob',
      client: server.client(),
      session: blocked,
    );
    addTearDown(other.dispose);
    await other.lookup('target', byEmail: false);
    await other.submit('setDisabled', true, 'Reviewed disable reason');
    final original = other.frozen!.body;
    expect(server.operations, isEmpty);
    expect(other.error!.code, 'checkpoint');
    blocked.blocked = false;
    await other.retryOriginal();
    expect(other.operation!.complete, true);
    expect(server.operationBodies.values.single, original);
  });
  test('pending HTTP 200 is not complete; explicit same-key resume keeps original intent', () async {
    server.mode = 'pending';
    await select();
    await c.submit('setRole', 'content_manager', 'Reviewed grant reason');
    expect(c.operation!.complete, false);
    expect(c.canResume, true);
    expect(c.canChange, false);
    final key = c.operationKey;
    await c.resume();
    expect(c.operation!.complete, true);
    expect(c.operationKey, key);
    expect(server.requests.last, {'action': 'resume', 'operationKey': key});
  });
  test(
    'active and recovery-required workers expose no browser resume route',
    () async {
      server.mode = 'recovery_required';
      await select();
      await c.submit('setDisabled', true, 'Reviewed disable reason');
      final before = server.requests.length;
      expect(c.operation!.state, 'recovery_required');
      expect(c.canResume, false);
      await c.resume();
      expect(server.requests.length, before);
      final op = server.operations.values.single;
      op['state'] = 'pending';
      op['lastError'] = null;
      await c.refreshOperation();
      expect(c.operation!.worker, true);
      expect(c.canResume, false);
      op['workerActive'] = false;
      await c.refreshOperation();
      expect(c.canResume, true);
    },
  );
  test('conflict correction requires explicit new intent, fresh read and a new operation ID', () async {
    await select();
    server.refusal = 'revision-conflict';
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    final old = c.frozen!.data['operationId'];
    expect(c.rejected, true);
    expect(c.canChange, false);
    c.beginNewChange();
    expect(c.selectedStale, true);
    expect(c.canChange, false);
    server.refusal = null;
    await c.refreshSelected();
    await c.submit('setDisabled', true, 'New reviewed disable reason');
    expect(c.operation!.id, isNot(old));
  });
  test('last-super-admin rejection is preserved and never converted into another action', () async {
    await select();
    server.refusal = 'last-super-admin';
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    expect(c.error!.code, 'last-super-admin');
    expect(c.rejected, true);
    expect(server.operations, isEmpty);
    expect(
      server.requests.where((r) => r['action'] == 'setDisabled'),
      hasLength(1),
    );
  });
  test('read errors cannot declare an unconfirmed mutation rejected', () async {
    server.loseMutations = 3;
    await select();
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    now = now.add(const Duration(seconds: 3));
    server.intercept = (_) async => userReply({'code': 'user-not-found'}, 404);
    await c.refreshSelected();
    expect(c.rejected, false);
    expect(c.frozen, isNotNull);
  });
  test('malformed or mismatched operation acknowledgement never clears frozen recovery', () async {
    await select();
    server.intercept = (request) async => userReply({
      'schemaVersion': 1,
      'operationKey': 'f' * 64,
      'state': 'complete',
    });
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    expect(c.frozen, isNotNull);
    expect(c.operation, isNull);
    expect(c.error!.code, 'invalid-response');
  });
  test('an acknowledgement with an additional unrequested role effect cannot confirm a status change', () async {
    await select();
    server.intercept = (request) async {
      final d = jsonDecode(request.body) as Map<String, dynamic>;
      return userReply({
        'schemaVersion': 1,
        'operationKey': (d['operationId'] as String).padRight(64, '0'),
        'operationId': d['operationId'],
        'actorUid': 'bob',
        'targetUid': 'target',
        'action': 'setDisabled',
        'state': 'complete',
        'phase': 'complete',
        'revision': 1,
        'before': {'role': 'student', 'disabled': false, 'emailVerified': true},
        'after': {
          'role': 'super_admin',
          'disabled': true,
          'emailVerified': true,
        },
        'workerActive': false,
        'lastError': null,
        'result': {
          'uid': 'target',
          'administrationRevision': 1,
          'authState': 'a' * 64,
          'reauthenticateAfter': 1760000000,
          'role': 'super_admin',
          'disabled': true,
          'emailVerified': true,
        },
      });
    };
    await c.submit('setDisabled', true, 'Reviewed disable request');
    expect(c.operation, isNull);
    expect(c.frozen, isNotNull);
    expect(c.error!.code, 'invalid-response');
  });
  test(
    'status lookup must match unknown original actor, target and operation ID',
    () async {
      server.loseMutations = 3;
      await select();
      await c.submit('setDisabled', true, 'Reviewed disable reason');
      now = now.add(const Duration(seconds: 3));
      final op = server.operations.values.single;
      final original = op['operationId'];
      op['operationId'] = 'wrong-id';
      await c.inspect(op['operationKey'] as String);
      expect(c.frozen, isNotNull);
      expect(c.operation, isNull);
      now = now.add(const Duration(seconds: 3));
      op['operationId'] = original;
      await c.inspect(op['operationKey'] as String);
      expect(c.operation!.complete, true);
      expect(c.frozen, isNull);
    },
  );
  test(
    'account switch erases private state and ignores the old request response',
    () async {
      await select();
      final response = Completer<http.Response>();
      server.intercept = (_) => response.future;
      final pending = c.submit('setDisabled', true, 'Reviewed disable reason');
      await Future<void>.delayed(Duration.zero);
      c.setAccess(false, clearPrivate: true);
      server.credentials.uid = 'alice';
      response.complete(userReply({'code': 'permission-denied'}, 403));
      await pending;
      expect(c.selected, isNull);
      expect(c.frozen, isNull);
      expect(c.operationKey, isNull);
      expect(storage.value, isNull);
    },
  );
  test('another owner cannot load the previous checkpoint', () async {
    server.loseMutations = 3;
    await select();
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    final other = UserAdminController(
      uid: 'alice',
      client: server.client(),
      session: storage,
    );
    addTearDown(other.dispose);
    expect(other.frozen, isNull);
    expect(other.operationKey, isNull);
    expect(other.error!.code, 'checkpoint');
  });
  test(
    'quota handling requires a cooldown and does not create a new ID',
    () async {
      await select();
      server.intercept = (_) async => userReply({'code': 'rate-limited'}, 429);
      await c.submit('setDisabled', true, 'Reviewed disable reason');
      final id = c.frozen!.data['operationId'];
      expect(c.canRequest, false);
      final before = server.requests.length;
      await c.retryOriginal();
      expect(server.requests.length, before);
      now = now.add(const Duration(seconds: 61));
      server.intercept = null;
      await c.retryOriginal();
      expect(c.operation!.id, id);
    },
  );
  test('confirmation binds the displayed snapshot rather than a later selected target', () async {
    await select();
    final reviewed = c.selected!;
    server.users['target'] = userDto('target', revision: 1);
    await c.refreshSelected();
    await c.submit(
      'setDisabled',
      true,
      'Reviewed disable reason',
      reviewedTarget: reviewed,
    );
    expect(c.error!.code, 'local-target-changed');
    expect(server.operations, isEmpty);
  });
  test('a confirmed historical receipt needs a new explicit target read before another change', () async {
    await select();
    await c.submit('setDisabled', true, 'Reviewed disable reason');
    c.beginNewChange();
    expect(c.canChange, false);
    await c.refreshSelected();
    expect(c.selected!.disabled, true);
    expect(c.canChange, true);
  });
}
