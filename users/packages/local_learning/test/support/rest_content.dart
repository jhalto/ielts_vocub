// Test-only public Firestore REST adapter. Production uses FlutterFire queries.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:local_learning/local_learning.dart';

class RestContentSource implements ContentFeedSource {
  RestContentSource(this.host) {
    final uri = Uri.parse('http://$host');
    if (!['127.0.0.1', 'localhost'].contains(uri.host)) {
      throw StateError('Loopback emulator required');
    }
  }
  final String host;
  final client = http.Client();
  final documentRoot = 'projects/demo-vocabulary/databases/(default)/documents';
  int fullPages = 0;
  Future<void> Function()? onManifest, onPage, afterPublished;
  Object? decodeValue(Map<String, dynamic> value) {
    if (value.containsKey('integerValue')) {
      return int.parse(value['integerValue'] as String);
    }
    if (value.containsKey('doubleValue')) return value['doubleValue'];
    if (value.containsKey('booleanValue')) return value['booleanValue'];
    if (value.containsKey('stringValue')) return value['stringValue'];
    if (value.containsKey('timestampValue')) return value['timestampValue'];
    if (value.containsKey('referenceValue')) return value['referenceValue'];
    if (value.containsKey('nullValue')) return null;
    if (value.containsKey('arrayValue')) {
      return ((value['arrayValue'] as Map)['values'] as List? ?? [])
          .map((v) => decodeValue(Map<String, dynamic>.from(v as Map)))
          .toList();
    }
    if (value.containsKey('mapValue')) {
      return decodeFields(
        Map<String, dynamic>.from(
          (value['mapValue'] as Map)['fields'] as Map? ?? {},
        ),
      );
    }
    throw const FormatException('Unsupported emulator fixture value');
  }

  Map<String, dynamic> decodeFields(Map<String, dynamic> fields) => fields.map(
    (k, v) => MapEntry(k, decodeValue(Map<String, dynamic>.from(v as Map))),
  );
  Future<Map<String, dynamic>> document(String path) async {
    final response = await client.get(
      Uri.parse('http://$host/v1/$documentRoot/$path'),
    );
    if (response.statusCode != 200) {
      throw SyncFailure('test-firestore-${response.statusCode}');
    }
    return decodeFields(
      Map<String, dynamic>.from(
        (jsonDecode(response.body) as Map)['fields'] as Map,
      ),
    );
  }

  @override
  Future<ContentSnapshot> manifest() async {
    await onManifest?.call();
    return ContentSnapshot.fromJson(await document('contentManifest/current'));
  }

  Map<String, dynamic> filter(
    String field,
    String op,
    Map<String, dynamic> value,
  ) => {
    'fieldFilter': {
      'field': {'fieldPath': field},
      'op': op,
      'value': value,
    },
  };
  Future<List<Map<String, dynamic>>> query(
    Map<String, dynamic> structured,
  ) async {
    final response = await client.post(
      Uri.parse('http://$host/v1/$documentRoot:runQuery'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'structuredQuery': structured}),
    );
    if (response.statusCode != 200) {
      throw SyncFailure('test-firestore-query-${response.statusCode}');
    }
    final rows = jsonDecode(response.body) as List;
    return rows.where((r) => (r as Map).containsKey('document')).map((r) {
      final document = Map<String, dynamic>.from(r['document'] as Map);
      return {
        'id': (document['name'] as String).split('/').last,
        ...decodeFields(Map<String, dynamic>.from(document['fields'] as Map)),
      };
    }).toList();
  }

  Map<String, dynamic> publicQuery(List<Map<String, dynamic>> extra) => {
    'from': [
      {'collectionId': 'words'},
    ],
    'where': {
      'compositeFilter': {
        'op': 'AND',
        'filters': [
          filter('isPublished', 'EQUAL', {'booleanValue': true}),
          filter('isRetired', 'EQUAL', {'booleanValue': false}),
          ...extra,
        ],
      },
    },
    'orderBy': [
      {
        'field': {'fieldPath': '__name__'},
        'direction': 'ASCENDING',
      },
    ],
    'limit': 100,
  };
  @override
  Future<List<VocabularyWord>> page(Category? category, String? afterId) async {
    fullPages++;
    await onPage?.call();
    final q = publicQuery([
      if (category != null)
        filter('category', 'EQUAL', {'stringValue': category.name}),
    ]);
    if (afterId != null) {
      q['startAt'] = {
        'values': [
          {'referenceValue': '$documentRoot/words/$afterId'},
        ],
        'before': false,
      };
    }
    return (await query(q)).map(VocabularyWord.fromJson).toList();
  }

  @override
  Future<List<ContentChange>> changes(
    int afterRevision,
    int throughRevision,
  ) async {
    final values = await query({
      'from': [
        {'collectionId': 'contentChanges'},
      ],
      'orderBy': [
        {
          'field': {'fieldPath': '__name__'},
          'direction': 'ASCENDING',
        },
      ],
      'startAt': {
        'values': [
          {
            'referenceValue':
                '$documentRoot/contentChanges/${afterRevision.toString().padLeft(16, '0')}',
          },
        ],
        'before': false,
      },
      'endAt': {
        'values': [
          {
            'referenceValue':
                '$documentRoot/contentChanges/${throughRevision.toString().padLeft(16, '0')}',
          },
        ],
        'before': false,
      },
      'limit': 2,
    });
    return values.map((data) {
      final value = Map<String, dynamic>.from(data);
      final id = value.remove('id') as String;
      return ContentChange.fromJson(id, value);
    }).toList();
  }

  @override
  Future<List<VocabularyWord>> publishedWords(List<String> ids) async {
    if (ids.isEmpty) return [];
    try {
      final result = (await query(
        publicQuery([
          filter('__name__', 'IN', {
            'arrayValue': {
              'values': ids
                  .map((id) => {'referenceValue': '$documentRoot/words/$id'})
                  .toList(),
            },
          }),
        ]),
      )).map(VocabularyWord.fromJson).toList();
      await afterPublished?.call();
      return result;
    } on SyncFailure catch (e) {
      if (e.code == 'test-firestore-query-403') {
        throw const ContentFailure('content-public-query-unavailable');
      }
      rethrow;
    }
  }

  /// Only this guarded demo fixture uses the emulator's owner bypass to simulate
  /// a pruned/corrupt feed. This is never part of the application source.
  Future<void> maintenance(
    String path, {
    Map<String, int>? fields,
    bool delete = false,
  }) async {
    final url = Uri.parse(
      'http://$host/v1/$documentRoot/$path${fields == null ? '' : '?${fields.keys.map((k) => 'updateMask.fieldPaths=$k').join('&')}'}',
    );
    final headers = {
      'Authorization': 'Bearer owner',
      'Content-Type': 'application/json',
    };
    final response = delete
        ? await client.delete(url, headers: headers)
        : await client.patch(
            url,
            headers: headers,
            body: jsonEncode({
              'fields': fields!.map(
                (k, v) => MapEntry(k, {'integerValue': '$v'}),
              ),
            }),
          );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'Demo fixture maintenance failed: ${response.statusCode}',
      );
    }
  }

  void close() => client.close();
}
