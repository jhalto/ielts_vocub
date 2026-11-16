part of '../local_learning.dart';

const _unresolved = "'pending','inflight','conflict','rejected'";

extension ProgressStore on LearningStore {
  Future<void> _createSyncSchema() async {
    for (final sql in [
      'ALTER TABLE pending_sync_operations ADD COLUMN request_payload TEXT',
      'ALTER TABLE pending_sync_operations ADD COLUMN supersedes_operation_id TEXT',
      'CREATE TABLE remote_progress(uid TEXT NOT NULL,word_id TEXT NOT NULL,status TEXT NOT NULL,revision INTEGER NOT NULL,last_operation_id TEXT NOT NULL,PRIMARY KEY(uid,word_id))',
      'CREATE TABLE progress_staging(uid TEXT NOT NULL,run_id TEXT NOT NULL,word_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(uid,run_id,word_id))',
      "CREATE TABLE sync_status(uid TEXT PRIMARY KEY,phase TEXT NOT NULL DEFAULT 'pending',remote_revision INTEGER NOT NULL DEFAULT 0,last_success TEXT,last_error TEXT,next_retry TEXT,automatic INTEGER NOT NULL DEFAULT 0 CHECK(automatic IN (0,1)))",
      'CREATE INDEX pending_word ON pending_sync_operations(uid,word_id,sequence)',
    ]) {
      await customStatement(sql);
    }
  }

  void _syncGuard(bool Function() active) {
    if (!active()) throw const SyncFailure('account-changed');
  }

  bool syncRunning(String uid) => _syncFlights.containsKey(uid);
  Future<void> singleSync(String uid, Future<void> Function() action) {
    final running = _syncFlights[uid];
    if (running != null) return running;
    final done = Completer<void>();
    _syncFlights[uid] = done.future;
    unawaited(() async {
      try {
        await action();
        done.complete();
      } catch (e, s) {
        done.completeError(e, s);
      } finally {
        if (identical(_syncFlights[uid], done.future)) _syncFlights.remove(uid);
      }
    }());
    return done.future;
  }

  Future<SyncView> syncView(String uid) async {
    final states = await rows('SELECT * FROM sync_status WHERE uid=?', [uid]);
    final state = states.isEmpty ? <String, dynamic>{} : states.single;
    final count = await pendingCount(uid);
    final issues =
        (await rows(
              "SELECT COUNT(DISTINCT word_id) AS count FROM pending_sync_operations WHERE uid=? AND state IN ('conflict','rejected')",
              [uid],
            )).single['count']
            as int;
    var phase = state['phase'] as String? ?? 'pending';
    if (phase != 'syncing' && phase != 'failed' && phase != 'offline') {
      phase = issues > 0
          ? 'conflict'
          : count > 0
          ? 'pending'
          : state['last_success'] != null
          ? 'synced'
          : 'pending';
    }
    return SyncView(
      phase,
      count,
      issues,
      DateTime.tryParse(state['last_success'] as String? ?? ''),
      state['last_error'] as String?,
      DateTime.tryParse(state['next_retry'] as String? ?? ''),
      state['automatic'] == 1,
    );
  }

