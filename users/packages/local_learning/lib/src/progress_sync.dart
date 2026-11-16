import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../local_learning.dart';

class SyncFailure implements Exception {
  const SyncFailure(this.code, {this.retryable = false, this.retryAfter});
  final String code;
  final bool retryable;
  final Duration? retryAfter;
  @override
  String toString() => 'Progress sync: $code';
}

bool validSyncId(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value);
int syncRevision(Object? value) {
  if (value is! int || value < 0 || value >= 9007199254740991) {
    throw const SyncFailure('invalid-response');
  }
  return value;
}

Map<String, dynamic> syncProgress(Object? value, {bool timestamps = false}) {
  if (value is! Map<String, dynamic> ||
      !validSyncId(value['wordId']) ||
      !validSyncId(value['lastOperationId']) ||
      syncRevision(value['revision']) < 1 ||
      !ProgressStatus.values.any((s) => s.wireValue == value['status'])) {
    throw const SyncFailure('invalid-response');
  }
  if (timestamps &&
      ['createdAt', 'updatedAt'].any(
        (key) =>
            value[key] is! String ||
            DateTime.tryParse(value[key] as String) == null,
      )) {
    throw const SyncFailure('invalid-response');
  }
  return {
    for (final key in ['wordId', 'status', 'revision', 'lastOperationId'])
      key: value[key],
  };
}

abstract interface class ProgressCredentials {
  String? get uid;
  Future<String> token(bool refresh);
}

abstract interface class ProgressRemote {
  Future<Map<String, dynamic>> request(String uid, String body);
  void close();
}

class HttpProgressRemote implements ProgressRemote {
  HttpProgressRemote({
    required this.endpoint,
    required this.credentials,
    http.Client? client,
  }) : client = client ?? http.Client();
  final Uri endpoint;
  final ProgressCredentials credentials;
  final http.Client client;
  void _check(String uid) {
    if (credentials.uid != uid) throw const SyncFailure('account-changed');
  }

  @override
  Future<Map<String, dynamic>> request(String uid, String body) async {
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        _check(uid);
        final token = await credentials
            .token(attempt > 0)
            .timeout(const Duration(seconds: 20));
        _check(uid);
        final response = await client
            .post(
              endpoint,
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              body: body,
            )
            .timeout(const Duration(seconds: 70));
        _check(uid);
        if (response.statusCode == 401 && attempt == 0) continue;
        Map<String, dynamic> data;
        try {
          data = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          throw SyncFailure(
            'invalid-response',
            retryable: response.statusCode != 401 && response.statusCode != 403,
          );
        }
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return data;
        }
        final code = data['code'] is String
            ? data['code'] as String
            : 'service-unavailable';
        final permanent = [
          'progress-state-invalid',
          'progress-initialization-required',
          'revision-exhausted',
        ].contains(code);
        throw SyncFailure(
          code,
          retryable:
              !permanent &&
              (response.statusCode >= 500 || response.statusCode == 429),
          retryAfter: response.statusCode == 429
              ? Duration(
                  seconds: max(
                    60,
                    min(
                      300,
                      int.tryParse(response.headers['retry-after'] ?? '') ?? 60,
                    ),
                  ),
                )
              : null,
        );
      }
      throw const SyncFailure('unauthenticated');
    } on TimeoutException {
      throw const SyncFailure('offline', retryable: true);
    } on http.ClientException {
      throw const SyncFailure('offline', retryable: true);
    }
  }

  @override
  void close() => client.close();
}

class SyncView {
  const SyncView(
    this.phase,
    this.pending,
    this.issues,
    this.lastSuccess,
    this.error,
    this.nextRetry,
    this.automatic,
  );
  final String phase;
  final int pending, issues;
  final DateTime? lastSuccess, nextRetry;
  final String? error;
  final bool automatic;
  String get label => switch (phase) {
    'syncing' => 'Syncing',
    'conflict' => 'Conflict requires attention',
    'offline' => 'Offline',
    'failed' => 'Sync failed',
    'synced' => pending == 0 ? 'Up to date' : 'Changes pending',
    _ => pending == 0 ? 'Not synced yet' : 'Changes pending',
  };
}

class ProgressSynchronizer {
  ProgressSynchronizer({
    required this.store,
    required this.uid,
    required this.remote,
    required this.stillAuthorized,
    this.pageSize = 100,
    this.reconcileContent,
    Future<void> Function(Duration)? delay,
  }) : epoch = store.privateEpoch(uid),
       delay = delay ?? Future<void>.delayed;
  final LearningStore store;
  final String uid;
  final ProgressRemote remote;
  final bool Function() stillAuthorized;
  final int epoch, pageSize;
  final Future<void> Function(bool Function() active)? reconcileContent;
  final Future<void> Function(Duration) delay;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  bool _disposed = false;
  bool get active =>
      !_disposed && stillAuthorized() && store.privateEpoch(uid) == epoch;
  void _check() {
    if (!active) throw const SyncFailure('account-changed');
  }

