// Invoked only by the guarded demo-emulator fixture; never opens app storage.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:local_learning/local_learning.dart';

class Credentials implements ProgressCredentials {
  Credentials(this.uid, this.value);
  @override
  String? uid;
  final String value;
  @override
  Future<String> token(bool refresh) async => value;
}

class InterceptRemote implements ProgressRemote {
  InterceptRemote(this.inner, this.intercept);
  final ProgressRemote inner;
  final Future<void> Function(Map<String, dynamic>) intercept;
  @override
  Future<Map<String, dynamic>> request(String uid, String body) async {
    final result = await inner.request(uid, body);
    await intercept(jsonDecode(body) as Map<String, dynamic>);
    return result;
  }

  @override
  void close() => inner.close();
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final fixture = jsonDecode(
    await stdin.transform(utf8.decoder).join(),
  ) as Map<String, dynamic>;
  final endpoint = Uri.parse(fixture['endpoint'] as String);
  if (fixture['projectId'] != 'demo-vocabulary' ||
      endpoint.scheme != 'http' ||
      endpoint.host != '127.0.0.1' ||
      !endpoint.path.startsWith('/demo-vocabulary/')) {
    throw StateError('Demo emulator fixture required');
  }
  final uid = fixture['uid'] as String;
  final words = (fixture['words'] as List)
      .map((w) => VocabularyWord.fromJson(Map<String, dynamic>.from(w as Map)))
      .toList();
  final manifest = ContentSnapshot.fromJson(
    Map<String, dynamic>.from(fixture['manifest'] as Map),
  );
  final directory = await Directory.systemTemp.createTemp(
    'progress-client-emulator-',
  );
  final aFile = File('${directory.path}/a.sqlite'),
      bFile = File('${directory.path}/b.sqlite');
  var a = LearningStore(NativeDatabase(aFile)),
      b = LearningStore(NativeDatabase(bFile));
  final liveEngines = <ProgressSynchronizer>[];
  ProgressRemote remote({bool bob = false}) => HttpProgressRemote(
    endpoint: endpoint,
    credentials: Credentials(
      bob ? fixture['bobUid'] as String : uid,
      bob ? fixture['bobToken'] as String : fixture['token'] as String,
    ),
  );
  ProgressSynchronizer sync(
    LearningStore db, {
    ProgressRemote? transport,
    String? owner,
  }) {
    final value = ProgressSynchronizer(
      store: db,
      uid: owner ?? uid,
      remote: transport ?? remote(),
      stillAuthorized: () => true,
      pageSize: 1,
      delay: (_) async {},
    );
    liveEngines.add(value);
    return value;
  }

  Future<void> seed(LearningStore db) async {
    final id = newId();
    await db.stage(id, words);
    await db.commitDownload(id, null, manifest.revision, manifest.groupCounts);
  }

  Future<String> status(LearningStore db) async =>
      (await db.rows(
            'SELECT status FROM user_progress WHERE uid=? AND word_id=?',
            [uid, 'client-a'],
          )).single['status']
          as String;
  Future<void> swipeA(LearningStore db, bool right) async {
    final current = ProgressStatus.parse(await status(db));
    await db.startSession(
      uid,
      Category.basic,
      Difficulty.easy,
      review: current,
    );
    await db.swipe(uid, 'client-a', right);
  }

