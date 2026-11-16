import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:admin_panel/features/imports/client.dart';
import 'package:admin_panel/features/imports/platform_types.dart';
import 'package:admin_panel/features/words/repository.dart';

import 'fake_vocabulary.dart';

class ImportCredentials implements AdminCredentials {
  @override
  String? uid = 'bob';
  final refreshes = <bool>[];
  @override
  Future<String> token(bool forceRefresh) async {
    refreshes.add(forceRefresh);
    return forceRefresh ? 'fresh' : 'demo';
  }
}

Map<String, dynamic> importRow([String id = 'row-1']) => {
  'itemId': id,
  'decision': 'create',
  'wordId': 'word-$id',
  'expectedRevision': 0,
  'content': fixtureDraft('Synthetic $id').toJson(),
};
PickedJson pickedFile([List<Map<String, dynamic>>? rows]) => PickedJson(
  'fixture.json',
  'application/json',
  Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'items': rows ?? [importRow()],
      }),
    ),
  ),
);

class FakeImports {
  final credentials = ImportCredentials();
  final requests = <Map<String, dynamic>>[], bodies = <String>[];
  final jobs = <String, Map<String, dynamic>>{};
  final failed = <String>{};
  int loseCreate = 0, loseProcess = 0;
  bool publishedTargets = false, failSecondPage = false;
  String? pendingError;
  Future<http.Response> Function(http.Request)? override;
  final waits = <Duration>[];
  ImportClient client({void Function()? onDenied}) => ImportClient(
    credentials: credentials,
    endpoint: Uri.parse('https://demo.test/importApi'),
    onDenied: onDenied,
    delay: (d) async {
      waits.add(d);
    },
    client: MockClient(handle),
  );
  Map<String, dynamic> summary(String id) {
    final items = jobs[id]!['receipts'] as List<Map<String, dynamic>>;
    final counts = {
      'total': items.length,
      'pending': 0,
      'applied': 0,
      'skipped': 0,
      'failed': 0,
    };
    for (final row in items) {
      counts[row['state'] as String] = counts[row['state']]! + 1;
    }
    return {
      'schemaVersion': 1,
      'jobId': id,
      'status': counts['pending']! > 0
          ? 'ready'
          : counts['failed']! > 0
          ? 'completed_with_errors'
          : 'completed',
      'counts': counts,
    };
  }

  Future<http.Response> handle(http.Request request) async {
    final data = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add(data);
    bodies.add(request.body);
    if (override != null) return override!(request);
    final id = data['jobId'] as String?;
    if (data['action'] == 'preview') {
      final rows = (data['import']['items'] as List)
          .cast<Map<String, dynamic>>();
      final items = rows.indexed.map((entry) {
        final row = entry.$2, update = row['decision'] == 'update';
        return {
          'index': entry.$1,
          'itemId': row['itemId'],
          'decision': row['decision'],
          'errors': publishedTargets && update && row['reviewed'] != true
              ? ['review-required']
              : <String>[],
          'content': row['content'],
          'normalizedSpelling': row['content']?['spelling']
              ?.toString()
              .toLowerCase(),
          'publishable': row['decision'] == 'skip' ? null : true,
          'existing': update
              ? {
                  'wordId': row['wordId'],
                  'revision': 2,
                  'isPublished': publishedTargets,
                  'isRetired': false,
                }
              : null,
          'duplicateWordId': null,
        };
      }).toList();
      return jsonResponse(
        jsonEncode({
          'schemaVersion': 1,
          'valid': items.every((r) => (r['errors'] as List).isEmpty),
          'items': items,
        }),
        200,
      );
    }
    if (data['action'] == 'create') {
      jobs.putIfAbsent(
        id!,
        () => {
          'file': data['import'],
          'receipts':
              ((data['import']['items'] as List).cast<Map<String, dynamic>>())
                  .indexed
                  .map(
                    (entry) => <String, dynamic>{
                      'itemId': entry.$2['itemId'],
                      'index': entry.$1,
                      'decision': entry.$2['decision'],
                      'state': entry.$2['decision'] == 'skip'
                          ? 'skipped'
                          : 'pending',
                      'wordId': entry.$2['wordId'],
                      'attempts': 0,
                      'result': entry.$2['decision'] == 'skip'
                          ? {'code': 'skipped'}
                          : null,
                      'lastError': null,
                    },
                  )
                  .toList(),
        },
      );
      if (loseCreate-- > 0) {
        throw http.ClientException('Synthetic lost acknowledgement');
      }
      return jsonResponse(jsonEncode({...summary(id), 'replayed': false}), 200);
    }
    if (id == null || !jobs.containsKey(id)) {
      return jsonResponse('{"code":"import-job-not-found"}', 404);
    }
    final rows = jobs[id]!['receipts'] as List<Map<String, dynamic>>;
    if (data['action'] == 'process') {
      final selected = <Map<String, dynamic>>[];
      for (final itemId in data['itemIds'] as List) {
        final row = rows.singleWhere((r) => r['itemId'] == itemId);
        if (row['state'] == 'pending') {
          row['attempts'] = (row['attempts'] as int) + 1;
          if (pendingError != null) {
            row['lastError'] = {'code': pendingError, 'retryable': true};
            selected.add(row);
            break;
          }
          if (failed.contains(itemId)) {
            row['state'] = 'failed';
            row['lastError'] = {
              'code': 'revision-conflict',
              'retryable': false,
            };
          } else {
            row['state'] = 'applied';
            row['result'] = {
              'wordId': row['wordId'],
              'revision': 3,
              'contentRevision': 3,
              'isPublished': false,
              'isRetired': false,
              'replayed': false,
            };
          }
        }
        selected.add(row);
      }
      if (loseProcess-- > 0) {
        throw http.ClientException('Synthetic lost acknowledgement');
      }
      return jsonResponse(jsonEncode({...summary(id), 'items': selected}), 200);
    }
    if (failSecondPage && data['afterItemId'] != null) {
      return jsonResponse('{"code":"service-unavailable"}', 503);
    }
    final sorted = [
      ...rows,
    ]..sort((a, b) => (a['itemId'] as String).compareTo(b['itemId'] as String));
    final after = data['afterItemId'] as String?;
    final page = sorted
        .where(
          (r) => after == null || (r['itemId'] as String).compareTo(after) > 0,
        )
        .take(26)
        .toList();
    return jsonResponse(
      jsonEncode({
        ...summary(id),
        'items': page.take(25).toList(),
        'nextAfterItemId': page.length > 25 ? page[24]['itemId'] : null,
      }),
      200,
    );
  }
}

http.Response jsonResponse(String body, int status) => http.Response(
  body,
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