  void _emit() {
    if (active) _changes.add(null);
  }

  Future<Map<String, dynamic>> _request(
    String body, {
    List<Map<String, dynamic>> operations = const [],
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      _check();
      if (operations.isNotEmpty) {
        await store.recordSyncAttempt(uid, operations, active: () => active);
      }
      try {
        final result = await remote.request(uid, body);
        _check();
        return result;
      } on SyncFailure catch (e) {
        if (active && operations.isNotEmpty) {
          await store.recordSyncFailure(
            uid,
            operations,
            e.code,
            active: () => active,
          );
        }
        if (!e.retryable || e.retryAfter != null || attempt == 2) rethrow;
        await delay(
          Duration(milliseconds: (1000 << attempt) + Random().nextInt(250)),
        );
      }
    }
    throw const SyncFailure('service-unavailable');
  }

  Future<void> sync() => store.singleSync(uid, () async {
    if (!active) return;
    final view = await store.syncView(uid);
    if (view.nextRetry != null && DateTime.now().isBefore(view.nextRetry!)) {
      return;
    }
    try {
      await store.setSyncPhase(uid, 'syncing', active: () => active);
      _emit();
      var sent = 0;
      while (sent < 100) {
        _check();
        final ops = await store.prepareSync(
          uid,
          limit: min(25, 100 - sent),
          active: () => active,
        );
        if (ops.isEmpty) break;
        final body =
            '{"action":"upload","operations":[${ops.map((o) => o['request_payload'] as String).join(',')}]}';
        final response = await _request(body, operations: ops);
        await store.acceptSync(uid, ops, response, active: () => active);
        sent += ops.length;
        _emit();
      }
      await _retrieve();
      _check();
      await reconcileContent?.call(() => active);
      _check();
      final current = await store.syncView(uid);
      await store.setSyncPhase(
        uid,
        current.issues > 0
            ? 'conflict'
            : current.pending > 0
            ? 'pending'
            : 'synced',
        active: () => active,
      );
    } catch (e) {
      if (active) {
        final failure = e is SyncFailure
            ? e
            : const SyncFailure('local-or-response-error');
        await store.setSyncPhase(
          uid,
          failure.code == 'offline' ? 'offline' : 'failed',
          error: failure.code,
          nextRetry: failure.retryAfter == null
              ? null
              : DateTime.now().add(failure.retryAfter!),
          active: () => active,
        );
      }
    } finally {
      _emit();
    }
  });

  Future<void> _retrieve() async {
    for (var restart = 0; restart < 3; restart++) {
      final run = newId();
      String? cursor, previous;
      int? revision;
      final cursors = <String>{};
      try {
        for (var page = 0; page < 200; page++) {
          final response = await _request(
            jsonEncode({
              'action': 'list',
              'limit': pageSize,
              'cursor': ?cursor,
            }),
          );
          if (response['schemaVersion'] != 1 ||
              response['progress'] is! List ||
              !response.containsKey('nextCursor')) {
            throw const SyncFailure('invalid-response');
          }
          final nextRevision = syncRevision(response['revision']);
          revision ??= nextRevision;
          if (revision != nextRevision) {
            throw const SyncFailure('invalid-response');
          }
          final values = response['progress'] as List;
          if (values.length > pageSize) {
            throw const SyncFailure('invalid-response');
          }
          final records = values
              .map((v) => syncProgress(v, timestamps: true))
              .toList();
          for (final value in records) {
            final id = value['wordId'] as String;
            if (value['revision'] as int > revision ||
                (previous != null && id.compareTo(previous) <= 0)) {
              throw const SyncFailure('invalid-response');
            }
            previous = id;
          }
          await store.stageProgress(uid, run, records, active: () => active);
          final next = response['nextCursor'];
          if (next == null) {
            await store.commitProgress(
              uid,
              run,
              revision,
              active: () => active,
            );
            return;
          }
          if (next is! String ||
              next.isEmpty ||
              next.length > 1024 ||
              records.isEmpty ||
              !cursors.add(next)) {
            throw const SyncFailure('invalid-response');
          }
          cursor = next;
        }
        throw const SyncFailure('snapshot-too-large');
      } on SyncFailure catch (e) {
        if (e.code != 'progress-snapshot-changed' || restart == 2) rethrow;
      } finally {
        await store.discardProgress(uid, run);
      }
    }
  }

  Future<void> resolve(
    String wordId,
    String expectedLocalOperationId, {
    required bool keepLocal,
  }) async {
    _check();
    if (store.syncRunning(uid)) throw const SyncFailure('sync-in-progress');
    await store.singleSync(uid, () async {
      // Fetch fresh state; a replayed conflict receipt can be older than current progress.
      await _retrieve();
      _check();
      await store.resolveSync(
        uid,
        wordId,
        expectedLocalOperationId,
        keepLocal: keepLocal,
        active: () => active,
      );
      await store.setSyncPhase(uid, 'pending', active: () => active);
      _emit();
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    remote.close();
    unawaited(_changes.close());
  }
}