  try {
    await seed(a);
    await seed(b);
    for (final db in [a, b]) {
      await db.startSession(uid, Category.basic, Difficulty.easy);
    }
    await a.swipe(uid, 'client-a', false);
    await b.swipe(uid, 'client-a', true);
    var aSync = sync(a), bSync = sync(b);
    await Future.wait([aSync.sync(), bSync.sync()]);
    final aLost = (await a.syncView(uid)).issues == 1;
    check(
      (await a.syncView(uid)).issues + (await b.syncView(uid)).issues == 1,
      'Two devices must produce one explicit conflict',
    );
    var loser = aLost ? a : b;
    final loserSync = aLost ? aSync : bSync;
    final original = (await loser.syncIssues(uid)).single;
    final desired = original['local_status'];
    await loserSync.resolve(
      'client-a',
      original['latest_operation_id'] as String,
      keepLocal: true,
    );
    loserSync.dispose();
    await loser.close();
    loser = LearningStore(NativeDatabase(aLost ? aFile : bFile));
    if (aLost) {
      a = loser;
      aSync = sync(a);
    } else {
      b = loser;
      bSync = sync(b);
    }
    await (aLost ? aSync : bSync).sync();
    await (aLost ? bSync : aSync).sync();
    check(
      await status(a) == desired && await status(b) == desired,
      'Durable explicit rebase must converge both devices',
    );
    check(
      await a.pendingCount(uid) == 0 && await b.pendingCount(uid) == 0,
      'Rebase must acknowledge matching operations',
    );

    // Lose every response after the real server has committed, then restart.
    await swipeA(a, false);
    aSync.dispose();
    aSync = sync(
      a,
      transport: InterceptRemote(remote(), (input) async {
        if (input['action'] == 'upload') {
          throw const SyncFailure('offline', retryable: true);
        }
      }),
    );
    await aSync.sync();
    final pending = (await a.rows(
      "SELECT * FROM pending_sync_operations WHERE state='inflight'",
    )).single;
    check(
      (await a.syncView(uid)).phase == 'offline',
      'Lost acknowledgement must remain pending',
    );
    aSync.dispose();
    await a.close();
    a = LearningStore(NativeDatabase(aFile));
    aSync = sync(a);
    await aSync.sync();
    final retried = (await a.rows(
      'SELECT * FROM pending_sync_operations WHERE operation_id=?',
      [pending['operation_id']],
    )).single;
    check(
      retried['state'] == 'applied' &&
          retried['request_payload'] == pending['request_payload'],
      'Retry after restart must preserve exact operation payload',
    );

    // A newer local swipe is committed after the older real HTTP acknowledgement
    // arrives, but before the client can apply it to SQLite.
    await swipeA(a, true);
    aSync.dispose();
    var newer = false;
    aSync = sync(
      a,
      transport: InterceptRemote(remote(), (input) async {
        if (input['action'] == 'upload' && !newer) {
          newer = true;
          await swipeA(a, false);
        }
      }),
    );
    await aSync.sync();
    check(
      await status(a) == 'didnt_know',
      'Older acknowledgement must not overwrite a newer swipe',
    );
    final issue = (await a.syncIssues(uid)).single;
    await aSync.resolve(
      'client-a',
      issue['latest_operation_id'] as String,
      keepLocal: false,
    );
    await aSync.sync();
    check(
      await status(a) == 'learned',
      'Explicit server choice must reconcile safely',
    );

    await bSync.sync();
    await b.startSession(uid, Category.basic, Difficulty.easy);
    await b.swipe(uid, 'client-b', true);
    await b.swipe(uid, 'client-c', false);
    await bSync.sync();
    aSync.dispose();
    var changed = false;
    aSync = sync(
      a,
      transport: InterceptRemote(remote(), (input) async {
        if (input['action'] == 'list' && !changed) {
          changed = true;
          await swipeA(b, false);
          await bSync.sync();
        }
      }),
    );
    await aSync.sync();
    check(
      (await a.syncView(uid)).phase == 'synced',
      'Pagination restart must eventually commit a complete snapshot',
    );
    check(
      (await a.rows('SELECT * FROM remote_progress WHERE uid=?', [
            uid,
          ])).length ==
          3,
      'All remote pages must be materialized',
    );

    final oldShadow = await a.rows(
      'SELECT * FROM remote_progress WHERE uid=? ORDER BY word_id',
      [uid],
    );
    await swipeA(b, true);
    await bSync.sync();
    aSync.dispose();
    aSync = sync(
      a,
      transport: InterceptRemote(remote(), (input) async {
        if (input['action'] == 'list' && input['cursor'] != null) {
          throw const SyncFailure('offline');
        }
      }),
    );
    await aSync.sync();
    final unchanged = await a.rows(
      'SELECT * FROM remote_progress WHERE uid=? ORDER BY word_id',
      [uid],
    );
    check(
      jsonEncode(oldShadow) == jsonEncode(unchanged),
      'Interrupted pagination must not apply partial pages',
    );
    aSync.dispose();
    aSync = sync(a);
    await aSync.sync();

    final bobUid = fixture['bobUid'] as String;
    final bobSync = sync(a, owner: bobUid, transport: remote(bob: true));
    await bobSync.sync();
    check(
      (await a.statistics(
            bobUid,
            Category.basic,
            Difficulty.easy,
          ))['unmarked'] ==
          3,
      'Incoming account must not see prior progress',
    );
    check(
      await a.pendingCount(bobUid) == 0 && await a.session(bobUid) == null,
      'UID private state must remain isolated',
    );

    await swipeA(a, false);
    aSync.dispose();
    aSync = sync(
      a,
      transport: InterceptRemote(remote(), (input) async {
        if (input['action'] == 'upload') await a.clearPrivate(uid);
      }),
    );
    await aSync.sync();
    check(
      (await a.rows('SELECT * FROM user_progress WHERE uid=?', [uid])).isEmpty,
      'Late acknowledgement must not recreate logged-out progress',
    );
    check(
      (await a.rows('SELECT * FROM sync_status WHERE uid=?', [uid])).isEmpty,
      'Late acknowledgement must not recreate logged-out metadata',
    );
    check(
      (await a.rows('SELECT * FROM sync_status WHERE uid=?', [
            bobUid,
          ])).length ==
          1,
      'Logout must preserve incoming account data',
    );
    stdout.writeln(
      'PASS: real HTTPS client + temporary Drift databases: two-device conflict/rebase, restart, lost ACK, newer swipe, pagination restart/interruption and logout/UID isolation.',
    );
  } finally {
    for (final value in liveEngines) {
      value.dispose();
    }
    await a.close();
    await b.close();
    await directory.delete(recursive: true);
  }
}
