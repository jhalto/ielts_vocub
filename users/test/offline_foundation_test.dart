import 'package:app_auth/app_auth.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_learning/local_learning.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vocab_swipe/features/offline/offline_panel.dart';

import '../packages/app_auth/test/support/fake_repository.dart';

Future<LearningStore> seededStore() async {
  final db = LearningStore(NativeDatabase.memory());
  final word = VocabularyWord(
    id: 'offline-test',
    spelling: 'Synthetic test word',
    pronunciation: 'test',
    category: Category.basic,
    difficulty: Difficulty.easy,
    ordering: 0,
    revision: 1,
    isPublished: true,
    isRetired: false,
    senses: [
      WordSense(
        id: 'test-sense',
        partOfSpeech: PartOfSpeech.noun,
        englishMeaning: 'Test fixture only',
        bengaliMeaning: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
        ordering: 0,
        examples: [
          const ExamplePair(
            english: 'Test only',
            bengali: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
          ),
        ],
      ),
    ],
  );
  await db.stage('test', [word]);
  await db.commitDownload('test', Category.basic, 1, {
    for (final d in Difficulty.values)
      'basic/${d.name}': d == Difficulty.easy ? 1 : 0,
  });
  return db;
}

Future<void> flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  test(
    'real logout cleanup removes only the old UID and keeps downloaded words',
    () async {
      final db = await seededStore();
      addTearDown(db.close);
      for (final uid in ['alice', 'bob']) {
        await db.startSession(uid, Category.basic, Difficulty.easy);
        await db.swipe(uid, 'offline-test', false);
      }
      final repo = FakeAuthRepository(initial: alice);
      addTearDown(repo.close);
      final auth = AuthController(repo, clearPrivate: db.clearPrivate);
      addTearDown(auth.dispose);
      await flush();
      await auth.signOut();
      await flush();
      expect(await db.pendingCount('alice'), 0);
      expect(await db.session('alice'), isNull);
      expect(await db.pendingCount('bob'), 1);
      expect(await db.session('bob'), isNotNull);
      expect(
        await db.browse(category: Category.basic, difficulty: Difficulty.easy),
        hasLength(1),
      );
    },
  );

  test(
    'account switch cleanup cannot delete the incoming UID progress',
    () async {
      final db = await seededStore();
      addTearDown(db.close);
      for (final uid in ['alice', 'bob']) {
        await db.startSession(uid, Category.basic, Difficulty.easy);
        await db.swipe(uid, 'offline-test', false);
      }
      final repo = FakeAuthRepository(initial: alice);
      addTearDown(repo.close);
      Future<void>? cleanup;
      final auth = AuthController(
        repo,
        clearPrivate: (uid) => cleanup = db.clearPrivate(uid),
      );
      addTearDown(auth.dispose);
      await flush();
      repo.emit(bob);
      await flush();
      await cleanup;
      expect(auth.identity?.uid, 'bob');
      expect(await db.pendingCount('alice'), 0);
      expect(await db.pendingCount('bob'), 1);
      expect(
        (await db.statistics(
          'bob',
          Category.basic,
          Difficulty.easy,
        ))['didnt_know'],
        1,
      );
    },
  );

  testWidgets(
    'guest reads local content at mobile width without saving progress',
    (tester) async {
      final db = await tester.runAsync(seededStore);
      addTearDown(db!.close);
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OfflinePanel(uid: null, storeLoader: () async => db),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Synthetic test word'), findsOneWidget);
      expect(find.text('Start learning this group'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(
        await tester.runAsync(() => db.rows('SELECT * FROM user_progress')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'database-open failure can be retried without restarting the app',
    (tester) async {
      final db = await tester.runAsync(seededStore);
      addTearDown(db!.close);
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OfflinePanel(
                uid: null,
                storeLoader: () async {
                  if (++attempts == 1) {
                    throw StateError('Simulated disk access error');
                  }
                  return db;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Local database unavailable. Check disk access and retry.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Retry local read'));
      await tester.runAsync(() async {
        await flush();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(find.text('Synthetic test word'), findsOneWidget);
      expect(find.text('Retry local read'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
