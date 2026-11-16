import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

abstract interface class VocabularyRepository {
  Future<WordPage> list(WordFilters filters, {Object? after});
  Future<AdminWord> get(String id);
  Future<MutationAck> mutate(PendingMutation mutation);
  void close();
}

abstract interface class AdminCredentials {
  String? get uid;
  Future<String> token(bool forceRefresh);
}

class FirebaseCredentials implements AdminCredentials {
  FirebaseCredentials(this.auth);
  final FirebaseAuth auth;
  @override
  String? get uid => auth.currentUser?.uid;
  @override
  Future<String> token(bool forceRefresh) async {
    final token = await auth.currentUser?.getIdToken(forceRefresh);
    if (token == null) {
      throw const PublicationFailure(
        'unauthenticated',
        'Sign in again.',
        denied: true,
      );
    }
    return token;
  }
}

class PublicationClient {
  PublicationClient({
    required this.credentials,
    required this.endpoint,
    http.Client? client,
    this.onDenied,
  }) : client = client ?? http.Client();
  final AdminCredentials credentials;
  final Uri endpoint;
  final http.Client client;
  final void Function()? onDenied;
  void _check(String uid) {
    if (credentials.uid != uid) {
      throw const PublicationFailure(
        'account-changed',
        'Account changed. This request belongs to the previous session.',
        denied: true,
      );
    }
  }

  Future<MutationAck> send(PendingMutation mutation) async {
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        _check(mutation.uid);
        final token = await credentials
            .token(attempt > 0)
            .timeout(const Duration(seconds: 20));
        _check(mutation.uid);
        final response = await client
            .post(
              endpoint,
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: mutation.body,
            )
            .timeout(const Duration(seconds: 35));
        _check(mutation.uid);
        if (response.statusCode == 401 && attempt == 0) continue;
        Map<String, dynamic> data;
        try {
          data = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          if (response.statusCode == 401 || response.statusCode == 403) {
            throw const PublicationFailure(
              'permission-denied',
              'Administrator authorization is unavailable. Refresh your session.',
              denied: true,
            );
          }
          throw const PublicationFailure(
            'invalid-response',
            'Server response could not be confirmed. Retry the same operation.',
            retryable: true,
          );
        }
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final expected = jsonDecode(mutation.body) as Map<String, dynamic>;
          if (data['wordId'] != expected['wordId'] ||
              data['revision'] is! int ||
              data['isPublished'] is! bool ||
              data['isRetired'] is! bool) {
            throw const PublicationFailure(
              'invalid-response',
              'Save could not be confirmed. Retry the same operation.',
              retryable: true,
            );
          }
          return MutationAck(
            data['wordId'] as String,
            data['revision'] as int,
            data['isPublished'] as bool,
            data['isRetired'] as bool,
          );
        }
        final code = data['code'] as String? ?? 'service-unavailable';
        final denied = response.statusCode == 401 || response.statusCode == 403;
        throw PublicationFailure(
          code,
          _message(code),
          retryable:
              response.statusCode >= 500 ||
              response.statusCode == 429 ||
              code == 'transaction-contention',
          denied: denied,
        );
      }
      throw const PublicationFailure(
        'unauthenticated',
        'Sign in again.',
        denied: true,
      );
    } on TimeoutException {
      throw const PublicationFailure(
        'network',
        'The request may have completed. Reconnect and retry the same operation.',
        retryable: true,
      );
    } on http.ClientException {
      throw const PublicationFailure(
        'network',
        'Network unavailable. Reconnect and retry the same operation.',
        retryable: true,
      );
    } on FirebaseAuthException {
      onDenied?.call();
      throw const PublicationFailure(
        'unauthenticated',
        'Session expired. Refresh your session.',
        denied: true,
      );
    } on PublicationFailure catch (e) {
      if (e.denied) onDenied?.call();
      rethrow;
    }
  }

  String _message(String code) => switch (code) {
    'revision-conflict' => 'Another editor changed this word. Compare or reload the latest revision before saving.',
    'duplicate-spelling' => 'This spelling is already reserved by another draft, published or retired word.',
    'word-exists' =>
      'This word ID already exists. Reload it before continuing.',
    'review-required' => 'Confirm editorial review before publishing or changing published content.',
    'publication-incomplete' => 'Complete pronunciation, meanings and every bilingual example before publishing.',
    'initialization-required' => 'This dataset requires a trusted migration before publication. Contact the project operator.',
    'content-state-invalid' => 'The server content state needs inspection. Do not reset or overwrite it.',
    'permission-denied' || 'email-unverified' || 'claims-stale' => 'Administrator authorization could not be verified. Refresh your session.',
    'operation-id-reused' => 'The server rejected a reused operation ID. Reload before starting a new operation.',
    'word-retired' => 'Restore this retired word before editing or publishing.',
    'word-not-found' => 'This word is no longer available. Reload the list.',
    'rate-limited' =>
      'Request limit reached. Wait a minute and retry the same operation.',
    'app-check-required' || 'app-check-invalid' =>
      'App attestation is required by this environment. Contact the operator.',
    _ =>
      'Request rejected ($code). Correct the content or refresh before trying again.',
  };
  void close() => client.close();
}

