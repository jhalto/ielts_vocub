import 'dart:io';

import 'package:drift/native.dart';
import 'package:local_learning/local_learning.dart';
import 'package:test/test.dart';

VocabularyWord word(String id, {int ordering = 0}) => VocabularyWord(
  id: id,
  spelling: 'Word $id',
  pronunciation: 'word',
  category: Category.basic,
  difficulty: Difficulty.easy,
  ordering: ordering,
  revision: 1,
  isPublished: true,
  isRetired: false,
  senses: [
    WordSense(
      id: 'sense',
      partOfSpeech: PartOfSpeech.noun,
      englishMeaning: 'Fixture meaning',
      bengaliMeaning: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
      ordering: 0,
      examples: const [
        ExamplePair(
          english: 'Test only.',
          bengali: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
        ),
      ],
    ),
  ],
);
Map<String, int> counts(int count) => {
  for (final d in Difficulty.values)
    'basic/${d.name}': d == Difficulty.easy ? count : 0,
};
Future<void> seed(
  LearningStore db,
  List<VocabularyWord> words, {
  int revision = 1,
}) async {
  final id = newId();
  await db.stage(id, words);
  await db.commitDownload(id, Category.basic, revision, counts(words.length));
}

class FakeSource implements PublishedContentSource {
  FakeSource(this.words);
  final List<VocabularyWord> words;
  int manifestCalls = 0;
  bool changeRevision = false, failPage = false;
  @override
  Future<ContentSnapshot> manifest() async => ContentSnapshot(
    changeRevision && manifestCalls++ > 0 ? 2 : 1,
    counts(words.length),
  );
  @override
  Future<List<VocabularyWord>> page(Category? category, String? cursor) async {
    if (failPage) throw StateError('Interrupted network');
    return cursor == null ? words : [];
  }
}

