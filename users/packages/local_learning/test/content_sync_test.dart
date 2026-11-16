import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:local_learning/local_learning.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'store_test.dart' as fixtures;
import 'support/fake_content.dart';
import 'support/fake_progress.dart';

VocabularyWord edited(VocabularyWord word, Map<String, dynamic> changes) =>
    VocabularyWord.fromJson({...word.toJson(), ...changes});
Future<void> baseline(
  LearningStore db,
  FakeContentFeed source, [
  Category? category = Category.basic,
]) => ContentDownloader(db, source).download(category, cancelled: () => false);
Future<int> checkpoint(LearningStore db, String category) async =>
    (await db.rows(
          'SELECT revision FROM content_checkpoints WHERE category=?',
          [category],
        )).single['revision']
        as int;
Future<List<Map<String, dynamic>>> localState(LearningStore db) async => [
  {'words': await db.rows('SELECT * FROM words ORDER BY id')},
  {'groups': await db.downloads()},
  {
    'checkpoints': await db.rows(
      'SELECT * FROM content_checkpoints ORDER BY category',
    ),
  },
];

void main() {
  test('missing upsert payload recovers rather than accepting an implicit tombstone', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    source.publish(
      edited(source.words['a']!, {'spelling': 'Recovered missing lookup'}),
    );
    source.omittedPublishedIds.add('a');
    final pages = source.fullPages;
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(source.fullPages, greaterThan(pages));
    expect(
      (await db.browse(
        category: Category.basic,
        difficulty: Difficulty.easy,
      )).single.spelling,
      'Recovered missing lookup',
    );
    expect(await checkpoint(db, 'basic'), 2);
  });
  test(
    'recovery cannot replace a trusted baseline with a legacy manifest',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      final source = FakeContentFeed([fixtures.word('a')]);
      await baseline(db, source);
      final before = await localState(db);
      source.noop();
      source.feed.removeLast();
      source.onChanges = () async {
        source.publisherVersion = null;
      };
      await expectLater(
        ContentReconciler(db, source).reconcile(active: () => true),
        throwsA(isA<ContentFailure>()),
      );
      expect(await localState(db), before);
    },
  );
  test('denied public ID lookup uses a verified snapshot instead of inventing a tombstone', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    source.publish(
      edited(source.words['a']!, {
        'spelling': 'Verified public lookup fallback',
      }),
    );
    source.onPublished = () async {
      throw const ContentFailure('content-public-query-unavailable');
    };
    final pages = source.fullPages;
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(source.fullPages, greaterThan(pages));
    expect(
      (await db.browse(
        category: Category.basic,
        difficulty: Difficulty.easy,
      )).single.spelling,
      'Verified public lookup fallback',
    );
    expect(await checkpoint(db, 'basic'), 2);
  });
  test('late cancellation rolls back delta content, queue changes and cursor together', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    final before = await localState(db);
    final original = await db.rows('SELECT * FROM pending_sync_operations');
    final captured = await db.contentBaseline();
    source.remove('a');
    await db.stageContentDelta(
      'cancelled',
      [ContentChange(2, 'remove', 'a')],
      {},
      active: () => true,
    );
    var checks = 0;
    await expectLater(
      db.commitContentDelta(
        'cancelled',
        captured,
        await source.manifest(),
        active: () => ++checks == 1,
      ),
      throwsA(isA<ContentFailure>()),
    );
    expect(await localState(db), before);
    expect(await db.rows('SELECT * FROM pending_sync_operations'), original);
    expect((await db.session('alice'))!['queue'], hasLength(1));
  });
  test(
    'multi-category fallback stages all scopes before any live replacement',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      final source = FakeContentFeed([
        fixtures.word('a'),
        edited(fixtures.word('b'), {'category': 'intermediate'}),
      ]);
      await baseline(db, source);
      await baseline(db, source, Category.intermediate);
      final before = await localState(db);
      source.publish(
        edited(source.words['a']!, {'spelling': 'Uncommitted fallback'}),
      );
      source.feed.removeLast();
      var pages = 0;
      source.onPage = () async {
        if (++pages == 3) throw const SyncFailure('offline');
      };
      await expectLater(
        ContentReconciler(db, source).reconcile(active: () => true),
        throwsA(isA<SyncFailure>()),
      );
      expect(pages, 3);
      expect(await localState(db), before);
      expect(await db.rows('SELECT * FROM download_staging'), isEmpty);
    },
  );
  test('content runs after progress retrieval and a content failure does not resend acknowledged progress', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    final progress = FakeProgressRemote();
    final order = <String>[];
    progress.onUpload = (_) async {
      order.add('progress-upload');
    };
    progress.onList = (_) async {
      order.add('progress-list');
    };
    source.publish(fixtures.word('a'));
    source.onChanges = () async {
      order.add('content-feed');
      throw const SyncFailure('offline');
    };
    final sync = ProgressSynchronizer(
      store: db,
      uid: 'alice',
      remote: progress,
      stillAuthorized: () => true,
      delay: (_) async {},
      reconcileContent: (active) =>
          ContentReconciler(db, source).reconcile(active: active),
    );
    addTearDown(sync.dispose);
    await sync.sync();
    expect(
      order.indexOf('progress-list'),
      lessThan(order.indexOf('content-feed')),
    );
    expect(await db.pendingCount('alice'), 0);
    expect((await db.syncView('alice')).phase, 'offline');
    expect((await db.syncView('alice')).lastSuccess, isNull);
    expect(await checkpoint(db, 'basic'), 1);
    source.onChanges = null;
    await sync.sync();
    expect(order.where((step) => step == 'progress-upload'), hasLength(1));
    expect((await db.syncView('alice')).phase, 'synced');
    expect(await checkpoint(db, 'basic'), 2);
  });
  test('feed decoder rejects schema changes, draft leakage, malformed IDs and revision mismatches', () {
    final valid = {
      'schemaVersion': 1,
      'revision': 1,
      'action': 'noop',
      'updatedAt': '2026-01-01T00:00:00Z',
    };
    expect(ContentChange.fromJson('0000000000000001', valid).wordId, isNull);
    for (final invalid in [
      {...valid, 'schemaVersion': 2},
      {...valid, 'wordId': 'draft'},
      {...valid, 'senses': []},
      {...valid, 'action': 'unknown'},
      {...valid, 'revision': 2},
    ]) {
      expect(
        () => ContentChange.fromJson('0000000000000001', invalid),
        throwsA(isA<SyncFailure>()),
      );
    }
    expect(
      () => ContentSnapshot.fromJson({
        'schemaVersion': 1,
        'publisherVersion': 1,
        'currentRevision': 1,
        'groupCounts': {
          for (final c in Category.values)
            for (final d in Difficulty.values) '${c.name}/${d.name}': 0,
        },
        'oldestRetainedRevision': 2,
      }),
      throwsFormatException,
    );
  });
  test('incremental edit preserves IDs, frozen outbox and a newer swipe while payloads load', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([
      fixtures.word('a'),
      fixtures.word('b', ordering: 1),
    ]);
    await baseline(db, source);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    final original = (await db.prepareSync(
      'alice',
      limit: 25,
      active: () => true,
    )).single;
    final replacement = edited(source.words['a']!, {
      'spelling': 'Updated bilingual fixture',
    });
    source.publish(replacement);
    source.onPublished = () async {
      source.onPublished = null;
      await db.swipe('alice', 'b', true);
      await db.swipe('alice', 'a', true);
    };
    final fullBefore = source.fullPages;
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(source.fullPages, fullBefore);
    expect(await checkpoint(db, 'basic'), source.revision);
    expect(
      (await db.rows(
        'SELECT * FROM pending_sync_operations WHERE operation_id=?',
        [original['operation_id']],
      )).single['request_payload'],
      original['request_payload'],
    );
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['learned'],
      1,
    );
    final words = await db.browse(
      category: Category.basic,
      difficulty: Difficulty.easy,
    );
    expect(words.first.spelling, 'Updated bilingual fixture');
    expect(words.first.id, 'a');
    expect(
      words.first.senses.first.examples.first.bengali,
      fixtures.word('a').senses.first.examples.first.bengali,
    );
  });
  test('moves outside downloaded scope hide cards without downloading another category', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    source.publish(edited(source.words['a']!, {'category': 'advanced'}));
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(
      await db.browse(category: Category.basic, difficulty: Difficulty.easy),
      isEmpty,
    );
    expect(
      await db.browse(category: Category.advanced, difficulty: Difficulty.easy),
      isEmpty,
    );
    expect((await db.downloads()).map((g) => g['category']).toSet(), {'basic'});
    expect(await db.pendingCount('alice'), 1);
    expect((await db.session('alice'))!['queue'], isEmpty);
    source.publish(edited(source.words['a']!, {'category': 'basic'}));
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['didnt_know'],
      1,
    );
    expect((await db.rows('SELECT id FROM words')).single['id'], 'a');
  });
  test('different category baselines catch up together and correctly move words between downloaded groups', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([
      fixtures.word('a'),
      edited(fixtures.word('b'), {'category': 'intermediate'}),
    ]);
    await baseline(db, source);
    source.publish(
      edited(source.words['a']!, {'spelling': 'Edited before second download'}),
    );
    await baseline(db, source, Category.intermediate);
    expect(
      (await db.downloads())
          .where((g) => g['category'] == 'basic')
          .every((g) => g['complete'] == 0),
      isTrue,
    );
    source.publish(edited(source.words['a']!, {'category': 'intermediate'}));
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(
      await db.browse(category: Category.basic, difficulty: Difficulty.easy),
      isEmpty,
    );
    expect(
      await db.browse(
        category: Category.intermediate,
        difficulty: Difficulty.easy,
      ),
      hasLength(2),
    );
    expect(await checkpoint(db, 'basic'), source.revision);
    expect(await checkpoint(db, 'intermediate'), source.revision);
    expect(await db.downloads(), hasLength(6));
  });
  test('noops advance the durable cursor without fetching or changing word payloads', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    final before = await db.rows('SELECT * FROM words');
    final fullBefore = source.fullPages;
    var fetched = false;
    source.onPublished = () async {
      fetched = true;
    };
    source.noop();
    source.noop();
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(await db.rows('SELECT * FROM words'), before);
    expect(fetched, isFalse);
    expect(source.fullPages, fullBefore);
    expect(await checkpoint(db, 'basic'), 3);
  });
  test('unpublish, restore noop and republish preserve historical progress and pending intent', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    final frozen = (await db.prepareSync(
      'alice',
      limit: 25,
      active: () => true,
    )).single;
    source.remove('a');
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect((await db.session('alice'))!['queue'], isEmpty);
    source.noop();
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(
      await db.browse(category: Category.basic, difficulty: Difficulty.easy),
      isEmpty,
    );
    source.publish(fixtures.word('a'));
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['didnt_know'],
      1,
    );
    expect(
      (await db.rows('SELECT * FROM pending_sync_operations'))
          .single['request_payload'],
      frozen['request_payload'],
    );
  });
  test(
    'feed gaps fall back to a verified snapshot of only the downloaded scope',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      final source = FakeContentFeed([fixtures.word('a')]);
      await baseline(db, source);
      source.publish(
        edited(source.words['a']!, {'spelling': 'Recovered edit'}),
      );
      source.noop();
      source.feed.removeWhere((e) => e.revision == 2);
      final fullBefore = source.fullPages;
      await ContentReconciler(db, source).reconcile(active: () => true);
      expect(source.fullPages, greaterThan(fullBefore));
      expect(await checkpoint(db, 'basic'), 3);
      expect((await db.downloads()).map((g) => g['category']).toSet(), {
        'basic',
      });
      expect(
        (await db.browse(
          category: Category.basic,
          difficulty: Difficulty.easy,
        )).single.spelling,
        'Recovered edit',
      );
    },
  );
  test(
    'failed fallback leaves content, queue and checkpoints unchanged',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      final source = FakeContentFeed([fixtures.word('a')]);
      await baseline(db, source);
      await db.startSession('alice', Category.basic, Difficulty.easy);
      final before = await localState(db);
      source.publish(edited(source.words['a']!, {'spelling': 'Not committed'}));
      source.feed.removeLast();
      source.onPage = () async {
        throw const SyncFailure('offline');
      };
      await expectLater(
        ContentReconciler(db, source).reconcile(active: () => true),
        throwsA(isA<SyncFailure>()),
      );
      expect(await localState(db), before);
      expect((await db.session('alice'))!['queue'], hasLength(1));
      expect(await db.rows('SELECT * FROM download_staging'), isEmpty);
      expect(await db.rows('SELECT * FROM content_delta_staging'), isEmpty);
    },
  );
  test(
    'expired cursor uses a snapshot and global revision rollback fails closed',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      final source = FakeContentFeed([fixtures.word('a')]);
      await baseline(db, source);
      source.noop();
      source.noop();
      source.watermark = 2;
      final feedBefore = source.feedPages;
      await ContentReconciler(db, source).reconcile(active: () => true);
      expect(source.feedPages, feedBefore);
      expect(await checkpoint(db, 'basic'), 3);
      final before = await localState(db);
      source.revision = 1;
      source.watermark = 0;
      await expectLater(
        ContentReconciler(db, source).reconcile(active: () => true),
        throwsA(isA<ContentFailure>()),
      );
      expect(await localState(db), before);
    },
  );
  test('interrupted closing read and restart discard staging without advancing a cursor', () async {
    final directory = await Directory.systemTemp.createTemp('content-restart-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/store.sqlite');
    var db = LearningStore(NativeDatabase(file));
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    source.publish(edited(source.words['a']!, {'spelling': 'After restart'}));
    var reads = 0;
    source.onManifest = () async {
      if (++reads == 2) throw const SyncFailure('offline');
    };
    await expectLater(
      ContentReconciler(db, source).reconcile(active: () => true),
      throwsA(isA<SyncFailure>()),
    );
    expect(await checkpoint(db, 'basic'), 1);
    await db.stageContentDelta(
      'abandoned',
      [ContentChange(2, 'upsert', 'a')],
      {'a': source.words['a']!},
      active: () => true,
    );
    await db.close();
    db = LearningStore(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.rows('SELECT * FROM content_delta_staging'), isEmpty);
    expect(await checkpoint(db, 'basic'), 1);
    source.onManifest = null;
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(await checkpoint(db, 'basic'), 2);
  });
  test('concurrent publication retries safely and a continuously changing source never commits', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    source.publish(fixtures.word('a'));
    source.onPublished = () async {
      source.onPublished = null;
      source.publish(
        edited(source.words['a']!, {'spelling': 'Concurrent edit'}),
      );
    };
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(await checkpoint(db, 'basic'), 3);
    final before = await localState(db);
    source.publish(fixtures.word('a'));
    source.onPublished = () async {
      source.publish(fixtures.word('a'));
    };
    await expectLater(
      ContentReconciler(db, source).reconcile(active: () => true),
      throwsA(isA<ContentFailure>()),
    );
    expect(await localState(db), before);
  });
  test('a failure while advancing checkpoints rolls back words, metadata and queue changes', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    final before = await localState(db);
    source.remove('a');
    await db.customStatement(
      "CREATE TRIGGER fail_cursor BEFORE UPDATE ON content_checkpoints BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END",
    );
    await expectLater(
      ContentReconciler(db, source).reconcile(active: () => true),
      throwsA(isA<Exception>()),
    );
    expect(await localState(db), before);
    expect((await db.session('alice'))!['queue'], hasLength(1));
    await db.customStatement('DROP TRIGGER fail_cursor');
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect((await db.session('alice'))!['queue'], isEmpty);
  });
  test('manual download during reconciliation cannot be overwritten by an older local baseline', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    source.publish(edited(source.words['a']!, {'spelling': 'Manual refresh'}));
    source.onPublished = () async {
      source.onPublished = null;
      await baseline(db, source);
    };
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(await checkpoint(db, 'basic'), 2);
    expect(
      (await db.browse(
        category: Category.basic,
        difficulty: Difficulty.easy,
      )).single.spelling,
      'Manual refresh',
    );
  });
  test('v2 migration retains frozen requests and requires a verified baseline before trusting a cursor', () async {
    final directory = await Directory.systemTemp.createTemp(
      'content-migration-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/v2.sqlite');
    var db = LearningStore(NativeDatabase(file));
    final source = FakeContentFeed([fixtures.word('a')]);
    await baseline(db, source);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    final pending = (await db.prepareSync(
      'alice',
      limit: 25,
      active: () => true,
    )).single;
    await db.close();
    // Remove only the new v3 tables to construct the exact previous v2 layout.
    final raw = sqlite.sqlite3.open(file.path);
    for (final table in [
      'content_checkpoints',
      'content_cache_state',
      'content_delta_staging',
    ]) {
      raw.execute('DROP TABLE $table');
    }
    raw.execute('PRAGMA user_version=2');
    raw.close();
    db = LearningStore(NativeDatabase(file));
    addTearDown(db.close);
    expect(await db.rows('SELECT * FROM content_checkpoints'), isEmpty);
    expect(
      (await db.rows('SELECT * FROM pending_sync_operations'))
          .single['request_payload'],
      pending['request_payload'],
    );
    await ContentReconciler(db, source).reconcile(active: () => true);
    expect(await checkpoint(db, 'basic'), 1);
    expect(await db.pendingCount('alice'), 1);
    expect((await db.session('alice'))!['queue'], hasLength(1));
  });
}
