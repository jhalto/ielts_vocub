import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:admin_panel/main.dart';
import 'package:admin_panel/features/words/models.dart';
import 'package:admin_panel/features/words/preview.dart';

import '../../../users/packages/app_auth/test/support/fake_repository.dart';
import 'support/fake_vocabulary.dart';

Future<void> start(
  WidgetTester tester,
  FakeAuthRepository auth,
  FakeVocabulary words,
) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  await tester.pumpWidget(
    AdminApp(repository: auth, vocabularyFactory: (_, _) => words),
  );
  await tester.pumpAndSettle();
}

Future<void> clean(WidgetTester tester, FakeAuthRepository auth) async {
  await tester.pumpWidget(const SizedBox());
  await auth.close();
  await tester.binding.setSurfaceSize(null);
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('role denial never queries or exposes vocabulary controls', (
    tester,
  ) async {
    final auth = FakeAuthRepository(initial: bob);
    final words = FakeVocabulary()
      ..words['word-1'] = fixtureWord(spelling: 'Private draft');
    await start(tester, auth, words);
    expect(find.text('Create word'), findsNothing);
    expect(find.text('Private draft'), findsNothing);
    expect(words.filters, isEmpty);
    await clean(tester, auth);
  });
  testWidgets(
    'dirty editor requires confirmation before leaving and does not write',
    (tester) async {
      final auth = FakeAuthRepository(initial: bob)..allowAdmin = true;
      final words = FakeVocabulary();
      await start(tester, auth, words);
      await tap(tester, find.text('Create word'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Spelling'),
        'Unfinished',
      );
      await tester.pump();
      await tap(tester, find.byTooltip('Back to words'));
      expect(find.text('Discard unsaved changes?'), findsOneWidget);
      await tap(tester, find.text('Cancel'));
      expect(find.widgetWithText(TextFormField, 'Spelling'), findsOneWidget);
      await tap(tester, find.byTooltip('Back to words'));
      await tap(tester, find.text('Leave editor'));
      expect(find.text('Create word'), findsOneWidget);
      expect(words.requests, isEmpty);
      await clean(tester, auth);
    },
  );
  testWidgets('unpublish confirmation precedes the API request', (
    tester,
  ) async {
    final auth = FakeAuthRepository(initial: bob)..allowAdmin = true;
    final words = FakeVocabulary()
      ..words['word-1'] = fixtureWord(published: true);
    await start(tester, auth, words);
    await tap(tester, find.text('Fixture'));
    await tap(tester, find.text('Unpublish'));
    expect(words.requests, isEmpty);
    await tap(tester, find.text('Cancel'));
    expect(words.requests, isEmpty);
    await tap(tester, find.text('Unpublish'));
    await tap(tester, find.text('unpublish'));
    expect(words.requests, hasLength(1));
    expect(words.words['word-1']!.published, isFalse);
    await clean(tester, auth);
  });
  testWidgets('preview preserves all repeated-POS senses and paired examples', (
    tester,
  ) async {
    final draft = fixtureDraft();
    draft.senses.add(
      SenseDraft(
        id: 'sense-2',
        englishMeaning: 'Second meaning',
        bengaliMeaning: '\u09a6\u09cd\u09ac\u09bf\u09a4\u09c0\u09df',
        examples: [
          ExampleDraft(
            english: 'Second example',
            bengali: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: WordPreview(draft: draft)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('noun'), findsNWidgets(2));
    expect(find.text('Second meaning'), findsOneWidget);
    expect(find.text('Second example'), findsOneWidget);
    expect(
      find.text('\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be'),
      findsNWidgets(3),
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'same-UID authorization recheck hides but preserves the dirty form',
    (tester) async {
      final auth = FakeAuthRepository(initial: bob)..allowAdmin = true;
      final words = FakeVocabulary();
      await start(tester, auth, words);
      await tap(tester, find.text('Create word'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Spelling'),
        'Keep this draft',
      );
      await tester.pump();
      final pending = Completer<Map<String, dynamic>>();
      auth.profileResult = pending;
      auth.emit(bob);
      await tester.pump();
      await tester.pump();
      expect(find.widgetWithText(TextFormField, 'Spelling'), findsNothing);
      pending.complete({'uid': 'bob', 'name': 'Bob'});
      await tester.pumpAndSettle();
      expect(find.text('Keep this draft'), findsOneWidget);
      expect(words.closed, 0);
      await clean(tester, auth);
    },
  );
  testWidgets('mobile navigation and word list fit without layout exceptions', (
    tester,
  ) async {
    final auth = FakeAuthRepository(initial: bob)..allowAdmin = true;
    final words = FakeVocabulary()..words['word-1'] = fixtureWord();
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpWidget(
      AdminApp(repository: auth, vocabularyFactory: (_, _) => words),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tap(tester, find.byIcon(Icons.menu));
    await tap(tester, find.text('Account'));
    expect(find.text('Administrator account'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await clean(tester, auth);
  });
}
