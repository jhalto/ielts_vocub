import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_learning/local_learning.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'store_test.dart' as fixtures;
import 'support/fake_progress.dart';

ProgressSynchronizer engine(
  LearningStore db,
  ProgressRemote remote, {
  bool Function()? authorized,
  int pageSize = 100,
}) => ProgressSynchronizer(
  store: db,
  uid: 'alice',
  remote: remote,
  stillAuthorized: authorized ?? () => true,
  pageSize: pageSize,
  delay: (_) async {},
);
Future<LearningStore> pendingStore({File? file}) async {
  final db = LearningStore(
    file == null ? NativeDatabase.memory() : NativeDatabase(file),
  );
  await fixtures.seed(db, [
    fixtures.word('a'),
    fixtures.word('b', ordering: 1),
  ]);
  await db.startSession('alice', Category.basic, Difficulty.easy);
  await db.swipe('alice', 'a', false);
  return db;
}

class Credentials implements ProgressCredentials {
  @override
  String? uid = 'alice';
  int refreshes = 0;
  @override
  Future<String> token(bool refresh) async {
    if (refresh) refreshes++;
    return 'token';
  }
}

void main() {
  test('failed acknowledgement transaction preserves retry payload after the server saves', () async {
    final db = await pendingStore();
    addTearDown(db.close);
    final remote = FakeProgressRemote();
    await db.customStatement(
      "CREATE TRIGGER fail_ack BEFORE UPDATE ON pending_sync_operations WHEN NEW.state='applied' BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END",
    );
    final sync = engine(db, remote);
    addTearDown(sync.dispose);
    await sync.sync();
    final before = (await db.rows('SELECT * FROM pending_sync_operations'))
        .single;
    expect(before['state'], 'inflight');
    expect(remote.revisions['alice'], 1);
    expect(await db.rows('SELECT * FROM remote_progress'), isEmpty);
    await db.customStatement('DROP TRIGGER fail_ack');
    await sync.sync();
    expect(await db.pendingCount('alice'), 0);
    expect(remote.revisions['alice'], 1);
    expect(
      (await db.rows('SELECT * FROM pending_sync_operations'))
          .single['request_payload'],
      before['request_payload'],
    );
  });
  test(
    'restart reports interrupted sync and clears only staged remote pages',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sync-interrupted-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/store.sqlite');
      var db = await pendingStore(file: file);
      final frozen = (await db.prepareSync(
        'alice',
        limit: 25,
        active: () => true,
      )).single;
      await db.setSyncPhase('alice', 'syncing', active: () => true);
      await db.stageProgress('alice', 'abandoned', [
        {
          'wordId': 'a',
          'status': 'learned',
          'revision': 1,
          'lastOperationId': 'remote-1',
        },
      ], active: () => true);
      await db.close();
      db = LearningStore(NativeDatabase(file));
      addTearDown(db.close);
      expect((await db.syncView('alice')).error, 'sync-interrupted');
      expect((await db.syncView('alice')).phase, 'failed');
      expect(await db.rows('SELECT * FROM progress_staging'), isEmpty);
      expect(
        (await db.rows('SELECT * FROM pending_sync_operations'))
            .single['request_payload'],
        frozen['request_payload'],
      );
      expect(await db.pendingCount('alice'), 1);
    },
  );
  test('v1 migration preserves content, progress, queue, IDs and installation identity', () async {
    final directory = await Directory.systemTemp.createTemp('sync-migration-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/old.sqlite');
    final old = sqlite.sqlite3.open(file.path);
    for (final sql in LearningStore.schema) {
      old.execute(sql);
    }
    old.execute('PRAGMA user_version=1');
    old.execute("INSERT INTO local_metadata VALUES('device_id','old-device')");
    old.execute('INSERT INTO words VALUES(?,?,?,?,?,?,?,?)', [
      'a',
      'basic',
      'easy',
      0,
      1,
      1,
      jsonEncode(fixtures.word('a').toJson()),
      'word a',
    ]);
    old.execute(
      "INSERT INTO user_progress VALUES('alice','a','didnt_know',0,'old','old')",
    );
    old.execute("INSERT INTO local_sequences VALUES('alice',1)");
    old.execute(
      "INSERT INTO pending_sync_operations(operation_id,uid,word_id,desired_status,base_revision,sequence,created_at,device_id) VALUES('original-op','alice','a','didnt_know',0,1,'old','old-device')",
    );
    old.execute(
      "INSERT INTO learning_sessions VALUES('session','alice','basic','easy',NULL,1,'{}')",
    );
    old.execute("INSERT INTO learning_queue_items VALUES('session','a',0)");
    old.close();
    final db = LearningStore(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.pendingCount('alice'), 1);
    expect((await db.rows('PRAGMA user_version')).single.values.single, 3);
    expect((await db.session('alice'))!['id'], 'session');
    expect(
      (await db.rows('SELECT * FROM local_metadata')).single['value'],
      'old-device',
    );
    final prepared = await db.prepareSync(
      'alice',
      limit: 25,
      active: () => true,
    );
    final payload = jsonDecode(prepared.single['request_payload'] as String);
    expect(payload['operationId'], 'original-op');
    expect(payload['deviceId'], 'old-device');
    expect((await db.syncView('alice')).automatic, isFalse);
    expect((await db.rows('PRAGMA foreign_key_check')), isEmpty);
  });
  test('single flight shares one upload and successful reconciliation clears only matching work', () async {
    final db = await pendingStore();
    addTearDown(db.close);
    final remote = FakeProgressRemote();
    final entered = Completer<void>(), release = Completer<void>();
    remote.onUpload = (_) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final sync = engine(db, remote);
    addTearDown(sync.dispose);
    final first = sync.sync();
    await entered.future;
    final second = sync.sync();
    expect(identical(first, second), isTrue);
    release.complete();
    await Future.wait([first, second]);
    expect(
      remote.bodies.where((b) => jsonDecode(b)['action'] == 'upload').length,
      1,
    );
    expect(await db.pendingCount('alice'), 0);
    expect((await db.syncView('alice')).phase, 'synced');
    expect((await db.syncView('alice')).lastSuccess, isNotNull);
  });
  test('lost acknowledgements preserve frozen IDs/payload through restart and replay once', () async {
    final directory = await Directory.systemTemp.createTemp('sync-restart-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/store.sqlite');
    var db = await pendingStore(file: file);
    final remote = FakeProgressRemote()..loseAcknowledgements = true;
    var sync = engine(db, remote);
    await sync.sync();
    final before = (await db.rows('SELECT * FROM pending_sync_operations'))
        .single;
    expect(before['state'], 'inflight');
    expect(before['retry_count'], 3);
    expect((await db.syncView('alice')).phase, 'offline');
    expect(remote.revisions['alice'], 1);
    sync.dispose();
    await db.close();
    db = LearningStore(NativeDatabase(file));
    addTearDown(db.close);
    remote.loseAcknowledgements = false;
    sync = engine(db, remote);
    addTearDown(sync.dispose);
    await sync.sync();
    final after = (await db.rows('SELECT * FROM pending_sync_operations'))
        .single;
    expect(after['operation_id'], before['operation_id']);
    expect(after['request_payload'], before['request_payload']);
    expect(after['state'], 'applied');
    expect(remote.revisions['alice'], 1);
    expect(await db.pendingCount('alice'), 0);
    expect(
      remote.bodies
          .where((b) => jsonDecode(b)['action'] == 'upload')
          .toSet()
          .length,
      1,
    );
  });
  test('newer local swipe survives older ACK and explicit durable rebase uploads latest intent', () async {
    final db = await pendingStore();
    addTearDown(db.close);
    final remote = FakeProgressRemote();
    var newer = false;
    remote.onUpload = (_) async {
      if (newer) return;
      newer = true;
      await db.swipe('alice', 'b', true);
      await db.swipe('alice', 'a', true);
    };
    final sync = engine(db, remote);
    addTearDown(sync.dispose);
    await sync.sync();
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['learned'],
      1,
    );
    final issues = await db.syncIssues('alice');
    expect(issues, hasLength(1));
    expect(issues.single['local_status'], 'learned');
    final oldPayloads = (await db.rows(
      'SELECT request_payload FROM pending_sync_operations WHERE request_payload IS NOT NULL',
    )).map((r) => r['request_payload']).toList();
    await sync.resolve(
      'a',
      issues.single['latest_operation_id'] as String,
      keepLocal: true,
    );
    expect(
      (await db.rows(
        "SELECT * FROM pending_sync_operations WHERE state='superseded'",
      )),
      hasLength(1),
    );
    await sync.sync();
    expect(remote.records['alice']!['a']!['status'], 'learned');
    expect(await db.pendingCount('alice'), 0);
    final all = (await db.rows(
      'SELECT request_payload FROM pending_sync_operations',
    )).map((r) => r['request_payload']).toList();
    expect(all, containsAll(oldPayloads));
  });
  test('stale confirmation cannot discard a newer local intent', () async {
    final db = await pendingStore();
    addTearDown(db.close);
    final remote = FakeProgressRemote()..put('alice', 'a', 'learned');
    final sync = engine(db, remote);
    addTearDown(sync.dispose);
    await sync.sync();
    final issue = (await db.syncIssues('alice')).single;
    await db.swipe('alice', 'b', true);
    await db.swipe('alice', 'a', true);
    await expectLater(
      sync.resolve(
        'a',
        issue['latest_operation_id'] as String,
        keepLocal: false,
      ),
      throwsA(isA<SyncFailure>()),
    );
    expect(await db.pendingCount('alice'), greaterThan(0));
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['learned'],
      1,
    );
  });
  test('a late response after logout cannot resurrect private rows even for the same UID', () async {
    final db = await pendingStore();
    addTearDown(db.close);
    final remote = FakeProgressRemote();
    remote.onUpload = (_) async {
      await db.clearPrivate('alice');
    };
    final sync = engine(db, remote);
    addTearDown(sync.dispose);
    await sync.sync();
    for (final table in [
      'user_progress',
      'pending_sync_operations',
      'remote_progress',
      'sync_status',
    ]) {
      expect(await db.rows('SELECT * FROM $table'), isEmpty);
    }
    expect(await db.session('alice'), isNull);
  });
  test('account changes during upload keep old-UID pending work and never apply it to another UID', () async {
    final db = await pendingStore();
    addTearDown(db.close);
    final remote = FakeProgressRemote();
    var active = true;
    remote.onUpload = (_) async {
      active = false;
    };
    final sync = engine(db, remote, authorized: () => active);
    addTearDown(sync.dispose);
    await sync.sync();
    expect(await db.pendingCount('alice'), 1);
    expect(await db.pendingCount('bob'), 0);
    expect(
      await db.rows("SELECT * FROM remote_progress WHERE uid='bob'"),
      isEmpty,
    );
    expect(
      (await db.rows('SELECT * FROM pending_sync_operations')).single['state'],
      'inflight',
    );
  });
  test('interrupted paginated retrieval never materializes a partial remote snapshot', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    await fixtures.seed(db, [fixtures.word('a'), fixtures.word('b')]);
    final remote = FakeProgressRemote()
      ..put('alice', 'a', 'learned')
      ..put('alice', 'b', 'already_know');
    remote.onList = (input) async {
      if (input['cursor'] != null) throw const SyncFailure('offline');
    };
    final sync = engine(db, remote, pageSize: 1);
    addTearDown(sync.dispose);
    await sync.sync();
    expect(await db.rows('SELECT * FROM user_progress'), isEmpty);
    expect(await db.rows('SELECT * FROM progress_staging'), isEmpty);
    expect((await db.syncView('alice')).lastSuccess, isNull);
    remote.onList = null;
    await sync.sync();
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['learned'],
      1,
    );
  });
  test('pagination restart captures a complete newer revision and unknown words keep remote progress', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    await fixtures.seed(db, [fixtures.word('a')]);
    final remote = FakeProgressRemote()
      ..put('alice', 'a', 'didnt_know')
      ..put('alice', 'not-downloaded', 'learned');
    var changed = false;
    remote.onList = (input) async {
      if (input['cursor'] != null && !changed) {
        changed = true;
        remote.put('alice', 'a', 'learned');
      }
    };
    final sync = engine(db, remote, pageSize: 1);
    addTearDown(sync.dispose);
    await sync.sync();
    expect(changed, isTrue);
    expect((await db.syncView('alice')).phase, 'synced');
    expect(await db.rows('SELECT * FROM remote_progress'), hasLength(2));
    expect(await db.rows('SELECT * FROM user_progress'), hasLength(1));
    await fixtures.seed(db, [
      fixtures.word('a'),
      fixtures.word('not-downloaded'),
    ]);
    await db.materializeProgress('alice', active: () => true);
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['learned'],
      2,
    );
  });
  test('unavailable words keep rejected history, leave queues and require an explicit decision', () async {
    final db = await pendingStore();
    addTearDown(db.close);
    final remote = FakeProgressRemote()..blocked.add('a');
    final sync = engine(db, remote);
    addTearDown(sync.dispose);
    await sync.sync();
    expect((await db.syncView('alice')).phase, 'conflict');
    expect(await db.pendingCount('alice'), 1);
    expect((await db.session('alice'))!['queue'], hasLength(1));
    expect(
      (await db.rows('SELECT * FROM user_progress')).single['status'],
      'didnt_know',
    );
    final issue = (await db.syncIssues('alice')).single;
    await sync.resolve(
      'a',
      issue['latest_operation_id'] as String,
      keepLocal: false,
    );
    expect(await db.pendingCount('alice'), 0);
    expect(
      (await db.rows('SELECT * FROM pending_sync_operations')).single['state'],
      'superseded',
    );
  });
  test(
    'HTTP refresh retries exact bytes and checks UID before using a token',
    () async {
      final credentials = Credentials();
      final bodies = <String>[];
      final client = MockClient((request) async {
        bodies.add(request.body);
        return bodies.length == 1
            ? http.Response('{"code":"unauthenticated"}', 401)
            : http.Response(
                '{"schemaVersion":1,"progress":[],"revision":0,"nextCursor":null}',
                200,
              );
      });
      final remote = HttpProgressRemote(
        endpoint: Uri.parse('https://test.invalid/progressApi'),
        credentials: credentials,
        client: client,
      );
      addTearDown(remote.close);
      const body = '{"action":"list","limit":1}';
      await remote.request('alice', body);
      expect(bodies, [body, body]);
      expect(credentials.refreshes, 1);
      credentials.uid = 'bob';
      await expectLater(
        remote.request('alice', body),
        throwsA(isA<SyncFailure>()),
      );
      expect(bodies, hasLength(2));
    },
  );
  test(
    'server rate backoff is durable and does not block new offline learning',
    () async {
      final db = await pendingStore();
      addTearDown(db.close);
      final remote = FakeProgressRemote()
        ..failure = const SyncFailure(
          'rate-limited',
          retryable: true,
          retryAfter: Duration(seconds: 60),
        );
      final sync = engine(db, remote);
      addTearDown(sync.dispose);
      await sync.sync();
      await sync.sync();
      expect(remote.bodies, hasLength(1));
      expect((await db.syncView('alice')).nextRetry, isNotNull);
      await db.swipe('alice', 'b', true);
      expect(await db.pendingCount('alice'), 2);
    },
  );
}
