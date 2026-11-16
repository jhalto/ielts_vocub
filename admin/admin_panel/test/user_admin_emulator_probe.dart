// Explicit demo-runner entry point, deliberately not a normal *_test.dart file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:admin_panel/features/imports/platform_types.dart';
import 'package:admin_panel/features/users/client.dart';
import 'package:admin_panel/features/users/controller.dart';
import 'package:admin_panel/features/words/models.dart' show PublicationFailure;
import 'package:admin_panel/features/words/repository.dart'
    show AdminCredentials;

class UserDemoCredentials implements AdminCredentials {
  UserDemoCredentials(this.uid, this.value);
  @override
  final String uid;
  final String value;
  @override
  Future<String> token(bool forceRefresh) async => value;
}

void main() {
  final config = jsonDecode(
    Platform.environment['VOCAB_USER_ADMIN_DEMO_CONFIG'] ?? '{}',
  ) as Map<String, dynamic>;
  final endpoint = Uri.parse(config['endpoint'] as String? ?? '');
  if (config['projectId'] != 'demo-vocabulary' ||
      !['localhost', '127.0.0.1'].contains(endpoint.host)) {
    throw StateError('Loopback demo configuration required.');
  }
  final uid = config['uid'] as String;
  UserAdminClient client({http.Client? transport}) => UserAdminClient(
    credentials: UserDemoCredentials(uid, config['token'] as String),
    endpoint: endpoint,
    client: transport,
    delay: (_) async {},
  );
  test('real directory follows empty filtered pages and resumes a known pending operation without a browser unlock', () async {
    var demoTime = DateTime.now();
    final c = UserAdminController(
      uid: uid,
      client: client(),
      session: MemoryImportSession(),
      clock: () => demoTime,
    );
    addTearDown(c.dispose);
    await c.firstPage({'provider': 'not-linked.example'});
    expect(c.error, isNull, reason: c.error?.code);
    expect(c.directory!.users, isEmpty);
    expect(c.directory!.next, isNotNull);
    await c.nextPage();
    expect(c.error, isNull, reason: c.error?.code);
    expect(c.directory!.users, isEmpty);
    expect(c.directory!.next, isNull);
    expect(c.hasPrevious, true);
    await c.inspect(config['pendingKey'] as String);
    expect(c.operation!.state, 'pending', reason: c.error?.code);
    demoTime = demoTime.add(const Duration(seconds: 3));
    expect(c.canResume, true);
    await c.resume();
    expect(c.operation!.complete, true, reason: c.error?.code);
    final manager = UserAdminClient(
      credentials: UserDemoCredentials(
        config['managerUid'] as String,
        config['managerToken'] as String,
      ),
      endpoint: endpoint,
    );
    addTearDown(manager.close);
    await expectLater(
      manager.send(
        config['managerUid'] as String,
        '{"action":"list"}',
        active: () => true,
      ),
      throwsA(
        isA<PublicationFailure>().having((e) => e.denied, 'denied', true),
      ),
    );
  });
  test('real concurrent change requires new intent; lost acknowledgements retain exact bytes and safe key recovery', () async {
    final wire = http.Client();
    addTearDown(wire.close);
    final sent = <String>[];
    var lost = false;
    final wrapped = MockClient((request) async {
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      final response = await wire.post(
        request.url,
        headers: request.headers,
        body: request.body,
      );
      if (data['action'] == 'setDisabled' && data['expectedRevision'] == 1) {
        sent.add(request.body);
        if (!lost) {
          lost = true;
          throw http.ClientException('Synthetic lost committed response');
        }
      }
      return response;
    });
    final storage = MemoryImportSession(),
        c = UserAdminController(
          uid: uid,
          client: client(transport: wrapped),
          session: storage,
        );
    addTearDown(c.dispose);
    final target = config['targetUid'] as String;
    await c.lookup(target, byEmail: false);
    expect(c.error, isNull, reason: c.error?.code);
    final observed = c.selected!;
    final competing = await wire.post(
      endpoint,
      headers: {
        'Authorization': 'Bearer ${config['token']}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'action': 'setRole',
        'operationId': 'competing-demo-user-change',
        'targetUid': target,
        'expectedRevision': observed.revision,
        'expectedState': observed.authState,
        'confirmed': true,
        'reason': 'Synthetic concurrent editor request',
        'role': 'content_manager',
      }),
    );
    expect(competing.statusCode, 200);
    expect(jsonDecode(competing.body)['state'], 'complete');
    await c.submit('setDisabled', true, 'Synthetic reviewed disable request');
    expect(c.rejected, true);
    expect([
      'revision-conflict',
      'auth-state-conflict',
    ], contains(c.error!.code));
    final oldId = c.frozen!.data['operationId'];
    c.beginNewChange();
    expect(c.canChange, false);
    await c.refreshSelected();
    expect(c.selected!.revision, 1);
    await c.submit(
      'setDisabled',
      true,
      'Synthetic fresh reviewed disable request',
    );
    expect(c.operation!.complete, true, reason: c.error?.code);
    expect(c.operation!.id, isNot(oldId));
    expect(sent, hasLength(2));
    expect(sent.toSet(), hasLength(1));
    expect(c.operation!.revision, 2);
    final recovered = UserAdminController(
      uid: uid,
      client: client(),
      session: storage,
    );
    addTearDown(recovered.dispose);
    expect(recovered.frozen, isNull);
    expect(recovered.operation, isNull);
    await recovered.refreshOperation();
    expect(recovered.operation!.complete, true, reason: recovered.error?.code);
    expect(jsonDecode(storage.value!)['body'], isNull);
    recovered.beginNewChange();
    await recovered.lookup(target, byEmail: false);
    expect(recovered.selected!.disabled, true);
    await recovered.submit(
      'setDisabled',
      false,
      'Synthetic explicit enable request',
    );
    expect(recovered.operation!.complete, true, reason: recovered.error?.code);
    expect(recovered.operation!.revision, 3);
  });
}
