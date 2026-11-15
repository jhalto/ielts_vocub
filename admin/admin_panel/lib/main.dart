import 'package:app_auth/app_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:firebase_bootstrap/firebase_bootstrap.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeFirebase(DefaultFirebaseOptions.web);
  runApp(const AdminApp());
}

/// Administrator access requires an online trusted-role check.
class AdminApp extends StatelessWidget {
  const AdminApp({super.key, this.repository});
  final AuthRepository? repository;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vocabulary Administration',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: AuthShell(
      repository: repository ?? FirebaseAuthRepository(),
      adminOnly: true,
    ),
  );
}
