import 'package:app_auth/app_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:admin_panel/main.dart';
import 'package:admin_panel/features/imports/platform_types.dart';
import 'package:admin_panel/features/users/user_page.dart';

import '../../../users/packages/app_auth/test/support/fake_repository.dart';
import 'support/fake_user_admin.dart';
import 'support/fake_vocabulary.dart';

class UserRoleRepository extends FakeAuthRepository {
  UserRoleRepository() : super(initial: bob) {
    allowAdmin = true;
  }
  String grantedRole = 'super_admin';
  @override
  Future<String> checkAdmin() async {
    if (!allowAdmin) return super.checkAdmin();
    return grantedRole;
  }
}

Future<void> userTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  late FakeUserAdmin server;
  late UserRoleRepository repository;
  late AuthController auth;
  late MemoryImportSession storage;
  setUp(() async {
    server = FakeUserAdmin();
    repository = UserRoleRepository();
    auth = AuthController(repository, adminOnly: true);
    storage = MemoryImportSession();
    await Future<void>.delayed(Duration.zero);
  });
  Future<void> start(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => UserAdminPage(
                    uid: 'bob',
                    auth: auth,
                    client: server.client(),
                    session: storage,
                  ),
                ),
              ),
              child: const Text('Open users'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await userTap(tester, find.text('Open users'));
  }

  Future<void> select(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Exact UID or email'),
      'target',
    );
    await userTap(tester, find.text('Look up account'));
  }

  Future<void> reason(WidgetTester tester) => tester.enterText(
    find.widgetWithText(TextField, 'Change reason (5–500 characters)'),
    'Reviewed synthetic account request',
  );
  Future<void> change(WidgetTester tester) async {
    await reason(tester);
    await userTap(tester, find.text('Disable account'));
    await userTap(tester, find.text('Confirm change'));
  }

  Future<void> clean(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    await repository.close();
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets(
    'super-admin navigation opens one guarded client without automatically scanning users',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      var clients = 0;
      await tester.pumpWidget(
        AdminApp(
          repository: repository,
          vocabularyFactory: (_, _) => FakeVocabulary(),
          userAdminFactory: (_, _) {
            clients++;
            return server.client();
          },
        ),
      );
      await tester.pumpAndSettle();
      await userTap(tester, find.text('User management'));
      expect(find.text('Exact UID or email'), findsOneWidget);
      expect(clients, 1);
      expect(server.requests, isEmpty);
      await tester.binding.setSurfaceSize(const Size(700, 800));
      await tester.pumpAndSettle();
      expect(clients, 1);
      expect(tester.takeException(), isNull);
      await clean(tester);
    },
  );
  testWidgets(
    'only current super admins see navigation and no user client is built for managers',
    (tester) async {
      repository.grantedRole = 'content_manager';
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      var clients = 0;
      await tester.pumpWidget(
        AdminApp(
          repository: repository,
          vocabularyFactory: (_, _) => FakeVocabulary(),
          userAdminFactory: (_, _) {
            clients++;
            return server.client();
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('User management'), findsNothing);
      expect(find.text('JSON imports'), findsOneWidget);
      expect(clients, 0);
      expect(server.requests, isEmpty);
      await clean(tester);
    },
  );
  testWidgets(
    'exact lookup exposes only allowlisted details and explains revision-zero ambiguity',
    (tester) async {
      server.users['target']!.addAll({
        'passwordHash': 'DO_NOT_SHOW',
        'customClaims': {'secret': 'DO_NOT_SHOW'},
      });
      await start(tester);
      await select(tester);
      expect(find.text('UID: target'), findsOneWidget);
      expect(find.text('Trusted Auth role: student'), findsOneWidget);
      expect(
        find.textContaining('legacy or initial bootstrap'),
        findsOneWidget,
      );
      expect(find.textContaining('DO_NOT_SHOW'), findsNothing);
      expect(server.operations, isEmpty);
      await clean(tester);
    },
  );
  testWidgets(
    'required reason and cancelled confirmation cannot mutate an account',
    (tester) async {
      await start(tester);
      await select(tester);
      await userTap(tester, find.text('Disable account'));
      expect(server.operations, isEmpty);
      expect(find.textContaining('Enter a reason of 5–500'), findsOneWidget);
      await reason(tester);
      await userTap(tester, find.text('Disable account'));
      expect(find.text('Confirm account change?'), findsOneWidget);
      await userTap(tester, find.text('Cancel'));
      expect(server.operations, isEmpty);
      await userTap(tester, find.text('Disable account'));
      await userTap(tester, find.text('Confirm change'));
      expect(find.textContaining('Server-confirmed complete.'), findsOneWidget);
      expect(find.textContaining('Target must sign in again'), findsOneWidget);
      expect(server.operations, hasLength(1));
      await clean(tester);
    },
  );
  testWidgets(
    'role assignment is an explicit approved choice with confirmation',
    (tester) async {
      await start(tester);
      await select(tester);
      await reason(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('requested-student')),
      );
      await tester.tap(find.byKey(const ValueKey('requested-student')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('content_manager').last);
      await tester.pumpAndSettle();
      await userTap(tester, find.text('Confirm role change'));
      expect(server.operations, isEmpty);
      await userTap(tester, find.text('Confirm change'));
      expect(
        server.requests.lastWhere((r) => r['action'] == 'setRole')['role'],
        'content_manager',
      );
      await clean(tester);
    },
  );
  testWidgets(
    'pending success needs explicit same-operation resume and never claims completion early',
    (tester) async {
      server.mode = 'pending';
      await start(tester);
      await select(tester);
      await change(tester);
      expect(find.textContaining('State: pending'), findsOneWidget);
      expect(find.textContaining('Server-confirmed complete.'), findsNothing);
      await userTap(tester, find.text('Resume same operation'));
      expect(find.text('Resume the same frozen operation?'), findsOneWidget);
      await userTap(tester, find.text('Cancel'));
      expect(server.requests.where((r) => r['action'] == 'resume'), isEmpty);
      await userTap(tester, find.text('Resume same operation'));
      await userTap(tester, find.text('Resume same operation').last);
      expect(find.textContaining('Server-confirmed complete.'), findsOneWidget);
      await clean(tester);
    },
  );
  testWidgets(
    'recovery-required state directs trusted operators and supplies no browser bypass',
    (tester) async {
      server.mode = 'recovery_required';
      await start(tester);
      await select(tester);
      await change(tester);
      expect(find.textContaining('Trusted recovery required.'), findsOneWidget);
      expect(find.text('Resume same operation'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Unlock'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Force'), findsNothing);
      expect(find.text('Refresh operation status'), findsOneWidget);
      await clean(tester);
    },
  );
  testWidgets('empty filtered pages keep an enabled next-page control', (
    tester,
  ) async {
    server.pages = [
      {
        'schemaVersion': 1,
        'users': [],
        'scanned': 25,
        'nextCursor': 'cursor-1',
      },
      {
        'schemaVersion': 1,
        'users': [userDto('target')],
        'scanned': 1,
        'nextCursor': null,
      },
    ];
    await start(tester);
    await userTap(tester, find.text('Apply filters / restart directory'));
    expect(
      find.textContaining('No matches on this page. More accounts'),
      findsOneWidget,
    );
    await userTap(tester, find.text('Next page'));
    expect(find.text('Synthetic target · student'), findsOneWidget);
    await userTap(tester, find.text('View account'));
    expect(find.text('UID: target'), findsOneWidget);
    await clean(tester);
  });
  testWidgets(
    'unsubmitted reasons trigger a leave warning and cancel preserves them',
    (tester) async {
      await start(tester);
      await select(tester);
      await reason(tester);
      await userTap(tester, find.byTooltip('Back to workspace'));
      expect(
        find.text('Leave unfinished user administration?'),
        findsOneWidget,
      );
      await userTap(tester, find.text('Cancel'));
      expect(find.text('UID: target'), findsOneWidget);
      await userTap(tester, find.byTooltip('Back to workspace'));
      await userTap(tester, find.text('Leave user management'));
      expect(find.text('Open users'), findsOneWidget);
      expect(server.operations, isEmpty);
      await clean(tester);
    },
  );
  testWidgets(
    'loss of super-admin role hides private data and erases owned recovery',
    (tester) async {
      server.mode = 'pending';
      await start(tester);
      await select(tester);
      await change(tester);
      expect(storage.value, isNotNull);
      repository.grantedRole = 'content_manager';
      await auth.refreshProfile();
      await tester.pumpAndSettle();
      expect(
        find.text('Current super-admin authorization is required.'),
        findsOneWidget,
      );
      expect(find.text('UID: target'), findsNothing);
      expect(find.text('Resume same operation'), findsNothing);
      expect(storage.value, isNull);
      await clean(tester);
    },
  );
  testWidgets(
    'self changes are visibly disabled and narrow layouts remain usable',
    (tester) async {
      await start(tester);
      await tester.binding.setSurfaceSize(const Size(390, 740));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Exact UID or email'),
        'bob',
      );
      await userTap(tester, find.text('Look up account'));
      expect(
        find.textContaining('Self role/status changes are prohibited.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Disable account'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await clean(tester);
    },
  );
}
