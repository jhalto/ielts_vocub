import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import '../words/models.dart';
import '../words/repository.dart';
import 'models.dart';

class ImportClient {
  ImportClient({
    required this.credentials,
    required this.endpoint,
    http.Client? client,
    this.onDenied,
    Future<void> Function(Duration)? delay,
  }) : client = client ?? http.Client(),
       delay = delay ?? Future<void>.delayed;
  final AdminCredentials credentials;
  final Uri endpoint;
  final http.Client client;
  final void Function()? onDenied;
  final Future<void> Function(Duration) delay;
  bool _closed = false;
  Future<Map<String, dynamic>> send(
    String uid,
    String body, {
    required bool Function() active,
  }) async {
    if (utf8.encode(body).length > importByteLimit) {
      throw const PublicationFailure(
        'payload-too-large',
        'The complete request exceeds 512 KiB. Reduce this file.',
      );
    }
    void check() {
      if (_closed || credentials.uid != uid || !active()) {
        throw const PublicationFailure(
          'account-changed',
          'This request belongs to an inactive session.',
          denied: true,
        );
      }
    }

    var refresh = false;
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        check();
        try {
          final token = await credentials
              .token(refresh)
              .timeout(const Duration(seconds: 20));
          check();
          final response = await client
              .post(
                endpoint,
                headers: {
                  'Authorization': 'Bearer $token',
                  'Content-Type': 'application/json',
                },
                body: body,
              )
              .timeout(const Duration(seconds: 65));
          check();
          if (response.statusCode == 401 && !refresh && attempt < 2) {
            refresh = true;
            continue;
          }
          Map<String, dynamic> data;
          try {
            data = jsonObject(jsonDecode(response.body));
          } catch (_) {
            throw PublicationFailure(
              'invalid-response',
              'The outcome could not be confirmed. Check status or retry the unchanged request.',
              retryable: true,
              denied: response.statusCode == 401 || response.statusCode == 403,
            );
          }
          if (response.statusCode == 200 ||
              (response.statusCode == 422 &&
                  data['code'] == 'import-invalid')) {
            return data;
          }
          final code = data['code'] is String
              ? data['code'] as String
              : 'service-unavailable';
          throw PublicationFailure(
            code,
            importMessage(code),
            denied: response.statusCode == 401 || response.statusCode == 403,
            retryable:
                response.statusCode >= 500 ||
                response.statusCode == 429 ||
                code == 'transaction-contention',
          );
        } on TimeoutException {
          if (attempt == 2) rethrow;
        } on http.ClientException {
          if (attempt == 2) rethrow;
        } on PublicationFailure catch (e) {
          if (!e.retryable ||
              e.denied ||
              e.code == 'rate-limited' ||
              attempt == 2) {
            rethrow;
          }
        }
        await delay(Duration(seconds: 1 << attempt));
        check();
      }
      throw const PublicationFailure(
        'network',
        'Request interrupted. Check status before changing anything.',
        retryable: true,
      );
    } on TimeoutException {
      throw const PublicationFailure(
        'network',
        'Request timed out and may have committed. Check status or retry the same job.',
        retryable: true,
      );
    } on http.ClientException {
      throw const PublicationFailure(
        'network',
        'Connection interrupted. Check status or retry the same job.',
        retryable: true,
      );
    } on FirebaseAuthException {
      onDenied?.call();
      throw const PublicationFailure(
        'unauthenticated',
        'Refresh your administrator session.',
        denied: true,
      );
    } on PublicationFailure catch (e) {
      // Attestation needs operator setup, not a role refresh that could hide
      // this actionable error behind a successful administrator recheck.
      if (e.denied &&
          !['app-check-required', 'app-check-invalid'].contains(e.code)) {
        onDenied?.call();
      }
      rethrow;
    }
  }

  void close() {
    _closed = true;
    client.close();
  }
}

String importMessage(String code) => switch (code) {
  'rate-limited' =>
    'Request quota reached. Wait at least a minute before retrying.',
  'revision-conflict' => 'A newer edit exists. Use a new plan with a deliberately reviewed current revision.',
  'import-job-id-reused' => 'This job ID already has a different plan. Look up its status; do not overwrite it.',
  'import-job-not-found' => 'Job not found for this account. An unconfirmed creation can still be retried unchanged.',
  'duplicate-spelling' || 'word-exists' => 'This spelling or ID already exists. Choose the target explicitly in a new plan.',
  'permission-denied' ||
  'claims-stale' ||
  'email-unverified' ||
  'session-revoked' ||
  'unauthenticated' =>
    'Administrator access could not be verified. Refresh your session.',
  'app-check-required' || 'app-check-invalid' =>
    'This environment requires app attestation. Contact the operator.',
  _ =>
    'Request could not complete ($code). Local choices and any frozen job are preserved.',
};
typedef ImportFactory = ImportClient Function(
  String uid,
  void Function() onDenied,
);
ImportClient createImportClient(String uid, void Function() onDenied) {
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
  return ImportClient(
    credentials: FirebaseCredentials(FirebaseAuth.instance),
    endpoint: Uri.parse(
      emulator
          ? 'http://$host:$port/$project/$region/importApi'
          : 'https://$region-$project.cloudfunctions.net/importApi',
    ),
    onDenied: onDenied,
  );
}
