import 'dart:convert';

import 'package:local_learning/local_learning.dart';

class FakeProgressRemote implements ProgressRemote {
  final records = <String, Map<String, Map<String, dynamic>>>{};
  final receipts = <String, Map<String, dynamic>>{};
  final revisions = <String, int>{};
  final bodies = <String>[];
  final blocked = <String>{};
  Future<void> Function(Map<String, dynamic>)? onUpload;
  Future<void> Function(Map<String, dynamic>)? onList;
  bool loseAcknowledgements = false;
  SyncFailure? failure;
  void put(String uid, String wordId, String status) {
    final revision = (revisions[uid] ?? 0) + 1;
    revisions[uid] = revision;
    (records[uid] ??= {})[wordId] = {
      'wordId': wordId,
      'status': status,
      'revision': revision,
      'lastOperationId': 'remote-$revision',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
    };
  }

  @override
  Future<Map<String, dynamic>> request(String uid, String body) async {
    bodies.add(body);
    if (failure != null) throw failure!;
    final input = jsonDecode(body) as Map<String, dynamic>;
    if (input['action'] == 'upload') {
      await onUpload?.call(input);
      final results = <Map<String, dynamic>>[];
      for (final raw in input['operations'] as List) {
        final op = Map<String, dynamic>.from(raw as Map),
            key = '$uid:${raw['operationId']}';
        final saved = receipts[key];
        if (saved != null) {
          results.add({...saved, 'replayed': true});
          continue;
        }
        final wordId = op['wordId'] as String;
        final current = records[uid]?[wordId];
        final code = blocked.contains(wordId)
            ? 'word-unavailable'
            : (current?['revision'] ?? 0) != op['baseRevision']
            ? 'revision-conflict'
            : 'applied';
        if (code == 'applied') {
          put(uid, wordId, op['desiredStatus'] as String);
          records[uid]![wordId]!['lastOperationId'] = op['operationId'];
        }
        final result = {
          'operationId': op['operationId'],
          'wordId': wordId,
          'code': code,
          'progress': records[uid]?[wordId] == null
              ? null
              : Map<String, dynamic>.from(records[uid]![wordId]!),
          'replayed': false,
        };
        receipts[key] = result;
        results.add(result);
      }
      if (loseAcknowledgements) {
        throw const SyncFailure('offline', retryable: true);
      }
      return {'schemaVersion': 1, 'results': results};
    }
    await onList?.call(input);
    final revision = revisions[uid] ?? 0;
    final cursor = input['cursor'] as String?;
    final start = cursor == null ? 0 : int.parse(cursor.split(':')[1]);
    if (cursor != null && int.parse(cursor.split(':')[0]) != revision) {
      throw const SyncFailure('progress-snapshot-changed');
    }
    final all = (records[uid]?.values.toList() ?? [])
      ..sort(
        (a, b) => (a['wordId'] as String).compareTo(b['wordId'] as String),
      );
    final end = (start + (input['limit'] as int)).clamp(0, all.length);
    return {
      'schemaVersion': 1,
      'revision': revision,
      'progress': all
          .sublist(start, end)
          .map((r) => Map<String, dynamic>.from(r))
          .toList(),
      'nextCursor': end < all.length ? '$revision:$end' : null,
    };
  }

  @override
  void close() {}
}