void main() {
  test('all swipe transitions exactly match the specification', () {
    expect(swipeStatus(null, true), ProgressStatus.alreadyKnow);
    for (final current in [null, ...ProgressStatus.values]) {
      expect(swipeStatus(current, false), ProgressStatus.didntKnow);
    }
    expect(swipeStatus(ProgressStatus.didntKnow, true), ProgressStatus.learned);
    expect(swipeStatus(ProgressStatus.learned, true), ProgressStatus.learned);
    expect(
      swipeStatus(ProgressStatus.alreadyKnow, true),
      ProgressStatus.alreadyKnow,
    );
  });
  test('atomic snapshot validates completeness and preserves previous data on failure', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db, [word('a')]);
    await db.stage('partial', [word('b')]);
    expect(
      await db.browse(category: Category.basic, difficulty: Difficulty.easy),
      hasLength(1),
    );
    await expectLater(
      db.commitDownload('partial', Category.basic, 2, counts(2)),
      throwsStateError,
    );
    expect(
      (await db.browse(
        category: Category.basic,
        difficulty: Difficulty.easy,
      )).single.id,
      'a',
    );
    expect((await db.downloads()).first['revision'], 1);
    final result = await db.browse(
      category: Category.basic,
      difficulty: Difficulty.easy,
      search: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
    );
    expect(result, hasLength(1));
    expect(
      await db.browse(
        category: Category.basic,
        difficulty: Difficulty.easy,
        partOfSpeech: PartOfSpeech.noun,
      ),
      hasLength(1),
    );
    expect(
      await db.browse(
        category: Category.basic,
        difficulty: Difficulty.easy,
        partOfSpeech: PartOfSpeech.verb,
      ),
      isEmpty,
    );
    expect(
      await db.browse(
        category: Category.basic,
        difficulty: Difficulty.easy,
        unmarkedOnly: true,
        uid: 'bob',
      ),
      hasLength(1),
    );
  });
  test('download cancellation, changing versions and network failure never mark complete', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    for (final source in [
      FakeSource([word('a')])..changeRevision = true,
      FakeSource([word('a')])..failPage = true,
    ]) {
      await expectLater(
        ContentDownloader(
          db,
          source,
        ).download(Category.basic, cancelled: () => false),
        throwsStateError,
      );
      expect(await db.downloads(), isEmpty);
      expect(await db.rows('SELECT * FROM download_staging'), isEmpty);
    }
    await expectLater(
      ContentDownloader(
        db,
        FakeSource([word('a')]),
      ).download(Category.basic, cancelled: () => true),
      throwsStateError,
    );
    await ContentDownloader(
      db,
      FakeSource([word('a')]),
    ).download(Category.basic, cancelled: () => false);
    expect((await db.downloads()).every((g) => g['complete'] == 1), isTrue);
  });
  test('unique queue reinserts unknown after three others and atomic progress/outbox survives restart', () async {
    final temp = await Directory.systemTemp.createTemp('vocabulary-store-');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/learning.sqlite');
    var db = LearningStore(NativeDatabase(file));
    await seed(db, [for (var i = 0; i < 5; i++) word('$i', ordering: i)]);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', '0', false);
    var session = await db.session('alice');
    expect((session!['queue'] as List<VocabularyWord>).map((w) => w.id), [
      '1',
      '2',
      '3',
      '0',
      '4',
    ]);
    expect(await db.pendingCount('alice'), 1);
    await db.close();
    db = LearningStore(NativeDatabase(file));
    addTearDown(db.close);
    session = await db.session('alice');
    expect((session!['queue'] as List).length, 5);
    expect(await db.pendingCount('alice'), 1);
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['didnt_know'],
      1,
    );
    expect(await db.statistics('bob', Category.basic, Difficulty.easy), {
      'unmarked': 5,
    });
    expect(await db.session('bob'), isNull);
    expect(await db.pendingCount('bob'), 0);
    await db.clearPrivate('alice');
    expect(await db.pendingCount('alice'), 0);
    expect(await db.session('alice'), isNull);
    expect(
      (await db.statistics(
        'alice',
        Category.basic,
        Difficulty.easy,
      ))['unmarked'],
      5,
    );
  });
  test(
    'one unknown requires Try Again; right turns learning into learned',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      await seed(db, [word('a')]);
      await db.startSession('alice', Category.basic, Difficulty.easy);
      await db.swipe('alice', 'a', false);
      expect((await db.session('alice'))!['waiting'], 1);
      await expectLater(db.swipe('alice', 'a', true), throwsStateError);
      await db.tryAgain('alice');
      await db.swipe('alice', 'a', true);
      expect(
        (await db.statistics(
          'alice',
          Category.basic,
          Difficulty.easy,
        ))['learned'],
        1,
      );
      expect((await db.session('alice'))!['queue'], isEmpty);
      expect(await db.pendingCount('alice'), 2);
    },
  );
  test(
    'account change during commit rolls back progress, outbox and queue',
    () async {
      final db = LearningStore(NativeDatabase.memory());
      addTearDown(db.close);
      await seed(db, [word('a')]);
      await db.startSession('alice', Category.basic, Difficulty.easy);
      var checks = 0;
      await expectLater(
        db.swipe('alice', 'a', true, stillAuthorized: () => ++checks == 1),
        throwsStateError,
      );
      expect(await db.pendingCount('alice'), 0);
      expect(
        (await db.statistics(
          'alice',
          Category.basic,
          Difficulty.easy,
        ))['unmarked'],
        1,
      );
      expect((await db.session('alice'))!['queue'], hasLength(1));
    },
  );
  test('snapshot removal keeps history and removes retired cards; foreign keys and status constraints apply', () async {
    final db = LearningStore(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db, [word('a')]);
    await db.startSession('alice', Category.basic, Difficulty.easy);
    await db.swipe('alice', 'a', false);
    await seed(db, [], revision: 2);
    expect(
      await db.browse(category: Category.basic, difficulty: Difficulty.easy),
      isEmpty,
    );
    expect((await db.session('alice'))!['queue'], isEmpty);
    expect(await db.pendingCount('alice'), 1);
    await expectLater(
      db.customStatement(
        "INSERT INTO user_progress VALUES('bob','missing','learned',0,'now','now')",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      db.customStatement("UPDATE user_progress SET status='learning'"),
      throwsA(isA<Exception>()),
    );
  });
}
