import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../imports/client.dart';
import '../words/models.dart';
import '../words/repository.dart';

/// Reuses the existing bounded, UID-guarded Admin transport without job semantics.
class UserAdminClient {
  UserAdminClient({
    required AdminCredentials credentials,
    required Uri endpoint,
    http.Client? client,
    void Function()? onDenied,
    Future<void> Function(Duration)? delay,
  }) : transport = ImportClient(
         credentials: credentials,
         endpoint: endpoint,
         client: client,
         onDenied: onDenied,
         delay: delay,
       );
  final ImportClient transport;
  Uri get endpoint => transport.endpoint;
  String? get currentUid => transport.credentials.uid;
  Future<Map<String, dynamic>> send(
    String uid,
    String body, {
    required bool Function() active,
  }) async {
    if (utf8.encode(body).length > 16384) {
      throw const PublicationFailure(
        'payload-too-large',
        'This request exceeds the 16 KiB administration limit.',
      );
    }
    try {
      return await transport.send(uid, body, active: active);
    } on PublicationFailure catch (e) {
      throw PublicationFailure(
        e.code,
        userAdminMessage(e.code),
        retryable: e.retryable || e.code == 'administration-busy',
        denied: e.denied,
      );
    }
  }

  void close() => transport.close();
}

String userAdminMessage(String code) => switch (code) {
  'revision-conflict' || 'auth-state-conflict' => 'The target changed. Review a fresh read and confirm a NEW operation; the original payload cannot be rebased.',
  'last-super-admin' => 'The backend refused to remove the last counted active super admin. There is no browser override.',
  'self-change-not-allowed' => 'Self role/status changes are refused. Another managed super admin must act.',
  'administration-busy' => 'Another administration operation is pending. Wait or have an authorized operator inspect its status.',
  'user-admin-initialization-required' ||
  'admin-registry-invalid' ||
  'admin-state-drift' ||
  'unmanaged-super-admin' => 'Managed administration needs trusted operator inspection. Follow docs/user_admin_api.md; do not reset records or initialize from this browser.',
  'target-not-eligible' => 'Administrative grants require an enabled, verified target. Review the current account.',
  'already-in-state' => 'The target already has this state. Refresh its details before another change.',
  'operation-id-reused' => 'This ID belongs to another immutable intent. Keep the ID and ask an operator to identify its receipt.',
  'rate-limited' => 'Request quota reached. Wait at least a minute, then retry the unchanged request.',
  'session-stale' ||
  'session-revoked' ||
  'user-disabled' ||
  'unauthenticated' ||
  'claims-stale' ||
  'administrator-unavailable' ||
  'permission-denied' ||
  'email-unverified' => 'Current managed super-admin access could not be verified. Sign in again after any required fresh-sign-in time.',
  'account-change-pending' => 'This account is quarantined by a pending change. A current eligible administrator must inspect the server operation.',
  'app-check-required' || 'app-check-invalid' =>
    'This environment needs valid app attestation. Contact the operator.',
  'user-not-found' => 'No account matches this exact UID/email.',
  'operation-not-found' => 'No operation matches this key. An unconfirmed change can still be retried unchanged.',
  'invalid-cursor' => 'This continuation is no longer usable. Restart the directory with the chosen filters.',
  _ =>
    'The request could not be confirmed ($code). Keep the original operation ID and inspect status before changing intent.',
};
typedef UserAdminFactory = UserAdminClient Function(
  String uid,
  void Function() onDenied,
);
UserAdminClient createUserAdminClient(String uid, void Function() onDenied) {
  const emulators = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
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
  return UserAdminClient(
    credentials: FirebaseCredentials(FirebaseAuth.instance),
    endpoint: Uri.parse(
      emulators
          ? 'http://$host:$port/$project/$region/userAdminApi'
          : 'https://$region-$project.cloudfunctions.net/userAdminApi',
    ),
    onDenied: onDenied,
  );
}
