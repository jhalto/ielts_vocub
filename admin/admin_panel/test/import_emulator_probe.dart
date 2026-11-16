// Explicitly invoked only by the guarded demo emulator runner; not a normal test filename.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:admin_panel/features/imports/client.dart';
import 'package:admin_panel/features/imports/controller.dart';
import 'package:admin_panel/features/imports/platform_types.dart';
import 'package:admin_panel/features/words/models.dart';
import 'package:admin_panel/features/words/repository.dart';

class DemoCredentials implements AdminCredentials {
  DemoCredentials(this.uid, this.value);
  @override
  final String uid;
  final String value;
  @override
  Future<String> token(bool forceRefresh) async => value;
}

Map<String, dynamic> fixture(String spelling) => {
  'spelling': spelling,
  'pronunciation': 'test',
  'category': 'basic',
  'difficulty': 'easy',
  'ordering': 0,
  'senses': [
    {
      'id': 'sense',
      'partOfSpeech': 'noun',
      'englishMeaning': 'Synthetic test only',
      'bengaliMeaning': 'পরীক্ষা',
      'ordering': 0,
      'examples': [
        {'english': 'First fixture', 'bengali': 'পরীক্ষা'},
        {'english': 'Second fixture', 'bengali': 'পরীক্ষা'},
      ],
    },
  ],
};
Map<String, dynamic> createRow(String id) => {
  'itemId': id,
  'decision': 'create',
  'wordId': 'word-$id',
  'expectedRevision': 0,
  'content': fixture('Synthetic $id'),
};
PickedJson file(List<Map<String, dynamic>> rows) => PickedJson(
  'demo.json',
  'application/json',
  Uint8List.fromList(
    utf8.encode(jsonEncode({'schemaVersion': 1, 'items': rows})),
  ),
);
void main() {
  final config = jsonDecode(
    Platform.environment['VOCAB_IMPORT_DEMO_CONFIG'] ?? '{}',
  ) as Map<String, dynamic>;
  if (config['projectId'] != 'demo-vocabulary' ||
      ![
        '127.0.0.1',
        'localhost',
      ].contains(Uri.parse(config['endpoint'] as String? ?? '').host)) {
    throw StateError('Loopback demo configuration required.');
  }
  final uid = config['uid'] as String;
  ImportClient client({http.Client? transport}) => ImportClient(
    credentials: DemoCredentials(uid, config['token'] as String),
    endpoint: Uri.parse(config['endpoint'] as String),
    client: transport,
    delay: (_) async {},
  );
  test('real Admin controller preserves creation bytes after lost reply, handles published conflict and resumes receipts', () async {
    final transport = http.Client();
    addTearDown(transport.close);
    final creations = <String>[];
    final wrapped = MockClient((request) async {
      final response = await transport.post(
        request.url,
        headers: request.headers,
        body: request.body,
      );
      if (jsonDecode(request.body)['action'] == 'create') {
        creations.add(request.body);
        if (creations.length == 1) {
          throw http.ClientException('Synthetic lost reply');
        }
      }
      return response;
    });
    final storage = MemoryImportSession();
    final c = ImportController(
      uid: uid,
      client: client(transport: wrapped),
      session: storage,
    );
    addTearDown(c.dispose);
    c.load(
      file([
        {
          'itemId': 'edit',
          'decision': 'update',
          'wordId': 'admin-import-existing',
          'expectedRevision': config['seedRevision'],
          'content': fixture('Reviewed candidate'),
          'reviewed': true,
        },
        createRow('admin-new'),
        {'itemId': 'skip', 'decision': 'skip'},
      ]),
    );
    await c.preview();
    expect(c.canCreate, false);
    c.attest(0);
    await c.preview();
    expect(c.canCreate, true, reason: c.error?.code);
    await c.create();
    expect(c.confirmed, true, reason: c.error?.code);
    expect(creations, hasLength(2));
    expect(creations.toSet(), hasLength(1));
    final changed = await transport.post(
      Uri.parse(config['publicationEndpoint'] as String),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config['token']}',
      },
      body: jsonEncode({
        'operationId': 'admin-import-racing-edit',
        'wordId': 'admin-import-existing',
        'action': 'edit',
        'expectedRevision': config['seedRevision'],
        'reviewed': true,
        'content': fixture('Newer demo editor intent'),
      }),
    );
    expect(changed.statusCode, 200);
    await c.processNext();
    expect(c.job!.status, 'completed_with_errors', reason: c.error?.code);
    expect(c.job!.counts['applied'], 1);
    expect(c.job!.counts['failed'], 1);
    expect(c.job!.counts['skipped'], 1);
    expect(
      c.receipts.singleWhere((r) => r.id == 'edit').errorCode,
      'revision-conflict',
    );
    final recovered = ImportController(
      uid: uid,
      client: client(),
      session: storage,
    );
    addTearDown(recovered.dispose);
    await recovered.refresh();
    expect(recovered.receipts, hasLength(3));
    expect(recovered.job!.status, 'completed_with_errors');
    expect(jsonDecode(storage.value!)['body'], isNull);
    final denied = ImportClient(
      credentials: DemoCredentials(
        config['studentUid'] as String,
        config['studentToken'] as String,
      ),
      endpoint: Uri.parse(config['endpoint'] as String),
    );
    addTearDown(denied.close);
    await expectLater(
      denied.send(
        config['studentUid'] as String,
        jsonEncode({'action': 'get', 'jobId': c.jobId}),
        active: () => true,
      ),
      throwsA(
        isA<PublicationFailure>().having((e) => e.denied, 'denied', true),
      ),
    );
  });
  test('real Admin client retrieves every status page and processes only pending items in a resumed job', () async {
    final storage = MemoryImportSession();
    final c = ImportController(uid: uid, client: client(), session: storage);
    addTearDown(c.dispose);
    c.load(
      file([
        ...List.generate(
          26,
          (i) => <String, dynamic>{
            'itemId': 'skip-${i.toString().padLeft(2, '0')}',
            'decision': 'skip',
          },
        ),
        createRow('paged-a'),
        createRow('paged-b'),
      ]),
    );
    await c.preview();
    expect(c.canCreate, true, reason: c.error?.code);
    await c.create();
    expect(c.receipts, hasLength(28), reason: c.error?.code);
    final resumed = ImportController(
      uid: uid,
      client: client(),
      session: storage,
    );
    addTearDown(resumed.dispose);
    await resumed.refresh();
    expect(resumed.receipts, hasLength(28));
    await resumed.processNext();
    expect(resumed.job!.status, 'completed', reason: resumed.error?.code);
    expect(resumed.job!.counts['applied'], 2);
    expect(resumed.job!.counts['skipped'], 26);
    expect(
      resumed.receipts
          .where((r) => r.state == 'applied')
          .every((r) => r.result!['isPublished'] == false),
      true,
    );
  });
}