  Future<void> setSyncPhase(
    String uid,
    String phase, {
    String? error,
    DateTime? nextRetry,
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    await customStatement(
      'INSERT INTO sync_status(uid,phase,last_error,next_retry) VALUES(?,?,?,?) ON CONFLICT(uid) DO UPDATE SET phase=excluded.phase,last_error=excluded.last_error,next_retry=excluded.next_retry',
      [uid, phase, error, nextRetry?.toUtc().toIso8601String()],
    );
    if (phase == 'synced') {
      await customStatement(
        'UPDATE sync_status SET last_success=? WHERE uid=?',
        [DateTime.now().toUtc().toIso8601String(), uid],
      );
    }
    _syncGuard(active);
  });
  Future<void> setAutomaticSync(
    String uid,
    bool enabled, {
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    await customStatement(
      'INSERT INTO sync_status(uid,automatic) VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET automatic=excluded.automatic',
      [uid, enabled ? 1 : 0],
    );
    _syncGuard(active);
  });
  Future<List<Map<String, dynamic>>> prepareSync(
    String uid, {
    required int limit,
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    final selected = (await rows(
      "SELECT o.* FROM pending_sync_operations o WHERE o.uid=? AND o.state IN ('pending','inflight') AND NOT EXISTS(SELECT 1 FROM pending_sync_operations p WHERE p.uid=o.uid AND p.word_id=o.word_id AND p.sequence<o.sequence AND p.state IN ($_unresolved)) ORDER BY o.sequence LIMIT ?",
      [uid, limit],
    )).map((row) => Map<String, dynamic>.from(row)).toList();
    for (final op in selected) {
      final payload =
          op['request_payload'] as String? ??
          jsonEncode({
            'operationId': op['operation_id'],
            'deviceId': op['device_id'],
            'wordId': op['word_id'],
            'desiredStatus': op['desired_status'],
            'baseRevision': op['base_revision'],
            'sequence': op['sequence'],
            if (op['supersedes_operation_id'] != null)
              'supersedesOperationId': op['supersedes_operation_id'],
          });
      await customStatement(
        "UPDATE pending_sync_operations SET request_payload=?,state='inflight' WHERE uid=? AND operation_id=?",
        [payload, uid, op['operation_id']],
      );
      op['request_payload'] = payload;
    }
    _syncGuard(active);
    return selected;
  });
  Future<void> recordSyncAttempt(
    String uid,
    List<Map<String, dynamic>> ops, {
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    for (final op in ops) {
      await customStatement(
        'UPDATE pending_sync_operations SET retry_count=retry_count+1 WHERE uid=? AND operation_id=?',
        [uid, op['operation_id']],
      );
    }
    _syncGuard(active);
  });
  Future<void> _shadow(String uid, Map<String, dynamic> p) => customStatement(
    'INSERT INTO remote_progress VALUES(?,?,?,?,?) ON CONFLICT(uid,word_id) DO UPDATE SET status=excluded.status,revision=excluded.revision,last_operation_id=excluded.last_operation_id WHERE excluded.revision>remote_progress.revision',
    [uid, p['wordId'], p['status'], p['revision'], p['lastOperationId']],
  );

  Future<void> recordSyncFailure(
    String uid,
    List<Map<String, dynamic>> ops,
    String code, {
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    for (final op in ops) {
      await customStatement(
        "UPDATE pending_sync_operations SET last_error=? WHERE uid=? AND operation_id=? AND state='inflight'",
        [code, uid, op['operation_id']],
      );
    }
    _syncGuard(active);
  });

