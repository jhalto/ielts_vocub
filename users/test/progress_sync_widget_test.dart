import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_learning/local_learning.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vocab_swipe/features/offline/offline_panel.dart';

import '../packages/local_learning/test/support/fake_progress.dart';
import '../packages/local_learning/test/support/fake_content.dart';
import 'offline_foundation_test.dart' show seededStore;

Future<void> settleDatabase(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        ),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null),
  );
  testWidgets('sync is opt-in and manual Sync Now reports acknowledged work', (
    tester,
  ) async {
    final db = (await tester.runAsync(seededStore))!;
    addTearDown(db.close);
    await tester.runAsync(() async {
      await db.startSession('alice', Category.basic, Difficulty.easy);
      await db.swipe('alice', 'offline-test', false);
    });
    final remote = FakeProgressRemote();
    final content = FakeContentFeed(
      (await tester.runAsync(
        () => db.browse(category: Category.basic, difficulty: Difficulty.easy),
      ))!,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OfflinePanel(
              uid: 'alice',
              storeLoader: () async => db,
              currentUid: () => 'alice',
              syncRemoteFactory: () => remote,
              contentSourceFactory: () => content,
            ),
          ),
        ),
      ),
    );
    await settleDatabase(tester);
    expect(remote.bodies, isEmpty);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.ensureVisible(find.text('Sync Now'));
    await tester.tap(find.text('Sync Now'));
    await settleDatabase(tester);
    expect(find.text('Up to date'), findsOneWidget);
    expect(await tester.runAsync(() => db.pendingCount('alice')), 0);
    expect(find.textContaining('Last successful sync:'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'conflict choice requires confirmation and cancellation preserves local intent',
    (tester) async {
      final db = (await tester.runAsync(seededStore))!;
      addTearDown(db.close);
      await tester.runAsync(() async {
        await db.startSession('alice', Category.basic, Difficulty.easy);
        await db.swipe('alice', 'offline-test', false);
      });
      final remote = FakeProgressRemote()
        ..put('alice', 'offline-test', 'learned');
      final content = FakeContentFeed(
        (await tester.runAsync(
          () =>
              db.browse(category: Category.basic, difficulty: Difficulty.easy),
        ))!,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OfflinePanel(
                uid: 'alice',
                storeLoader: () async => db,
                currentUid: () => 'alice',
                syncRemoteFactory: () => remote,
                contentSourceFactory: () => content,
              ),
            ),
          ),
        ),
      );
      await settleDatabase(tester);
      await tester.ensureVisible(find.text('Sync Now'));
      await tester.tap(find.text('Sync Now'));
      await settleDatabase(tester);
      expect(find.text('Conflict requires attention'), findsOneWidget);
      await tester.ensureVisible(find.text('Use server progress'));
      await tester.tap(find.text('Use server progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => db.pendingCount('alice')), 1);
      await tester.tap(find.text('Use server progress'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await settleDatabase(tester);
      expect(await tester.runAsync(() => db.pendingCount('alice')), 0);
      expect(
        (await tester.runAsync(
          () => db.statistics('alice', Category.basic, Difficulty.easy),
        ))!['learned'],
        1,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
