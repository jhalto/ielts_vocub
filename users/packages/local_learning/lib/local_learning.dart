import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:drift/drift.dart';
import 'package:shared_models/shared_models.dart';

import 'src/progress_sync.dart';
import 'src/content_sync.dart';

export 'package:shared_models/shared_models.dart';

export 'src/progress_sync.dart';
export 'src/content_sync.dart';

part 'src/progress_store.dart';
part 'src/content_store.dart';

String newId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
ProgressStatus swipeStatus(ProgressStatus? current, bool right) => !right
    ? ProgressStatus.didntKnow
    : switch (current) {
        null => ProgressStatus.alreadyKnow,
        ProgressStatus.didntKnow => ProgressStatus.learned,
        _ => current,
      };

/// Drift owns all operational reads/writes. JSON is a lossless nested content
/// representation; indexed group/search columns avoid Firestore reads offline.
class LearningStore extends GeneratedDatabase {
  LearningStore(super.executor);
  final Map<String, int> _privateEpochs = {};
  final Map<String, Future<void>> _syncFlights = {};
  Future<void>? _contentFlight;
  int privateEpoch(String uid) => _privateEpochs[uid] ?? 0;
  @override
  int get schemaVersion => 3;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in schema) {
        await customStatement(sql);
      }
      await _createSyncSchema();
      await _createContentSchema();
      await customStatement('INSERT INTO local_metadata VALUES(?,?)', [
        'device_id',
        newId(),
      ]);
    },
    onUpgrade: (_, from, to) async {
      if ((from != 1 && from != 2) || to != 3) {
        throw StateError('Unsupported migration $from -> $to');
      }
      await transaction(() async {
        if (from == 1) await _createSyncSchema();
        await _createContentSchema();
      });
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA secure_delete = ON');
      // Cancelled/crashed snapshots restart; staged rows never become published.
      await customStatement('DELETE FROM download_staging');
      await customStatement('DELETE FROM progress_staging');
      await customStatement('DELETE FROM content_delta_staging');
      await customStatement(
        "UPDATE sync_status SET phase='failed',last_error='sync-interrupted' WHERE phase='syncing'",
      );
    },
  );
  static const schema = [
    'CREATE TABLE words(id TEXT PRIMARY KEY, category TEXT NOT NULL, difficulty TEXT NOT NULL, ordering INTEGER NOT NULL, revision INTEGER NOT NULL, published INTEGER NOT NULL CHECK(published IN (0,1)), payload TEXT NOT NULL, searchable TEXT NOT NULL)',
    'CREATE INDEX word_group ON words(category,difficulty,published,ordering,id)',
    'CREATE TABLE downloaded_groups(category TEXT NOT NULL,difficulty TEXT NOT NULL,revision INTEGER NOT NULL,complete INTEGER NOT NULL CHECK(complete IN (0,1)),updated_at TEXT NOT NULL,PRIMARY KEY(category,difficulty))',
    'CREATE TABLE download_staging(download_id TEXT NOT NULL,word_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(download_id,word_id))',
    "CREATE TABLE user_progress(uid TEXT NOT NULL,word_id TEXT NOT NULL REFERENCES words(id),status TEXT NOT NULL CHECK(status IN ('already_know','learned','didnt_know')),server_revision INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(uid,word_id))",
    'CREATE TABLE local_sequences(uid TEXT PRIMARY KEY,sequence INTEGER NOT NULL)',
    'CREATE TABLE local_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
    "CREATE TABLE pending_sync_operations(operation_id TEXT PRIMARY KEY,uid TEXT NOT NULL,word_id TEXT NOT NULL REFERENCES words(id),desired_status TEXT NOT NULL CHECK(desired_status IN ('already_know','learned','didnt_know')),base_revision INTEGER NOT NULL,sequence INTEGER NOT NULL,created_at TEXT NOT NULL,device_id TEXT NOT NULL,retry_count INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL DEFAULT 'pending',last_error TEXT,UNIQUE(uid,sequence))",
    'CREATE INDEX pending_uid ON pending_sync_operations(uid,sequence)',
    'CREATE TABLE learning_sessions(id TEXT PRIMARY KEY,uid TEXT NOT NULL UNIQUE,category TEXT NOT NULL,difficulty TEXT NOT NULL,review TEXT,waiting INTEGER NOT NULL DEFAULT 0,outcomes TEXT NOT NULL)',
    'CREATE TABLE learning_queue_items(session_id TEXT NOT NULL REFERENCES learning_sessions(id) ON DELETE CASCADE,word_id TEXT NOT NULL REFERENCES words(id),position INTEGER NOT NULL,PRIMARY KEY(session_id,word_id),UNIQUE(session_id,position))',
  ];
  Future<List<Map<String, dynamic>>> rows(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    // SQL is static at call sites; only values are bound.
    final result = await customSelect(
      sql,
      variables: args
          .map<Variable>(
            (v) => switch (v) {
              int value => Variable<int>(value),
              String value => Variable<String>(value),
              null => const Variable<String>(null),
              _ => throw ArgumentError('Unsupported SQL value'),
            },
          )
          .toList(),
    ).get();
    return result.map((r) => r.data).toList();
  }

  Future<void> stage(String downloadId, List<VocabularyWord> words) =>
      transaction(() async {
        for (final word in words) {
          // Constructors also serve tests/editors; validate the persisted wire payload.
          VocabularyWord.fromJson(word.toJson());
          if (!word.isPublished || word.isRetired) {
            throw const FormatException('Only published words may be cached');
          }
          await customStatement('INSERT INTO download_staging VALUES(?,?,?)', [
            downloadId,
            word.id,
            jsonEncode(word.toJson()),
          ]);
        }
      });
  Future<void> discard(String downloadId) => customStatement(
    'DELETE FROM download_staging WHERE download_id=?',
    [downloadId],
  );
  Future<void> commitDownload(
    String downloadId,
    Category? category,
    int revision,
    Map<String, int> expectedCounts, {
    bool Function()? stillWanted,
    Set<Category>? scopes,
    bool trustedManifest = false,
    int? expectedGeneration,
  }) => transaction(() async {
    void checkWanted() {
      if (stillWanted != null && !stillWanted()) {
        throw StateError('Download cancelled. Existing content is preserved.');
      }
    }

    checkWanted();
    if (expectedGeneration != null &&
        await contentGeneration() != expectedGeneration) {
      throw const ContentFailure('content-local-changed', retryable: true);
    }
    ContentSnapshot(revision, expectedCounts).validate(category);
    final versions = await rows(
      'SELECT MAX(revision) AS version FROM downloaded_groups',
    );
    if ((versions.single['version'] as int? ?? 0) > revision) {
      throw StateError('Server content revision rolled back');
    }
    final staged = await rows(
      'SELECT payload FROM download_staging WHERE download_id=?',
      [downloadId],
    );
    final words = staged
        .map(
          (r) => VocabularyWord.fromJson(
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
    if (words.any(
      (w) => !w.isPublished || w.isRetired || w.revision > revision,
    )) {
      throw StateError('Invalid staged publication');
    }
    final categories =
        scopes?.toList() ?? (category == null ? Category.values : [category]);
    if (categories.isEmpty) throw StateError('No download scope');
    for (final cat in categories) {
      for (final difficulty in Difficulty.values) {
        final key = '${cat.name}/${difficulty.name}';
        if (expectedCounts[key] !=
            words
                .where((w) => w.category == cat && w.difficulty == difficulty)
                .length) {
          throw StateError('Snapshot group count mismatch');
        }
      }
    }
    if (words.any((w) => !categories.contains(w.category))) {
      throw StateError('Wrong download category');
    }
    // New snapshots invalidate previous-version completeness until redownloaded.
    await customStatement(
      'UPDATE downloaded_groups SET complete=0 WHERE revision<>?',
      [revision],
    );
    await customStatement(
      'UPDATE words SET published=0 WHERE category IN (${List.filled(categories.length, '?').join(',')})',
      categories.map((c) => c.name).toList(),
    );
    for (final word in words) {
      await _putContentWord(word);
    }
    for (final cat in categories) {
      for (final d in Difficulty.values) {
        await customStatement(
          'INSERT OR REPLACE INTO downloaded_groups VALUES(?,?,?,?,?)',
          [
            cat.name,
            d.name,
            revision,
            1,
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
      }
    }
    for (final cat in categories) {
      if (trustedManifest) {
        await customStatement(
          'INSERT INTO content_checkpoints VALUES(?,?) ON CONFLICT(category) DO UPDATE SET revision=excluded.revision',
          [cat.name, revision],
        );
      } else {
        await customStatement(
          'DELETE FROM content_checkpoints WHERE category=?',
          [cat.name],
        );
      }
    }
    await _bumpContentGeneration();
    await discard(downloadId);
    // Retired/moved words no longer belong in active queues. History remains.
    await customStatement(
      'DELETE FROM learning_queue_items WHERE word_id IN (SELECT w.id FROM words w JOIN learning_sessions s ON s.id=learning_queue_items.session_id WHERE w.published=0 OR w.category<>s.category OR w.difficulty<>s.difficulty)',
    );
    await customStatement(
      'UPDATE learning_sessions SET waiting=0 WHERE NOT EXISTS(SELECT 1 FROM learning_queue_items q WHERE q.session_id=learning_sessions.id)',
    );
    // Cancellation/account changes while SQLite was awaiting a write roll back
    // words, completeness, queue pruning and staging removal together.
    checkWanted();
  });
  Future<List<VocabularyWord>> browse({
    required Category category,
    required Difficulty difficulty,
    String search = '',
    String? uid,
    ProgressStatus? status,
    PartOfSpeech? partOfSpeech,
    bool unmarkedOnly = false,
    int offset = 0,
  }) async {
    final result = await rows(
      r"SELECT w.payload FROM words w LEFT JOIN user_progress p ON p.word_id=w.id AND p.uid=? WHERE w.published=1 AND w.category=? AND w.difficulty=? AND instr(w.searchable,?)>0 AND (? IS NULL OR p.status=?) AND (?=0 OR p.status IS NULL) AND (? IS NULL OR EXISTS(SELECT 1 FROM json_each(w.payload,'$.senses') s WHERE json_extract(s.value,'$.partOfSpeech')=?)) ORDER BY w.ordering,w.id LIMIT 50 OFFSET ?",
      [
        uid ?? '',
        category.name,
        difficulty.name,
        search.trim().toLowerCase(),
        status?.wireValue,
        status?.wireValue,
        unmarkedOnly ? 1 : 0,
        partOfSpeech?.name,
        partOfSpeech?.name,
        offset,
      ],
    );
    return result
        .map(
          (r) => VocabularyWord.fromJson(
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  Future<Map<String, int>> statistics(
    String? uid,
    Category category,
    Difficulty difficulty,
  ) async {
    final result = await rows(
      "SELECT COALESCE(p.status,'unmarked') AS status,COUNT(*) AS count FROM words w LEFT JOIN user_progress p ON p.word_id=w.id AND p.uid=? WHERE w.published=1 AND w.category=? AND w.difficulty=? GROUP BY p.status",
      [uid ?? '', category.name, difficulty.name],
    );
    return {for (final r in result) r['status'] as String: r['count'] as int};
  }

  Future<List<Map<String, dynamic>>> downloads() =>
      rows('SELECT * FROM downloaded_groups ORDER BY category,difficulty');
  Future<int> pendingCount(String uid) async =>
      (await rows(
            "SELECT COUNT(*) AS count FROM pending_sync_operations WHERE uid=? AND state IN ('pending','inflight','conflict','rejected')",
            [uid],
          )).single['count']
          as int;
  Future<void> clearPrivate(String uid) {
    _privateEpochs[uid] = privateEpoch(uid) + 1;
    return transaction(() async {
      for (final table in [
        'learning_sessions',
        'pending_sync_operations',
        'user_progress',
        'local_sequences',
        'remote_progress',
        'progress_staging',
        'sync_status',
      ]) {
        await customStatement('DELETE FROM $table WHERE uid=?', [uid]);
      }
    });
  }

  Future<void> startSession(
    String uid,
    Category category,
    Difficulty difficulty, {
    ProgressStatus? review,
    bool Function()? stillAuthorized,
  }) => transaction(() async {
    if (uid.trim().isEmpty) throw StateError('Sign in before saving progress');
    if (stillAuthorized != null && !stillAuthorized()) {
      throw StateError('Account changed');
    }
    final result = await rows(
      "SELECT w.id FROM words w LEFT JOIN user_progress p ON p.word_id=w.id AND p.uid=? WHERE w.published=1 AND w.category=? AND w.difficulty=? AND ((? IS NULL AND (p.status IS NULL OR p.status='didnt_know')) OR p.status=?) ORDER BY w.ordering,w.id",
      [
        uid,
        category.name,
        difficulty.name,
        review?.wireValue,
        review?.wireValue,
      ],
    );
    await customStatement('DELETE FROM learning_sessions WHERE uid=?', [uid]);
    final id = newId();
    await customStatement(
      'INSERT INTO learning_sessions(id,uid,category,difficulty,review,outcomes) VALUES(?,?,?,?,?,?)',
      [id, uid, category.name, difficulty.name, review?.wireValue, '{}'],
    );
    for (var i = 0; i < result.length; i++) {
      await customStatement('INSERT INTO learning_queue_items VALUES(?,?,?)', [
        id,
        result[i]['id'],
        i,
      ]);
    }
    if (stillAuthorized != null && !stillAuthorized()) {
      throw StateError('Account changed');
    }
  });
  Future<Map<String, dynamic>?> session(String uid) async {
    final sessions = await rows('SELECT * FROM learning_sessions WHERE uid=?', [
      uid,
    ]);
    if (sessions.isEmpty) return null;
    final result = Map<String, dynamic>.from(sessions.single);
    final queue = await rows(
      'SELECT q.word_id,w.payload FROM learning_queue_items q JOIN words w ON w.id=q.word_id WHERE q.session_id=? AND w.published=1 ORDER BY q.position',
      [result['id']],
    );
    result['queue'] = queue
        .map(
          (r) => VocabularyWord.fromJson(
            jsonDecode(r['payload'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
    return result;
  }

  Future<void> tryAgain(String uid, {bool Function()? stillAuthorized}) =>
      transaction(() async {
        if (stillAuthorized != null && !stillAuthorized()) {
          throw StateError('Account changed');
        }
        await customStatement(
          'UPDATE learning_sessions SET waiting=0 WHERE uid=?',
          [uid],
        );
        if (stillAuthorized != null && !stillAuthorized()) {
          throw StateError('Account changed');
        }
      });
  Future<void> swipe(
    String uid,
    String expectedWordId,
    bool right, {
    bool Function()? stillAuthorized,
  }) => transaction(() async {
    if (uid.trim().isEmpty) throw StateError('Sign in before saving progress');
    if (stillAuthorized != null && !stillAuthorized()) {
      throw StateError('Account changed');
    }
    final current = await session(uid);
    if (current == null || current['waiting'] == 1) {
      throw StateError('No active card');
    }
    final queue = List<VocabularyWord>.from(current['queue'] as List);
    if (queue.isEmpty || queue.first.id != expectedWordId) {
      throw StateError('Card changed');
    }
    final word = queue.removeAt(0);
    final progress = await rows(
      'SELECT * FROM user_progress WHERE uid=? AND word_id=?',
      [uid, word.id],
    );
    final old = progress.isEmpty
        ? null
        : ProgressStatus.parse(progress.single['status'] as String);
    final status = swipeStatus(old, right);
    final time = DateTime.now().toUtc().toIso8601String();
    await customStatement(
      'INSERT INTO user_progress(uid,word_id,status,created_at,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(uid,word_id) DO UPDATE SET status=excluded.status,updated_at=excluded.updated_at',
      [uid, word.id, status.wireValue, time, time],
    );
    await customStatement(
      'INSERT INTO local_sequences VALUES(?,1) ON CONFLICT(uid) DO UPDATE SET sequence=sequence+1',
      [uid],
    );
    final sequence = (await rows(
      'SELECT sequence FROM local_sequences WHERE uid=?',
      [uid],
    )).single['sequence'];
    await customStatement(
      "INSERT INTO pending_sync_operations(operation_id,uid,word_id,desired_status,base_revision,sequence,created_at,device_id) VALUES(?,?,?,?,?,?,?,(SELECT value FROM local_metadata WHERE key='device_id'))",
      [
        newId(),
        uid,
        word.id,
        status.wireValue,
        progress.isEmpty ? 0 : progress.single['server_revision'],
        sequence,
        time,
      ],
    );
    if (status == ProgressStatus.didntKnow) {
      queue.insert(min(3, queue.length), word);
    }
    await customStatement(
      'DELETE FROM learning_queue_items WHERE session_id=?',
      [current['id']],
    );
    for (var i = 0; i < queue.length; i++) {
      await customStatement('INSERT INTO learning_queue_items VALUES(?,?,?)', [
        current['id'],
        queue[i].id,
        i,
      ]);
    }
    final outcomes =
        jsonDecode(current['outcomes'] as String) as Map<String, dynamic>;
    outcomes[word.id] = status.wireValue;
    await customStatement(
      'UPDATE learning_sessions SET waiting=?,outcomes=? WHERE uid=?',
      [
        status == ProgressStatus.didntKnow && queue.length == 1 ? 1 : 0,
        jsonEncode(outcomes),
        uid,
      ],
    );
    if (stillAuthorized != null && !stillAuthorized()) {
      throw StateError('Account changed');
    }
  });
}

class ContentSnapshot {
  ContentSnapshot(
    this.revision,
    Map<String, int> groupCounts, {
    this.publisherVersion,
    this.oldestRetainedRevision = 0,
  }) : groupCounts = Map.unmodifiable(groupCounts);
  final int revision;
  final Map<String, int> groupCounts;
  final int? publisherVersion;
  final int oldestRetainedRevision;
  bool sameVersion(ContentSnapshot other) =>
      revision == other.revision &&
      publisherVersion == other.publisherVersion &&
      oldestRetainedRevision == other.oldestRetainedRevision &&
      groupCounts.length == other.groupCounts.length &&
      groupCounts.entries.every((e) => other.groupCounts[e.key] == e.value);

  factory ContentSnapshot.fromJson(Map<String, dynamic> json) {
    final counts = json['groupCounts'];
    if (json['schemaVersion'] != 1 ||
        json['currentRevision'] is! int ||
        counts is! Map ||
        (json.containsKey('oldestRetainedRevision') &&
            json['oldestRetainedRevision'] is! int) ||
        (json.containsKey('publisherVersion') &&
            (json['publisherVersion'] is! int ||
                json['publisherVersion'] != 1))) {
      throw const FormatException('Unsupported publication manifest');
    }
    final keys = {
      for (final c in Category.values)
        for (final d in Difficulty.values) '${c.name}/${d.name}',
    };
    if (counts.length != keys.length ||
        counts.keys.any((key) => !keys.contains(key)) ||
        counts.values.any((value) => value is! int || value < 0)) {
      throw const FormatException('Invalid publication group counts');
    }
    final snapshot = ContentSnapshot(
      json['currentRevision'] as int,
      Map<String, int>.from(counts),
      publisherVersion: json['publisherVersion'] as int?,
      oldestRetainedRevision: json.containsKey('oldestRetainedRevision')
          ? json['oldestRetainedRevision'] as int
          : 0,
    );
    snapshot.validate(null);
    if (json.containsKey('totalPublished') &&
        (json['totalPublished'] is! int ||
            json['totalPublished'] !=
                snapshot.groupCounts.values.fold<int>(0, (a, b) => a + b))) {
      throw const FormatException('Publication total does not match groups');
    }
    return snapshot;
  }

  void validate(Category? category) {
    if (revision < 0 ||
        revision >= 9007199254740991 ||
        oldestRetainedRevision < 0 ||
        oldestRetainedRevision > revision) {
      throw const FormatException('Invalid publication revision');
    }
    for (final c in category == null ? Category.values : [category]) {
      for (final d in Difficulty.values) {
        final count = groupCounts['${c.name}/${d.name}'];
        if (count == null || count < 0) {
          throw const FormatException('Missing or invalid publication group');
        }
      }
    }
  }
}

abstract interface class PublishedContentSource {
  Future<ContentSnapshot> manifest();
  Future<List<VocabularyWord>> page(Category? category, String? afterId);
}

class ContentDownloader {
  ContentDownloader(this.store, this.source);
  final LearningStore store;
  final PublishedContentSource source;
  Future<int> download(
    Category? category, {
    required bool Function() cancelled,
    void Function(int)? onProgress,
    Set<Category>? scopes,
    int? expectedGeneration,
    bool requireTrustedManifest = false,
  }) async {
    final id = newId();
    try {
      final snapshot = await source.manifest();
      snapshot.validate(category);
      if (requireTrustedManifest && snapshot.publisherVersion != 1) {
        throw const ContentFailure('content-manifest-unsupported');
      }
      var count = 0;
      final queries = scopes == null
          ? <Category?>[category]
          : scopes.length == 3
          ? <Category?>[null]
          : <Category?>[...Category.values.where(scopes.contains)];
      if (queries.isEmpty) throw StateError('No download scope');
      for (final selected in queries) {
        String? cursor;
        while (true) {
          if (cancelled()) {
            throw StateError(
              'Download cancelled. Retry to restart; existing content is preserved.',
            );
          }
          final words = await source.page(selected, cursor);
          if (cancelled()) throw StateError('Download cancelled.');
          if (words.isEmpty) break;
          if (selected != null && words.any((w) => w.category != selected)) {
            throw StateError('Wrong download category');
          }
          var previous = cursor;
          for (final word in words) {
            if (previous != null && word.id.compareTo(previous) <= 0) {
              throw StateError('Invalid download cursor');
            }
            previous = word.id;
          }
          if (words.any((word) => word.revision > snapshot.revision)) {
            throw StateError('Word revision exceeds the manifest');
          }
          await store.stage(id, words);
          count += words.length;
          if (count > 10000) {
            throw StateError('Download exceeds safe snapshot limit.');
          }
          onProgress?.call(count);
          cursor = words.last.id;
        }
      }
      final closing = await source.manifest();
      closing.validate(category);
      if (cancelled()) throw StateError('Download cancelled.');
      if (!closing.sameVersion(snapshot)) {
        throw StateError('Content changed during download. Retry.');
      }
      await store.commitDownload(
        id,
        category,
        snapshot.revision,
        snapshot.groupCounts,
        stillWanted: () => !cancelled(),
        scopes: scopes,
        trustedManifest: snapshot.publisherVersion == 1,
        expectedGeneration: expectedGeneration,
      );
      return count;
    } catch (_) {
      await store.discard(id);
      rethrow;
    }
  }
}
