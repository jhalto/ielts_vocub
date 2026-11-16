import 'dart:async';

import 'package:app_auth/app_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../features/words/repository.dart';
import 'workspace.dart';
import '../features/imports/client.dart';
import '../features/users/client.dart';

typedef VocabularyFactory = VocabularyRepository Function(
  String uid,
  void Function() onDenied,
);

class AdminGate extends StatefulWidget {
  const AdminGate({
    super.key,
    required this.repository,
    required this.onTheme,
    this.vocabularyFactory,
    this.importFactory,
    this.userAdminFactory,
  });
  final AuthRepository repository;
  final VoidCallback onTheme;
  final VocabularyFactory? vocabularyFactory;
  final ImportFactory? importFactory;
  final UserAdminFactory? userAdminFactory;
  @override
  State<AdminGate> createState() => _AdminGateState();
}

class _AdminGateState extends State<AdminGate> with WidgetsBindingObserver {
  late final AuthController auth;
  @override
  void initState() {
    super.initState();
    auth = AuthController(widget.repository, adminOnly: true);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && auth.identity != null) {
      unawaited(auth.refreshSession());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: auth,
    builder: (context, _) {
      final uid = auth.identity?.uid;
      return Stack(
        children: [
          if (uid != null)
            ExcludeFocus(
              excluding: !auth.canEnter,
              child: Offstage(
                offstage: !auth.canEnter,
                child: TickerMode(
                  enabled: auth.canEnter,
                  child: Navigator(
                    key: ValueKey('authorized-workspace-$uid'),
                    onGenerateRoute: (_) => MaterialPageRoute<void>(
                      builder: (_) => AdminWorkspace(
                        uid: uid,
                        auth: auth,
                        onTheme: widget.onTheme,
                        importFactory: widget.importFactory,
                        userAdminFactory: widget.userAdminFactory,
                        vocabularyFactory:
                            widget.vocabularyFactory ??
                            createVocabularyRepository,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (!auth.canEnter)
            AuthShell(
              repository: widget.repository,
              adminOnly: true,
              controller: auth,
            ),
        ],
      );
    },
  );
}
