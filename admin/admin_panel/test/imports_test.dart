import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:admin_panel/features/imports/controller.dart';
import 'package:admin_panel/features/imports/models.dart';
import 'package:admin_panel/features/imports/platform_types.dart';
import 'package:admin_panel/features/words/models.dart';

import 'support/fake_imports.dart';

class UnavailableSession extends MemoryImportSession {
  bool blocked = true;
  @override
  void write(String value) {
    if (blocked) throw StateError('Synthetic storage failure');
    super.write(value);
  }
}

void main() {
  test('unavailable checkpoint storage prevents mutation and retry retains the original identity', () async {
    final server = FakeImports(), storage = UnavailableSession();
    final c = ImportController(
      uid: 'bob',
      client: server.client(),
      session: storage,
    );
    addTearDown(c.dispose);
    c.load(pickedFile());
    await c.preview();
    await c.create();
    expect(c.error!.code, 'checkpoint');
    expect(server.requests.where((r) => r['action'] == 'create'), isEmpty);
    final id = c.jobId, body = c.frozenCreate;
    storage.blocked = false;
    await c.create();
    expect(c.jobId, id);
    expect(c.confirmed, true);
    expect(
      server.bodies[server.requests.indexWhere((r) => r['action'] == 'create')],
      body,
    );
  });
  late FakeImports server;
  late MemoryImportSession storage;
  late ImportController c;
  var now = DateTime.utc(2026);
  setUp(() {
    server = FakeImports();
    storage = MemoryImportSession();
    c = ImportController(
      uid: 'bob',
      client: server.client(),
      session: storage,
      clock: () => now,
    );
  });
  tearDown(() => c.dispose());
  test('file types, schema, size and UTF-8 fail safely; file review flags are cleared', () {
    for (final file in [
      PickedJson('data.csv', 'text/csv', Uint8List(0)),
      PickedJson('data.json', 'application/json', Uint8List(524289)),
      PickedJson('data.json', '', Uint8List.fromList([255])),
      PickedJson(
        'data.json',
        '',
        Uint8List.fromList(utf8.encode('{"schemaVersion":2,"items":[]}')),
      ),
    ]) {
      c.load(file);
      expect(c.error, isNotNull);
      expect(c.rows, isEmpty);
    }
    c.load(
      pickedFile([
        {...importRow(), 'reviewed': true},
      ]),
    );
    expect((c.rows.single as Map).containsKey('reviewed'), false);
    expect(server.requests, isEmpty);
  });
  test('normalized bilingual preview is required and changing a row invalidates it', () async {
    c.load(pickedFile());
    expect(c.canCreate, false);
    await c.preview();
    expect(c.canCreate, true, reason: c.error?.toString());
    expect(
      c.previews.single['content']['senses'][0]['bengaliMeaning'],
      isNotEmpty,
    );
    c.changeRow(0, {
      ...importRow(),
      'expectedRevision': 5,
      'decision': 'update',
    });
    expect(c.canCreate, false);
    expect(c.previews, isEmpty);
  });
  test(
    'published updates require explicit UI attestation and a fresh preview',
    () async {
      server.publishedTargets = true;
      c.load(
        pickedFile([
          {
            ...importRow(),
            'decision': 'update',
            'expectedRevision': 2,
            'reviewed': true,
          },
        ]),
      );
      await c.preview();
      expect(c.canCreate, false);
      expect(c.previews.single['errors'], contains('review-required'));
      c.attest(0);
      expect(c.canCreate, false);
      await c.preview();
      expect(c.canCreate, true);
      c.changeRow(0, {
        ...importRow(),
        'decision': 'update',
        'expectedRevision': 2,
      });
      expect((c.rows.single as Map)['reviewed'], isNull);
    },
  );
  test('creation is frozen before sending; automatic and manual retries use identical IDs and bytes', () async {
    server.loseCreate = 3;
    c.load(pickedFile());
    await c.preview();
    await c.create();
    final frozen = c.frozenCreate, id = c.jobId;
    expect(frozen, isNotNull);
    expect(c.confirmed, false);
    expect(storage.value, contains(id!));
    c.changeRow(0, {...importRow(), 'wordId': 'changed'});
    expect(c.frozenCreate, frozen);
    now = now.add(const Duration(seconds: 3));
    await c.create();
    final bodies = server.requests.indexed
        .where((e) => e.$2['action'] == 'create')
        .map((e) => server.bodies[e.$1])
        .toSet();
    expect(bodies, {frozen});
    expect(c.jobId, id);
    expect(c.confirmed, true);
    expect(server.waits, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);
    expect(jsonDecode(storage.value!)['body'], isNull);
  });
  test('reload can recover an unconfirmed creation without automatically uploading', () async {
    server.loseCreate = 3;
    c.load(pickedFile());
    await c.preview();
    await c.create();
    final before = server.requests.length;
    final recovered = ImportController(
      uid: 'bob',
      client: server.client(),
      session: storage,
    );
    addTearDown(recovered.dispose);
    expect(server.requests.length, before);
    expect(recovered.frozenCreate, c.frozenCreate);
    await recovered.refresh();
    expect(recovered.confirmed, true);
    expect(recovered.frozenCreate, isNull);
  });
  test('lost process acknowledgements reconcile durable outcomes before another batch', () async {
    c.load(pickedFile());
    await c.preview();
    await c.create();
    server.loseProcess = 3;
    await c.processNext();
    expect(c.error, isNotNull);
    expect(c.job!.counts['pending'], 1);
    now = now.add(const Duration(seconds: 3));
    final before = server.requests
        .where((r) => r['action'] == 'process')
        .length;
    await c.processNext();
    expect(c.job!.counts['applied'], 1);
    expect(
      server.requests.where((r) => r['action'] == 'process').length,
      before,
    );
  });
  test('status pagination resumes without source file and processing is bounded to five', () async {
    c.load(
      pickedFile(
        List.generate(
          28,
          (i) => importRow('row-${i.toString().padLeft(2, '0')}'),
        ),
      ),
    );
    await c.preview();
    await c.create();
    expect(c.receipts, hasLength(28));
    final resumed = ImportController(
      uid: 'bob',
      client: server.client(),
      session: storage,
    );
    addTearDown(resumed.dispose);
    await resumed.refresh();
    expect(resumed.receipts, hasLength(28));
    await resumed.processNext();
    expect(resumed.job!.counts['applied'], 5);
    expect(
      (server.requests.lastWhere((r) => r['action'] == 'process')['itemIds']
          as List),
      hasLength(5),
    );
  });
  test('interrupted pagination keeps prior complete receipts and does not select partial work', () async {
    c.load(
      pickedFile(
        List.generate(
          28,
          (i) => importRow('row-${i.toString().padLeft(2, '0')}'),
        ),
      ),
    );
    await c.preview();
    await c.create();
    final previous = c.receipts;
    server.failSecondPage = true;
    await c.processNext();
    expect(c.receipts, same(previous));
    expect(server.requests.where((r) => r['action'] == 'process'), isEmpty);
    expect(c.error, isNotNull);
  });
  test('partial failures remain terminal; correction starts a new job without mutating the old plan', () async {
    server.failed.add('bad');
    c.load(pickedFile([importRow('bad'), importRow('good')]));
    await c.preview();
    await c.create();
    final id = c.jobId;
    await c.processNext();
    expect(c.job!.status, 'completed_with_errors');
    expect(c.job!.counts['failed'], 1);
    expect(c.job!.counts['applied'], 1);
    await c.processNext();
    expect(
      server.requests.where((r) => r['action'] == 'process'),
      hasLength(1),
    );
    c.newPlan();
    c.load(
      pickedFile([
        {...importRow('bad'), 'decision': 'update', 'expectedRevision': 3},
      ]),
    );
    await c.preview();
    await c.create();
    expect(c.jobId, isNot(id));
    expect(server.jobs[id], isNotNull);
  });
  test('transient item quota failures retain intent and impose a durable-state-informed cooldown', () async {
    c.load(pickedFile());
    await c.preview();
    await c.create();
    server.pendingError = 'rate-limited';
    await c.processNext();
    expect(c.job!.counts['pending'], 1);
    expect(c.canRequest, false);
    final before = server.requests.length;
    await c.processNext();
    expect(server.requests.length, before);
    now = now.add(const Duration(seconds: 61));
    server.pendingError = null;
    await c.processNext();
    expect(c.job!.counts['applied'], 1);
  });
  test('late failed resume cannot restore an old account job ID after isolation clears it', () async {
    c.load(pickedFile());
    await c.preview();
    await c.create();
    final response = Completer<http.Response>();
    server.override = (_) => response.future;
    final pending = c.resume('another-job');
    await Future<void>.delayed(Duration.zero);
    c.setAvailable(false, clearPrivate: true);
    server.credentials.uid = 'alice';
    response.complete(http.Response('{"code":"permission-denied"}', 403));
    await pending;
    expect(c.jobId, isNull);
    expect(storage.value, isNull);
  });
  test('account switch discards a late response and erases the previous owner checkpoint', () async {
    c.load(pickedFile());
    await c.preview();
    final response = Completer<http.Response>();
    server.override = (_) => response.future;
    final pending = c.create();
    await Future<void>.delayed(Duration.zero);
    c.setAvailable(false, clearPrivate: true);
    server.credentials.uid = 'alice';
    response.complete(http.Response('{"code":"permission-denied"}', 403));
    await pending;
    expect(c.jobId, isNull);
    expect(c.job, isNull);
    expect(c.rows, isEmpty);
    expect(storage.value, isNull);
  });
  test(
    'permission denial triggers reauthorization once with no processing retry',
    () async {
      var denied = 0;
      final client = server.client(onDenied: () => denied++);
      addTearDown(client.close);
      server.override = (_) async =>
          http.Response('{"code":"permission-denied"}', 403);
      await expectLater(
        client.send('bob', '{"action":"get","jobId":"j"}', active: () => true),
        throwsA(
          isA<PublicationFailure>().having((e) => e.denied, 'denied', true),
        ),
      );
      expect(denied, 1);
      expect(server.requests, hasLength(1));
    },
  );
  test('attestation setup errors remain visible without a misleading successful role recheck', () async {
    var denied = 0;
    final client = server.client(onDenied: () => denied++);
    addTearDown(client.close);
    final controller = ImportController(
      uid: 'bob',
      client: client,
      session: MemoryImportSession(),
    );
    addTearDown(controller.dispose);
    server.override = (_) async =>
        http.Response('{"code":"app-check-required"}', 403);
    controller.load(pickedFile());
    await controller.preview();
    expect(controller.error!.code, 'app-check-required');
    expect(denied, 0);
    expect(server.requests, hasLength(1));
  });
  test('HTTP token refresh preserves exact request bytes', () async {
    final client = server.client();
    addTearDown(client.close);
    var calls = 0;
    server.override = (_) async => ++calls == 1
        ? http.Response('{"code":"unauthenticated"}', 401)
        : http.Response('{"ok":true}', 200);
    await client.send(
      'bob',
      '{"action":"get","jobId":"j"}',
      active: () => true,
    );
    expect(server.bodies.toSet(), {'{"action":"get","jobId":"j"}'});
    expect(server.credentials.refreshes, [false, true]);
  });
  test('malformed counts and applied draft publication cannot be accepted as success', () {
    expect(
      () => ImportJob.parse({
        'schemaVersion': 1,
        'jobId': 'j',
        'status': 'completed',
        'counts': {
          'total': 1,
          'pending': 1,
          'applied': 0,
          'failed': 0,
          'skipped': 0,
        },
      }, 'j'),
      throwsFormatException,
    );
    expect(
      () => ImportReceipt.parse({
        'itemId': 'row',
        'index': 0,
        'decision': 'create',
        'state': 'applied',
        'wordId': 'word',
        'attempts': 1,
        'lastError': null,
        'result': {
          'wordId': 'word',
          'revision': 1,
          'isPublished': true,
          'isRetired': false,
        },
      }),
      throwsFormatException,
    );
  });
}
