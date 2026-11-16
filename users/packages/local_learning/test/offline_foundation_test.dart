import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:local_learning/local_learning.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'store_test.dart' as fixtures;

Map<String, int> allCounts(int count) => {
  for (final c in Category.values)
    for (final d in Difficulty.values)
      '${c.name}/${d.name}': c == Category.basic && d == Difficulty.easy
          ? count
          : 0,
};
Map<String, dynamic> manifest(int count) => {
  'schemaVersion': 1,
  'publisherVersion': 1,
  'currentRevision': 7,
  'totalPublished': count,
  'groupCounts': allCounts(count),
};

class ScriptedSource implements PublishedContentSource {
  ScriptedSource(this.snapshot, this.pages, {this.closing});
  final ContentSnapshot snapshot;
  final ContentSnapshot? closing;
  final List<List<VocabularyWord>> pages;
  int manifests = 0, reads = 0;
  @override
  Future<ContentSnapshot> manifest() async =>
      manifests++ == 0 ? snapshot : closing ?? snapshot;
  @override
  Future<List<VocabularyWord>> page(Category? category, String? cursor) async =>
      reads < pages.length ? pages[reads++] : [];
}

void main() {
  test('drafts, retired records and future revisions never replace public downloads', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    await fixtures.seed(db, [fixtures.word('old')]);
    for (final overrides in [
      {'isPublished': false},
      {'isRetired': true},
      {'revision': 2},
    ]) {
      final unsafe = VocabularyWord.fromJson({
        ...fixtures.word('a').toJson(),
        ...overrides,
      });
      final source = ScriptedSource(ContentSnapshot(1, fixtures.counts(1)), [
        [unsafe],
      ]);
      await expectLater(
        ContentDownloader(
          db,
          source,
        ).download(Category.basic, cancelled: () => false),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(
        (await db.browse(
          category: Category.basic,
          difficulty: Difficulty.easy,
        )).single.id,
        'old',
      );
      expect(await db.rows('SELECT * FROM download_staging'), isEmpty);
    }
  });

  test(
    'publication manifest validates all nine groups, versions and exact totals',
    () {
      expect(ContentSnapshot.fromJson(manifest(2)).revision, 7);
      final legacy = manifest(2)
        ..remove('publisherVersion')
        ..remove('totalPublished');
      expect(ContentSnapshot.fromJson(legacy).groupCounts.length, 9);
      for (final invalid in [
        {...manifest(2), 'schemaVersion': 2},
        {...manifest(2), 'publisherVersion': 2},
        {...manifest(2), 'currentRevision': -1},
        {...manifest(2), 'totalPublished': 3},
        {
          ...manifest(2),
          'groupCounts': {...allCounts(2)}..remove('advanced/advanced'),
        },
        {
          ...manifest(2),
          'groupCounts': {...allCounts(2), 'basic/easy': -1},
        },
        {
          ...manifest(2),
          'groupCounts': {...allCounts(2), 'basic/easy': 2.0},
        },
      ]) {
        expect(() => ContentSnapshot.fromJson(invalid), throwsFormatException);
      }
      final counts = allCounts(1);
      final snapshot = ContentSnapshot(7, counts);
      counts['basic/easy'] = 99;
      expect(snapshot.groupCounts['basic/easy'], 1);
      expect(() => snapshot.groupCounts.clear(), throwsUnsupportedError);
    },
  );

  test(
    'late cancellation rolls back content, completeness and queue pruning',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      await fixtures.seed(db, [fixtures.word('a')]);
      await db.startSession('alice', Category.basic, Difficulty.easy);
      final before = await db.downloads();
      await db.stage('replacement', [fixtures.word('b')]);
      var checks = 0;
      await expectLater(
        db.commitDownload(
          'replacement',
          Category.basic,
          2,
          fixtures.counts(1),
          stillWanted: () => ++checks == 1,
        ),
        throwsStateError,
      );
      expect(await db.downloads(), before);
      expect((await db.session('alice'))!['queue'], hasLength(1));
      expect(
        (await db.browse(
          category: Category.basic,
          difficulty: Difficulty.easy,
        )).single.id,
        'a',
      );
      expect(await db.rows('SELECT * FROM download_staging'), hasLength(1));
    },
  );

  test(
    'unsorted pages and same-revision count changes cannot replace a snapshot',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      await fixtures.seed(db, [fixtures.word('old')]);
      for (final source in [
        ScriptedSource(ContentSnapshot(2, fixtures.counts(2)), [
          [fixtures.word('z'), fixtures.word('a')],
        ]),
        ScriptedSource(ContentSnapshot(2, fixtures.counts(1)), [
          [fixtures.word('a')],
        ], closing: ContentSnapshot(2, fixtures.counts(2))),
      ]) {
        await expectLater(
          ContentDownloader(
            db,
            source,
          ).download(Category.basic, cancelled: () => false),
          throwsStateError,
        );
        expect(
          (await db.browse(
            category: Category.basic,
            difficulty: Difficulty.easy,
          )).single.id,
          'old',
        );
        expect(await db.rows('SELECT * FROM download_staging'), isEmpty);
      }
    },
  );

  test('interrupted staged pages are removed on reopen; committed bilingual data and private IDs survive', () async {
    final temp = await Directory.systemTemp.createTemp('offline-recovery-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/learning.sqlite');
    var db = LearningStore(NativeDatabase(file));
    await fixtures.seed(db, [fixtures.word('a')]);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    final operations = await db.rows('SELECT * FROM pending_sync_operations');
    final metadata = await db.rows('SELECT * FROM local_metadata');
    await db.stage('interrupted', [fixtures.word('b')]);
    await db.close();
    db = LearningStore(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.rows('SELECT * FROM download_staging'), isEmpty);
    expect(await db.rows('SELECT * FROM pending_sync_operations'), operations);
    expect(await db.rows('SELECT * FROM local_metadata'), metadata);
    expect((await db.session('alice'))!['waiting'], 1);
    final restored = (await db.browse(
      category: Category.basic,
      difficulty: Difficulty.easy,
    )).single;
    expect(restored.toJson(), fixtures.word('a').toJson());
    expect((await db.rows('PRAGMA foreign_keys')).single.values.single, 1);
    expect(
      (await db.rows('PRAGMA integrity_check')).single.values.single,
      'ok',
    );
    await db.clearPrivate('alice');
    expect(await db.rows('SELECT * FROM learning_queue_items'), isEmpty);
    expect(await db.rows('SELECT * FROM user_progress'), isEmpty);
    expect(await db.rows('SELECT * FROM pending_sync_operations'), isEmpty);
    expect(
      await db.browse(category: Category.basic, difficulty: Difficulty.easy),
      hasLength(1),
    );
    expect(await db.session('bob'), isNull);
  });

  test(
    'unknown database versions fail closed without dropping existing data',
    () async {
      final temp = await Directory.systemTemp.createTemp('offline-version-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/learning.sqlite');
      final original = LearningStore(NativeDatabase(file));
      await fixtures.seed(original, [fixtures.word('a')]);
      await original.customStatement('PRAGMA user_version = 4');
      await original.close();
      final unsupported = LearningStore(NativeDatabase(file));
      await expectLater(unsupported.downloads(), throwsStateError);
      await unsupported.close();
      final raw = sqlite.sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single.values.single, 4);
        expect(raw.select('SELECT id FROM words').single['id'], 'a');
      } finally {
        raw.close();
      }
    },
  );

  test(
    'session creation and Try Again roll back when the account changes',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      await fixtures.seed(db, [fixtures.word('a')]);
      await db.startSession('alice', Category.basic, Difficulty.easy);
      await db.swipe('alice', 'a', false);
      final before = await db.session('alice');
      var checks = 0;
      await expectLater(
        db.startSession(
          'alice',
          Category.basic,
          Difficulty.easy,
          stillAuthorized: () => ++checks == 1,
        ),
        throwsStateError,
      );
      expect((await db.session('alice'))!['id'], before!['id']);
      checks = 0;
      await expectLater(
        db.tryAgain('alice', stillAuthorized: () => ++checks == 1),
        throwsStateError,
      );
      expect((await db.session('alice'))!['waiting'], 1);
      expect(await db.pendingCount('alice'), 1);
      await expectLater(
        db.startSession('', Category.basic, Difficulty.easy),
        throwsStateError,
      );
      await expectLater(db.swipe('', 'a', true), throwsStateError);
    },
  );

  test('disk write failure rolls back progress, sequence, outcome and queue before retry', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    await fixtures.seed(db, [fixtures.word('a')]);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.customStatement(
      "CREATE TRIGGER fail_outbox BEFORE INSERT ON pending_sync_operations BEGIN SELECT RAISE(ABORT,'simulated storage failure'); END",
    );
    await expectLater(db.swipe('alice', 'a', true), throwsA(isA<Exception>()));
    expect(await db.rows('SELECT * FROM user_progress'), isEmpty);
    expect(await db.rows('SELECT * FROM local_sequences'), isEmpty);
    expect(
      jsonDecode((await db.session('alice'))!['outcomes'] as String),
      isEmpty,
    );
    expect((await db.session('alice'))!['queue'], hasLength(1));
    await db.customStatement('DROP TRIGGER fail_outbox');
    await db.swipe('alice', 'a', true);
    expect(await db.pendingCount('alice'), 1);
    expect(
      (await db.rows('SELECT sequence FROM local_sequences'))
          .single['sequence'],
      1,
    );
  });

  test('new snapshots preserve stable progress on group moves and block revision rollback', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    await fixtures.seed(db, [fixtures.word('a')]);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    final moved = VocabularyWord.fromJson({
      ...fixtures.word('a').toJson(),
      'category': 'advanced',
      'revision': 2,
    });
    await db.stage('move', [moved]);
    await db.commitDownload('move', Category.advanced, 2, {
      for (final d in Difficulty.values)
        'advanced/${d.name}': d == Difficulty.easy ? 1 : 0,
    });
    expect((await db.session('alice'))!['queue'], isEmpty);
    expect(await db.pendingCount('alice'), 1);
    expect(
      (await db.statistics(
        'alice',
        Category.advanced,
        Difficulty.easy,
      ))['didnt_know'],
      1,
    );
    expect(
      (await db.downloads())
          .where((g) => g['category'] == 'basic')
          .every((g) => g['complete'] == 0),
      isTrue,
    );
    await expectLater(
      db.commitDownload('old', Category.basic, 1, fixtures.counts(0)),
      throwsStateError,
    );
  });
}
