import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:shared_models/shared_models.dart';
export 'package:shared_models/shared_models.dart';

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
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in schema) {
        await customStatement(sql);
      }
      await customStatement('INSERT INTO local_metadata VALUES(?,?)', [
        'device_id',
        newId(),
      ]);
    },
    onUpgrade: (_, from, to) async {
      throw StateError('Unsupported migration $from -> $to');
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA secure_delete = ON');
      // Cancelled/crashed snapshots restart; staged rows never become published.
      await customStatement('DELETE FROM download_staging');
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
    Map<String, int> expectedCounts,
  ) => transaction(() async {
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
    final categories = category == null ? Category.values : [category];
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
    if (words.any((w) => category != null && w.category != category)) {
      throw StateError('Wrong download category');
    }
    // New snapshots invalidate previous-version completeness until redownloaded.
    await customStatement(
      'UPDATE downloaded_groups SET complete=0 WHERE revision<>?',
      [revision],
    );
    if (category == null) {
      await customStatement('UPDATE words SET published=0');
    } else {
      await customStatement('UPDATE words SET published=0 WHERE category=?', [
        category.name,
      ]);
    }
    for (final word in words) {
      final search = [
        word.spelling,
        for (final s in word.senses) ...[
          s.englishMeaning,
          s.bengaliMeaning,
          for (final e in s.examples) ...[e.english, e.bengali],
        ],
      ].join(' ').toLowerCase();
      await customStatement(
        'INSERT INTO words VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET category=excluded.category,difficulty=excluded.difficulty,ordering=excluded.ordering,revision=excluded.revision,published=excluded.published,payload=excluded.payload,searchable=excluded.searchable',
        [
          word.id,
          word.category.name,
          word.difficulty.name,
          word.ordering,
          word.revision,
          1,
          jsonEncode(word.toJson()),
          search,
        ],
      );
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
    await discard(downloadId);
    // Retired/moved words no longer belong in active queues. History remains.
    await customStatement(
      'DELETE FROM learning_queue_items WHERE word_id IN (SELECT w.id FROM words w JOIN learning_sessions s ON s.id=learning_queue_items.session_id WHERE w.published=0 OR w.category<>s.category OR w.difficulty<>s.difficulty)',
    );
    await customStatement(
      'UPDATE learning_sessions SET waiting=0 WHERE NOT EXISTS(SELECT 1 FROM learning_queue_items q WHERE q.session_id=learning_sessions.id)',
    );
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
            'SELECT COUNT(*) AS count FROM pending_sync_operations WHERE uid=?',
            [uid],
          )).single['count']
          as int;
  Future<void> clearPrivate(String uid) => transaction(() async {
    for (final table in [
      'learning_sessions',
      'pending_sync_operations',
      'user_progress',
      'local_sequences',
    ]) {
      await customStatement('DELETE FROM $table WHERE uid=?', [uid]);
    }
  });
  Future<void> startSession(
    String uid,
    Category category,
    Difficulty difficulty, {
    ProgressStatus? review,
  }) => transaction(() async {
    if (uid.trim().isEmpty) throw StateError('Sign in before saving progress');
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

  Future<void> tryAgain(String uid) => customStatement(
    'UPDATE learning_sessions SET waiting=0 WHERE uid=?',
    [uid],
  );
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
  const ContentSnapshot(this.revision, this.groupCounts);
  final int revision;
  final Map<String, int> groupCounts;
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
  }) async {
    final id = newId();
    try {
      final snapshot = await source.manifest();
      String? cursor;
      var count = 0;
      while (true) {
        if (cancelled()) {
          throw StateError(
            'Download cancelled. Retry to restart; existing content is preserved.',
          );
        }
        final words = await source.page(category, cursor);
        if (cancelled()) throw StateError('Download cancelled.');
        if (words.isEmpty) break;
        if (words.any(
          (word) => cursor != null && word.id.compareTo(cursor) <= 0,
        )) {
          throw StateError('Invalid download cursor');
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
      final closing = await source.manifest();
      if (cancelled()) throw StateError('Download cancelled.');
      if (closing.revision != snapshot.revision) {
        throw StateError('Content changed during download. Retry.');
      }
      await store.commitDownload(
        id,
        category,
        snapshot.revision,
        snapshot.groupCounts,
      );
      return count;
    } catch (_) {
      await store.discard(id);
      rethrow;
    }
  }
}
