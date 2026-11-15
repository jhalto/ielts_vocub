import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:admin_panel/main.dart';

import '../../../users/packages/app_auth/test/support/fake_repository.dart';

void main() {
  testWidgets('admin login has no registration or guest bypass', (
    tester,
  ) async {
    final repo = FakeAuthRepository();
    await tester.pumpWidget(AdminApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Continue as guest'), findsNothing);
    expect(find.text('Create an account'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await repo.close();
  });
}
