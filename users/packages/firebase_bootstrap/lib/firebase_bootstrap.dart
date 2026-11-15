import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Explicit opt-in: emulator traffic uses a demo project, never the live project.
Future<void> initializeFirebase(FirebaseOptions options) async {
  const emulators = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
  const host = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
    defaultValue: 'localhost',
  );
  const authPort = int.fromEnvironment(
    'FIREBASE_AUTH_EMULATOR_PORT',
    defaultValue: 9099,
  );
  const firestorePort = int.fromEnvironment(
    'FIRESTORE_EMULATOR_PORT',
    defaultValue: 8080,
  );
  const functionsPort = int.fromEnvironment(
    'FUNCTIONS_EMULATOR_PORT',
    defaultValue: 5001,
  );
  const region = String.fromEnvironment(
    'FIREBASE_FUNCTIONS_REGION',
    defaultValue: 'us-central1',
  );
  await Firebase.initializeApp(
    options: emulators
        ? const FirebaseOptions(
            apiKey: 'demo-api-key',
            appId: '1:123456789:web:demo',
            messagingSenderId: '123456789',
            projectId: 'demo-vocabulary',
          )
        : options,
  );
  // Drift, not a second persistent Firestore cache, owns student offline state.
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: false,
  );
  if (emulators) {
    await FirebaseAuth.instance.useAuthEmulator(host, authPort);
    FirebaseFirestore.instance.useFirestoreEmulator(host, firestorePort);
    // cloud_functions has no native Windows implementation. Windows sync must
    // use the authenticated HTTPS transport planned in the sync contract.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      FirebaseFunctions.instanceFor(region: region)
          .useFunctionsEmulator(host, functionsPort);
    }
  }
}