  Future<void> acceptSync(
    String uid,
    List<Map<String, dynamic>> ops,
    Map<String, dynamic> response, {
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    if (response['schemaVersion'] != 1 ||
        response['results'] is! List ||
        (response['results'] as List).length != ops.length) {
      throw const SyncFailure('invalid-response');
    }
    final results = response['results'] as List;
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i], result = results[i];
      if (result is! Map<String, dynamic> ||
          result['operationId'] != op['operation_id'] ||
          result['wordId'] != op['word_id'] ||
          result['replayed'] is! bool ||
          ![
            'applied',
            'revision-conflict',
            'word-unavailable',
            'invalid-rebase',
            'operation-id-reused',
          ].contains(result['code'])) {
        throw const SyncFailure('invalid-response');
      }
      final p = result['progress'] == null
          ? null
          : syncProgress(result['progress']);
      if (p != null && p['wordId'] != op['word_id']) {
        throw const SyncFailure('invalid-response');
      }
      final applied = result['code'] == 'applied';
      if (applied &&
          (p == null ||
              p['lastOperationId'] != op['operation_id'] ||
              p['status'] != op['desired_status'] ||
              (p['revision'] as int) <= (op['base_revision'] as int))) {
        throw const SyncFailure('invalid-response');
      }
      // An acknowledgement is tied to the exact persisted request, not just a word.
      final current = await rows(
        'SELECT * FROM pending_sync_operations WHERE uid=? AND operation_id=?',
        [uid, op['operation_id']],
      );
      if (current.isEmpty ||
          current.single['request_payload'] != op['request_payload'] ||
          current.single['state'] != 'inflight') {
        throw const SyncFailure('operation-changed');
      }
      if (p != null) await _shadow(uid, p);
      await customStatement(
        'UPDATE pending_sync_operations SET state=?,last_error=? WHERE uid=? AND operation_id=?',
        [
          applied
              ? 'applied'
              : result['code'] == 'revision-conflict'
              ? 'conflict'
              : 'rejected',
          applied ? null : result['code'],
          uid,
          op['operation_id'],
        ],
      );
      if (p != null) {
        await customStatement(
          'UPDATE user_progress SET server_revision=MAX(server_revision,?) WHERE uid=? AND word_id=?',
          [p['revision'], uid, op['word_id']],
        );
      }
      if (result['code'] == 'word-unavailable') {
        await _bumpContentGeneration();
        await customStatement('UPDATE words SET published=0 WHERE id=?', [
          op['word_id'],
        ]);
        await customStatement(
          'DELETE FROM learning_queue_items WHERE word_id=?',
          [op['word_id']],
        );
        await customStatement(
          'UPDATE downloaded_groups SET complete=0 WHERE (category,difficulty) IN (SELECT category,difficulty FROM words WHERE id=?)',
          [op['word_id']],
        );
      }
    }
    await _materialize(uid);
    _syncGuard(active);
  });
  Future<void> stageProgress(
    String uid,
    String run,
    List<Map<String, dynamic>> records, {
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    for (final record in records) {
      await customStatement('INSERT INTO progress_staging VALUES(?,?,?,?)', [
        uid,
        run,
        record['wordId'],
        jsonEncode(record),
      ]);
    }
    _syncGuard(active);
  });
  Future<void> discardProgress(String uid, String run) => customStatement(
    'DELETE FROM progress_staging WHERE uid=? AND run_id=?',
    [uid, run],
  );
  Future<void> commitProgress(
    String uid,
    String run,
    int revision, {
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    final prior = await rows(
      'SELECT remote_revision FROM sync_status WHERE uid=?',
      [uid],
    );
    final maximum =
        (await rows(
              'SELECT MAX(revision) AS revision FROM remote_progress WHERE uid=?',
              [uid],
            )).single['revision']
            as int? ??
        0;
    if ((prior.isNotEmpty &&
            revision < (prior.single['remote_revision'] as int)) ||
        revision < maximum) {
      throw const SyncFailure('progress-revision-rollback');
    }
    final missing = await rows(
      'SELECT word_id FROM remote_progress r WHERE uid=? AND NOT EXISTS(SELECT 1 FROM progress_staging s WHERE s.uid=r.uid AND s.run_id=? AND s.word_id=r.word_id) LIMIT 1',
      [uid, run],
    );
    if (missing.isNotEmpty) {
      throw const SyncFailure('snapshot-missing-progress');
    }
    final staged = await rows(
      'SELECT payload FROM progress_staging WHERE uid=? AND run_id=?',
      [uid, run],
    );
    for (final record in staged) {
      await _shadow(uid, syncProgress(jsonDecode(record['payload'] as String)));
    }
    await _materialize(uid);
    await customStatement(
      'INSERT INTO sync_status(uid,remote_revision) VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET remote_revision=excluded.remote_revision',
      [uid, revision],
    );
    await discardProgress(uid, run);
    _syncGuard(active);
  });
  Future<void> _materialize(String uid) async {
    final time = DateTime.now().toUtc().toIso8601String();
    await customStatement(
      "INSERT INTO user_progress(uid,word_id,status,server_revision,created_at,updated_at) SELECT r.uid,r.word_id,r.status,r.revision,?,? FROM remote_progress r JOIN words w ON w.id=r.word_id WHERE r.uid=? AND NOT EXISTS(SELECT 1 FROM pending_sync_operations o WHERE o.uid=r.uid AND o.word_id=r.word_id AND o.state IN ($_unresolved)) ON CONFLICT(uid,word_id) DO UPDATE SET status=excluded.status,server_revision=excluded.server_revision,updated_at=excluded.updated_at WHERE excluded.server_revision>=user_progress.server_revision",
      [time, time, uid],
    );
    await customStatement(
      "DELETE FROM learning_queue_items WHERE session_id IN (SELECT id FROM learning_sessions WHERE uid=?) AND EXISTS(SELECT 1 FROM learning_sessions s JOIN user_progress p ON p.uid=s.uid AND p.word_id=learning_queue_items.word_id WHERE s.id=learning_queue_items.session_id AND ((s.review IS NULL AND p.status IN ('learned','already_know')) OR (s.review IS NOT NULL AND p.status<>s.review)))",
      [uid],
    );
    await customStatement(
      'UPDATE learning_sessions SET waiting=0 WHERE uid=? AND NOT EXISTS(SELECT 1 FROM learning_queue_items q WHERE q.session_id=learning_sessions.id)',
      [uid],
    );
  }

  Future<void> materializeProgress(
    String uid, {
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    await _materialize(uid);
    _syncGuard(active);
  });

  Future<List<Map<String, dynamic>>> syncIssues(String uid) => rows(
    "SELECT o.*,(SELECT json_extract(w.payload,'\$.spelling') FROM words w WHERE w.id=o.word_id) AS spelling,(SELECT operation_id FROM pending_sync_operations n WHERE n.uid=o.uid AND n.word_id=o.word_id AND n.state IN ($_unresolved) ORDER BY sequence DESC LIMIT 1) AS latest_operation_id,(SELECT status FROM user_progress p WHERE p.uid=o.uid AND p.word_id=o.word_id) AS local_status,(SELECT status FROM remote_progress p WHERE p.uid=o.uid AND p.word_id=o.word_id) AS remote_status FROM pending_sync_operations o WHERE o.uid=? AND o.state IN ('conflict','rejected') ORDER BY o.sequence",
    [uid],
  );
  Future<void> resolveSync(
    String uid,
    String wordId,
    String expectedLocalId, {
    required bool keepLocal,
    required bool Function() active,
  }) => transaction(() async {
    _syncGuard(active);
    final activeOps = await rows(
      "SELECT * FROM pending_sync_operations WHERE uid=? AND word_id=? AND state IN ($_unresolved) ORDER BY sequence",
      [uid, wordId],
    );
    if (activeOps.isEmpty ||
        activeOps.last['operation_id'] != expectedLocalId ||
        !['conflict', 'rejected'].contains(activeOps.first['state']) ||
        activeOps.any((op) => op['state'] == 'inflight')) {
      throw const SyncFailure('local-intent-changed');
    }
    final remote = await rows(
      'SELECT * FROM remote_progress WHERE uid=? AND word_id=?',
      [uid, wordId],
    );
    final latest = activeOps.last;
    if (keepLocal) {
      final available = await rows('SELECT published FROM words WHERE id=?', [
        wordId,
      ]);
      if (available.isEmpty || available.single['published'] != 1) {
        throw const SyncFailure('refresh-published-content-first');
      }
    }
    await customStatement(
      "UPDATE pending_sync_operations SET state='superseded',last_error=? WHERE uid=? AND word_id=? AND state IN ($_unresolved)",
      [
        keepLocal ? 'explicit-local-rebase' : 'explicit-server-choice',
        uid,
        wordId,
      ],
    );
    if (keepLocal) {
      await customStatement(
        'INSERT INTO local_sequences VALUES(?,1) ON CONFLICT(uid) DO UPDATE SET sequence=sequence+1',
        [uid],
      );
      final sequence = (await rows(
        'SELECT sequence FROM local_sequences WHERE uid=?',
        [uid],
      )).single['sequence'];
      await customStatement(
        'INSERT INTO pending_sync_operations(operation_id,uid,word_id,desired_status,base_revision,sequence,created_at,device_id,supersedes_operation_id) VALUES(?,?,?,?,?,?,?,?,?)',
        [
          newId(),
          uid,
          wordId,
          latest['desired_status'],
          remote.isEmpty ? 0 : remote.single['revision'],
          sequence,
          DateTime.now().toUtc().toIso8601String(),
          latest['device_id'],
          activeOps.first['state'] == 'conflict'
              ? activeOps.first['operation_id']
              : null,
        ],
      );
    }
    if (!keepLocal && remote.isEmpty) {
      await customStatement(
        'DELETE FROM user_progress WHERE uid=? AND word_id=?',
        [uid, wordId],
      );
    }
    await _materialize(uid);
    _syncGuard(active);
  });
}
