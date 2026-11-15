import 'package:material_ui/material_ui.dart';
import 'package:app_auth/app_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_repository.dart';

void main() {
  testWidgets('guest path works without Firebase and never records progress', (
    tester,
  ) async {
    final repo = FakeAuthRepository();
    await tester.pumpWidget(MaterialApp(home: AuthShell(repository: repo)));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Google sign-in is not available in this Windows build. Use email and password.',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Continue as guest'));
    await tester.tap(find.text('Continue as guest'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome, guest'), findsOneWidget);
    expect(repo.current, isNull);
    await tester.pumpWidget(const SizedBox());
    await repo.close();
  });
  testWidgets('registration validates confirmation and preserves fields', (
    tester,
  ) async {
    final repo = FakeAuthRepository();
    await tester.pumpWidget(MaterialApp(home: AuthShell(repository: repo)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Learner');
    await tester.enterText(fields.at(1), 'learner@example.com');
    await tester.enterText(fields.at(2), 'test-password');
    await tester.enterText(fields.at(3), 'different');
    await tester.ensureVisible(find.text('Register'));
    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    expect(find.text('Passwords must match.'), findsOneWidget);
    expect(repo.current, isNull);
    await tester.pumpWidget(const SizedBox());
    await repo.close();
  });
}