class FirestoreVocabularyRepository implements VocabularyRepository {
  FirestoreVocabularyRepository({
    required this.uid,
    required this.firestore,
    required this.publication,
    required this.credentials,
    this.onDenied,
  });
  final String uid;
  final FirebaseFirestore firestore;
  final PublicationClient publication;
  final AdminCredentials credentials;
  final void Function()? onDenied;
  void _check() {
    if (credentials.uid != uid) {
      throw const PublicationFailure(
        'account-changed',
        'Account changed.',
        denied: true,
      );
    }
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    _check();
    try {
      final result = await action().timeout(const Duration(seconds: 20));
      _check();
      return result;
    } on TimeoutException {
      throw const PublicationFailure(
        'network',
        'Online read timed out. Check your connection and retry.',
      );
    } on FirebaseException catch (e) {
      final denied = ['permission-denied', 'unauthenticated'].contains(e.code);
      if (denied) onDenied?.call();
      throw PublicationFailure(
        e.code,
        e.code == 'failed-precondition'
            ? 'A required Firestore index is missing. Ask the operator to deploy the checked-in indexes.'
            : denied
            ? 'Administrator access is unavailable. Refresh your session.'
            : 'Online read failed. Check your connection and retry.',
        denied: denied,
      );
    } on FormatException {
      throw const PublicationFailure(
        'schema',
        'This word uses an unsupported schema. Ask the operator to migrate it.',
      );
    } on TypeError {
      throw const PublicationFailure(
        'schema',
        'A word has an invalid schema. Ask the operator to inspect it.',
      );
    } on ArgumentError {
      throw const PublicationFailure(
        'schema',
        'A word contains an unsupported enum.',
      );
    }
  }

  @override
  Future<WordPage> list(WordFilters filters, {Object? after}) => _read(
    () async {
      Query<Map<String, dynamic>> query = firestore.collection('words');
      switch (filters.publication) {
        case PublicationFilter.published:
          query = query
              .where('isPublished', isEqualTo: true)
              .where('isRetired', isEqualTo: false);
        case PublicationFilter.draft:
          query = query
              .where('isPublished', isEqualTo: false)
              .where('isRetired', isEqualTo: false);
        case PublicationFilter.retired:
          query = query.where('isRetired', isEqualTo: true);
        case PublicationFilter.all:
          break;
      }
      if (filters.category != null) {
        query = query.where('category', isEqualTo: filters.category!.name);
      }
      if (filters.difficulty != null) {
        query = query.where('difficulty', isEqualTo: filters.difficulty!.name);
      }
      final prefix = filters.prefix.trim();
      if (prefix.isNotEmpty) {
        query = query.where('spelling', isGreaterThanOrEqualTo: prefix);
        final end = prefixEnd(prefix);
        if (end != null) {
          query = query.where('spelling', isLessThan: end);
        }
      }
      query = query.orderBy('spelling').orderBy(FieldPath.documentId).limit(26);
      if (after != null) {
        query = query.startAfterDocument(
          after as DocumentSnapshot<Map<String, dynamic>>,
        );
      }
      final snapshot = await query.get(const GetOptions(source: Source.server));
      final docs = snapshot.docs.take(25).toList();
      return WordPage(
        docs.map((doc) => AdminWord.fromJson(doc.id, doc.data())).toList(),
        hasNext: snapshot.docs.length > 25,
        nextCursor: docs.isEmpty ? null : docs.last,
      );
    },
  );
  @override
  Future<AdminWord> get(String id) => _read(() async {
    final doc = await firestore
        .collection('words')
        .doc(id)
        .get(const GetOptions(source: Source.server));
    if (!doc.exists) {
      throw const PublicationFailure(
        'word-not-found',
        'Word not found. Reload the list.',
      );
    }
    return AdminWord.fromJson(doc.id, doc.data()!);
  });
  @override
  Future<MutationAck> mutate(PendingMutation mutation) =>
      publication.send(mutation);
  @override
  void close() => publication.close();
}

VocabularyRepository createVocabularyRepository(
  String uid,
  void Function() onDenied,
) {
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
  final credentials = FirebaseCredentials(FirebaseAuth.instance);
  final publication = PublicationClient(
    credentials: credentials,
    endpoint: Uri.parse(
      emulator
          ? 'http://$host:$port/$project/$region/contentApi'
          : 'https://$region-$project.cloudfunctions.net/contentApi',
    ),
    onDenied: onDenied,
  );
  return FirestoreVocabularyRepository(
    uid: uid,
    firestore: FirebaseFirestore.instance,
    publication: publication,
    credentials: credentials,
    onDenied: onDenied,
  );
}
