import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:app_auth/app_auth.dart';
import 'package:admin_panel/features/imports/import_page.dart';
import 'package:admin_panel/features/imports/controller.dart';
import 'package:admin_panel/features/imports/platform_types.dart';
import 'package:admin_panel/main.dart';

import '../../../users/packages/app_auth/test/support/fake_repository.dart';
import 'support/fake_imports.dart';
import 'support/fake_vocabulary.dart';

Future<void> tapImport(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late FakeImports server;
  late FakeAuthRepository repository;
  late AuthController auth;
  late FakeVocabulary words;
  late MemoryImportSession storage;
  setUp(() async {
    server = FakeImports();
    repository = FakeAuthRepository(initial: bob)..allowAdmin = true;
    auth = AuthController(repository, adminOnly: true);
    words = FakeVocabulary();
    storage = MemoryImportSession();
    await Future<void>.delayed(Duration.zero);
  });
  Future<void> start(WidgetTester tester, {PickedJson? selected}) async {
    expect(auth.canEnter, true);
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ImportPage(
                    uid: 'bob',
                    auth: auth,
                    vocabulary: words,
                    client: server.client(),
                    session: storage,
                    picker: () async => selected ?? pickedFile(),
                  ),
                ),
              ),
              child: const Text('Open imports'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapImport(tester, find.text('Open imports'));
  }

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    await repository.close();
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets(
    'file selection and server preview show bilingual normalized content before job creation',
    (tester) async {
      await start(tester);
      await tapImport(tester, find.text('Select JSON file'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Create immutable job'),
            )
            .onPressed,
        isNull,
      );
      await tapImport(tester, find.text('Run server dry run'));
      await tapImport(tester, find.text('Row 1: row-1 · create'));
      expect(find.text('Synthetic row-1'), findsOneWidget);
      expect(find.textContaining('Normalized spelling:'), findsOneWidget);
      expect(find.text('পরীক্ষা'), findsWidgets);
      expect(server.jobs, isEmpty);
      expect(words.requests, isEmpty);
      await clean(tester);
    },
  );
  testWidgets('published review requires confirmation and another dry run', (
    tester,
  ) async {
    server.publishedTargets = true;
    await start(
      tester,
      selected: pickedFile([
        {
          ...importRow(),
          'decision': 'update',
          'expectedRevision': 2,
          'reviewed': true,
        },
      ]),
    );
    await tapImport(tester, find.text('Select JSON file'));
    await tapImport(tester, find.text('Run server dry run'));
    await tapImport(tester, find.text('Row 1: row-1 · update'));
    await tapImport(tester, find.text('Confirm published review'));
    expect(find.text('Confirm published edit review?'), findsOneWidget);
    await tapImport(tester, find.text('Cancel'));
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create immutable job'),
          )
          .onPressed,
      isNull,
    );
    await tapImport(tester, find.text('Confirm published review'));
    await tapImport(tester, find.text('I reviewed this edit'));
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create immutable job'),
          )
          .onPressed,
      isNull,
    );
    await tapImport(tester, find.text('Run server dry run'));
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Create immutable job'),
          )
          .onPressed,
      isNotNull,
    );
    expect(server.jobs, isEmpty);
    await clean(tester);
  });
  testWidgets(
    'creation confirmation precedes every job; explicit processing reports applied counts',
    (tester) async {
      await start(tester);
      await tapImport(tester, find.text('Select JSON file'));
      await tapImport(tester, find.text('Run server dry run'));
      await tapImport(tester, find.text('Create immutable job'));
      expect(server.jobs, isEmpty);
      await tapImport(tester, find.text('Cancel'));
      await tapImport(tester, find.text('Create immutable job'));
      await tapImport(tester, find.text('Create job'));
      expect(server.jobs, hasLength(1));
      expect(find.textContaining('pending 1'), findsOneWidget);
      await tapImport(tester, find.text('Process next 5 pending'));
      expect(find.text('Server status: completed'), findsOneWidget);
      expect(find.textContaining('applied 1'), findsOneWidget);
      expect(words.requests, isEmpty);
      await clean(tester);
    },
  );
  testWidgets('leaving an unfinished plan warns and cancel keeps the plan', (
    tester,
  ) async {
    await start(tester);
    await tapImport(tester, find.text('Select JSON file'));
    await tapImport(tester, find.byTooltip('Back to workspace'));
    expect(find.text('Leave unfinished import?'), findsOneWidget);
    await tapImport(tester, find.text('Cancel'));
    expect(find.text('Selected: fixture.json'), findsOneWidget);
    await tapImport(tester, find.byTooltip('Back to workspace'));
    await tapImport(tester, find.text('Leave imports'));
    expect(find.text('Open imports'), findsOneWidget);
    expect(server.jobs, isEmpty);
    await clean(tester);
  });
  testWidgets(
    'existing checkpoint resumes by status without selecting or uploading a file',
    (tester) async {
      final c = ImportController(
        uid: 'bob',
        client: server.client(),
        session: storage,
      );
      c.load(pickedFile());
      await c.preview();
      await c.create();
      c.dispose();
      final creates = server.requests
          .where((r) => r['action'] == 'create')
          .length;
      await start(tester);
      expect(find.textContaining('Job ID:'), findsOneWidget);
      await tapImport(tester, find.text('Refresh job status'));
      expect(find.text('Process next 5 pending'), findsOneWidget);
      expect(
        server.requests.where((r) => r['action'] == 'create').length,
        creates,
      );
      await clean(tester);
    },
  );
  testWidgets('receipts have explicit bounded next and previous pages', (
    tester,
  ) async {
    final c = ImportController(
      uid: 'bob',
      client: server.client(),
      session: storage,
    );
    c.load(
      pickedFile(
        List.generate(
          28,
          (i) => {
            'itemId': 'skip-${i.toString().padLeft(2, '0')}',
            'decision': 'skip',
          },
        ),
      ),
    );
    await c.preview();
    await c.create();
    c.dispose();
    await start(tester);
    await tapImport(tester, find.text('Refresh job status'));
    expect(find.text('Receipts 1–25 of 28'), findsOneWidget);
    expect(find.text('skip-27 · skip · skipped'), findsNothing);
    await tapImport(tester, find.text('Next receipts'));
    expect(find.text('Receipts 26–28 of 28'), findsOneWidget);
    expect(find.text('skip-27 · skip · skipped'), findsOneWidget);
    await tapImport(tester, find.text('Previous receipts'));
    expect(find.text('Receipts 1–25 of 28'), findsOneWidget);
    await clean(tester);
  });
  testWidgets(
    'target revision adoption is an explicit choice after loading current content',
    (tester) async {
      words.words['word-target'] = fixtureWord(id: 'word-target', revision: 7);
      await start(tester);
      await tapImport(tester, find.text('Select JSON file'));
      await tapImport(tester, find.text('Row 1: row-1 · create'));
      await tapImport(tester, find.text('Choose action / target'));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('update').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Target word ID'),
        'word-target',
      );
      await tapImport(tester, find.text('Load current target'));
      expect(find.textContaining('Current revision 7'), findsOneWidget);
      await tapImport(tester, find.text('Use this displayed revision'));
      await tapImport(tester, find.text('Apply choice'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await tapImport(tester, find.text('Run server dry run'));
      final row = server.requests.last['import']['items'][0];
      expect(row['decision'], 'update');
      expect(row['wordId'], 'word-target');
      expect(row['expectedRevision'], 7);
      expect(words.requests, isEmpty);
      await clean(tester);
    },
  );
  testWidgets('import preview adapts to a narrow viewport without overflow', (
    tester,
  ) async {
    await start(tester);
    await tester.binding.setSurfaceSize(const Size(390, 700));
    await tester.pumpAndSettle();
    await tapImport(tester, find.text('Select JSON file'));
    await tapImport(tester, find.text('Run server dry run'));
    await tapImport(tester, find.text('Row 1: row-1 · create'));
    expect(tester.takeException(), isNull);
    await clean(tester);
  });
  testWidgets(
    'role-denied shell never creates an import client or exposes import navigation',
    (tester) async {
      repository.allowAdmin = false;
      var created = 0;
      await tester.pumpWidget(
        AdminApp(
          repository: repository,
          vocabularyFactory: (_, _) => words,
          importFactory: (_, _) {
            created++;
            return server.client();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('JSON imports'), findsNothing);
      expect(created, 0);
      await clean(tester);
    },
  );
}
