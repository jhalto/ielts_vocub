part of '../local_learning.dart';

extension ContentStore on LearningStore {
  Future<void> _createContentSchema() async {
    for (final sql in [
      'CREATE TABLE content_checkpoints(category TEXT PRIMARY KEY,revision INTEGER NOT NULL CHECK(revision>=0))',
      'CREATE TABLE content_cache_state(id INTEGER PRIMARY KEY CHECK(id=1),generation INTEGER NOT NULL)',
      'INSERT INTO content_cache_state VALUES(1,0)',
      'CREATE TABLE content_delta_staging(run_id TEXT NOT NULL,word_id TEXT NOT NULL,revision INTEGER NOT NULL,payload TEXT,PRIMARY KEY(run_id,word_id))',
    ]) {
      await customStatement(sql);
    }
  }

  Future<int> contentGeneration() async =>
      (await rows('SELECT generation FROM content_cache_state WHERE id=1'))
              .single['generation']
          as int;
  Future<void> _bumpContentGeneration() => customStatement(
    'UPDATE content_cache_state SET generation=generation+1 WHERE id=1',
  );
  Future<void> singleContentSync(Future<void> Function() work) {
    if (_contentFlight != null) return _contentFlight!;
    final result = Completer<void>();
    _contentFlight = result.future;
    unawaited(() async {
      try {
        await work();
        result.complete();
      } catch (e, s) {
        result.completeError(e, s);
      } finally {
        _contentFlight = null;
      }
    }());
    return result.future;
  }

  Future<ContentBaseline> contentBaseline() => transaction(() async {
    final groups = await downloads();
    final scopes = groups
        .map((g) => Category.values.byName(g['category'] as String))
        .toSet();
    final checkpoints = <Category, int>{};
    final saved = await rows('SELECT * FROM content_checkpoints');
    for (final row in saved) {
      final category = Category.values.byName(row['category'] as String);
      final selected = groups
          .where((g) => g['category'] == category.name)
          .toList();
      if (scopes.contains(category) &&
          selected.length == 3 &&
          selected.every((g) => g['revision'] == row['revision'])) {
        checkpoints[category] = row['revision'] as int;
      }
    }
    final versions = [
      0,
      ...groups.map((g) => g['revision'] as int),
      ...saved.map((s) => s['revision'] as int),
    ];
    return ContentBaseline(
      await contentGeneration(),
      scopes,
      checkpoints,
      versions.reduce(max),
    );
  });
  Future<void> _putContentWord(VocabularyWord word) async {
    final existing = await rows('SELECT revision FROM words WHERE id=?', [
      word.id,
    ]);
    if (existing.isNotEmpty &&
        (existing.single['revision'] as int) > word.revision) {
      throw const ContentFailure('content-word-rollback');
    }
    final search = [
      word.spelling,
      for (final sense in word.senses) ...[
        sense.englishMeaning,
        sense.bengaliMeaning,
        for (final e in sense.examples) ...[e.english, e.bengali],
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

  Future<void> stageContentDelta(
    String run,
    List<ContentChange> changes,
    Map<String, VocabularyWord> words, {
    required bool Function() active,
  }) => transaction(() async {
    if (!active()) throw const ContentFailure('account-changed');
    for (final change in changes) {
      final word = words[change.wordId];
      await customStatement(
        'INSERT INTO content_delta_staging VALUES(?,?,?,?)',
        [
          run,
          change.wordId,
          change.revision,
          word == null ? null : jsonEncode(word.toJson()),
        ],
      );
    }
    if (!active()) throw const ContentFailure('account-changed');
  });
  Future<void> discardContentDelta(String run) => customStatement(
    'DELETE FROM content_delta_staging WHERE run_id=?',
    [run],
  );
  Future<void> commitContentDelta(
    String run,
    ContentBaseline baseline,
    ContentSnapshot manifest, {
    required bool Function() active,
  }) => transaction(() async {
    if (!active()) throw const ContentFailure('account-changed');
    if (await contentGeneration() != baseline.generation) {
      throw const ContentFailure('content-local-changed', retryable: true);
    }
    final staged = await rows(
      'SELECT * FROM content_delta_staging WHERE run_id=?',
      [run],
    );
    for (final row in staged) {
      final payload = row['payload'] as String?;
      final word = payload == null
          ? null
          : VocabularyWord.fromJson(
              jsonDecode(payload) as Map<String, dynamic>,
            );
      if (word != null && baseline.scopes.contains(word.category)) {
        if (!word.isPublished ||
            word.isRetired ||
            word.revision != row['revision'] ||
            word.id != row['word_id']) {
          throw const ContentFailure('content-payload-invalid');
        }
        await _putContentWord(word);
      } else {
        await customStatement(
          'UPDATE words SET published=0,revision=MAX(revision,?) WHERE id=?',
          [row['revision'], row['word_id']],
        );
      }
    }
    for (final category in baseline.scopes) {
      for (final difficulty in Difficulty.values) {
        final count = (await rows(
          'SELECT COUNT(*) AS count FROM words WHERE category=? AND difficulty=? AND published=1',
          [category.name, difficulty.name],
        )).single['count'];
        if (count !=
            manifest.groupCounts['${category.name}/${difficulty.name}']) {
          throw const ContentFailure('content-count-mismatch');
        }
        await customStatement(
          'INSERT OR REPLACE INTO downloaded_groups VALUES(?,?,?,?,?)',
          [
            category.name,
            difficulty.name,
            manifest.revision,
            1,
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
      }
      await customStatement(
        'INSERT INTO content_checkpoints VALUES(?,?) ON CONFLICT(category) DO UPDATE SET revision=excluded.revision',
        [category.name, manifest.revision],
      );
    }
    await customStatement(
      'DELETE FROM learning_queue_items WHERE word_id IN (SELECT w.id FROM words w JOIN learning_sessions s ON s.id=learning_queue_items.session_id WHERE w.published=0 OR w.category<>s.category OR w.difficulty<>s.difficulty)',
    );
    await customStatement(
      'UPDATE learning_sessions SET waiting=0 WHERE NOT EXISTS(SELECT 1 FROM learning_queue_items q WHERE q.session_id=learning_sessions.id)',
    );
    await _bumpContentGeneration();
    await discardContentDelta(run);
    if (!active()) throw const ContentFailure('account-changed');
  });
}
