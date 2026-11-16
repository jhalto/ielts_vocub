import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:local_learning/local_learning.dart';

class FirebaseProgressCredentials implements ProgressCredentials {
  @override
  String? get uid => FirebaseAuth.instance.currentUser?.uid;
  @override
  Future<String> token(bool refresh) async {
    try {
      final value = await FirebaseAuth.instance.currentUser?.getIdToken(
        refresh,
      );
      if (value == null) throw const SyncFailure('unauthenticated');
      return value;
    } on FirebaseAuthException catch (e) {
      throw SyncFailure(
        e.code == 'network-request-failed' ? 'offline' : e.code,
        retryable: e.code == 'network-request-failed',
      );
    }
  }
}

ProgressRemote createProgressRemote() {
  const emulator = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
  const host = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
    defaultValue: 'localhost',
  );
  const port = int.fromEnvironment(
    'FUNCTIONS_EMULATOR_PORT',
    defaultValue: 5001,
  );
  const region = String.fromEnvironment(
    'FIREBASE_FUNCTIONS_REGION',
    defaultValue: 'us-central1',
  );
  final project = Firebase.app().options.projectId;
  return HttpProgressRemote(
    endpoint: Uri.parse(
      emulator
          ? 'http://$host:$port/$project/$region/progressApi'
          : 'https://$region-$project.cloudfunctions.net/progressApi',
    ),
    credentials: FirebaseProgressCredentials(),
  );
}
