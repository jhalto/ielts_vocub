import 'package:app_auth/app_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:firebase_bootstrap/firebase_bootstrap.dart';

import 'app/admin_gate.dart';
import 'firebase_options.dart';
import 'features/imports/client.dart';
import 'features/users/client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeFirebase(DefaultFirebaseOptions.web);
  runApp(AdminApp(repository: FirebaseAuthRepository()));
}

class AdminApp extends StatefulWidget {
  const AdminApp({
    super.key,
    this.repository,
    this.vocabularyFactory,
    this.importFactory,
    this.userAdminFactory,
  });
  final AuthRepository? repository;
  final VocabularyFactory? vocabularyFactory;
  final ImportFactory? importFactory;
  final UserAdminFactory? userAdminFactory;
  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  late final AuthRepository repository =
      widget.repository ?? FirebaseAuthRepository();
  ThemeMode theme = ThemeMode.system;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Vocabulary Administration',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
    ),
    themeMode: theme,
    home: AdminGate(
      repository: repository,
      vocabularyFactory: widget.vocabularyFactory,
      importFactory: widget.importFactory,
      userAdminFactory: widget.userAdminFactory,
      onTheme: () => setState(
        () =>
            theme = theme == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
      ),
    ),
  );
}
