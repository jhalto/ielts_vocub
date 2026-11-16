import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:local_learning/local_learning.dart';

import 'support/rest_content.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Map<String, dynamic> content(VocabularyWord word) => {
  for (final key in [
    'spelling',
    'pronunciation',
    'category',
    'difficulty',
    'ordering',
    'senses',
  ])
    key: word.toJson()[key],
};
Future<void> main() async {
  final config = jsonDecode(
    await stdin.transform(utf8.decoder).join(),
  ) as Map<String, dynamic>;
  final endpoint = Uri.parse(config['publicationEndpoint'] as String);
  if (config['projectId'] != 'demo-vocabulary' ||
      endpoint.scheme != 'http' ||
      endpoint.host != '127.0.0.1' ||
      !endpoint.path.startsWith('/demo-vocabulary/')) {
    throw StateError('Demo fixture required');
  }
  final source = RestContentSource(config['firestoreHost'] as String);
  final client = http.Client();
  final directory = await Directory.systemTemp.createTemp(
    'content-client-emulator-',
  );
  final file = File('${directory.path}/learning.sqlite');
  var db = LearningStore(NativeDatabase(file));
  Future<Map<String, dynamic>> mutate(
    String id,
    String action,
    int revision, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final response = await client.post(
      endpoint,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${config['editorToken']}',
      },
      body: jsonEncode({
        'operationId': newId(),
        'wordId': id,
        'action': action,
        'expectedRevision': revision,
        ...extra,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError(
        'Synthetic publication failed: ${response.statusCode} ${response.body}',
      );
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<VocabularyWord> word(String id) async =>
      (await source.publishedWords([id])).single;
  Future<void> reconcile() =>
      ContentReconciler(db, source).reconcile(active: () => true);
  Future<int> cursor() async =>
      (await db.rows(
            "SELECT revision FROM content_checkpoints WHERE category='basic'",
          )).single['revision']
          as int;
  Future<String> state() async => jsonEncode([
    await db.rows('SELECT * FROM words ORDER BY id'),
    await db.downloads(),
    await db.rows('SELECT * FROM content_checkpoints ORDER BY category'),
  ]);
  try {
    await ContentDownloader(
      db,
      source,
    ).download(Category.basic, cancelled: () => false);
    await ContentDownloader(
      db,
      source,
    ).download(Category.intermediate, cancelled: () => false);
    await db.startSession('demo-learner', Category.basic, Difficulty.easy);
    await db.swipe('demo-learner', 'content-a', false);
    final pending = (await db.prepareSync(
      'demo-learner',
      limit: 25,
      active: () => true,
    )).single;
    final fullBefore = source.fullPages;
    var a = await word('content-a');
    await mutate(a.id, 'edit', a.revision, {
      'reviewed': true,
      'content': {...content(a), 'spelling': 'Edited synthetic content'},
    });
    await reconcile();
    check(
      source.fullPages == fullBefore,
      'Normal edit must use feed, not full snapshots',
    );
    check(
      (await db.browse(
            category: Category.basic,
            difficulty: Difficulty.easy,
          )).single.spelling ==
          'Edited synthetic content',
      'Published edit must reach Drift',
    );
    final draft = await mutate('draft-hidden', 'create', 0, {
      'content': {
        ...content(a),
        'spelling': 'Private synthetic draft',
        'pronunciation': '',
        'senses': [],
      },
    });
    await reconcile();
    var draftExcluded = false;
    try {
      draftExcluded = (await source.publishedWords(['draft-hidden'])).isEmpty;
    } on ContentFailure catch (e) {
      draftExcluded = e.code == 'content-public-query-unavailable';
    }
    check(draftExcluded, 'Public ID query must exclude or deny drafts');
    check(
      (await db.rows("SELECT * FROM words WHERE id='draft-hidden'")).isEmpty,
      'Draft must never enter local content',
    );
    check(await cursor() == draft['revision'], 'Noop must advance cursor');
    a = await word('content-a');
    await mutate(a.id, 'edit', a.revision, {
      'reviewed': true,
      'content': {...content(a), 'category': 'intermediate'},
    });
    await reconcile();
    check(
      (await db.session('demo-learner'))!['queue'].isEmpty,
      'Group move must remove card from old session',
    );
    check(
      (await db.statistics(
            'demo-learner',
            Category.intermediate,
            Difficulty.easy,
          ))['didnt_know'] ==
          1,
      'Group move must preserve learning',
    );
    var b = await word('content-b');
    final retired = await mutate(b.id, 'retire', b.revision);
    await reconcile();
    check(
      (await db.browse(
            category: Category.intermediate,
            difficulty: Difficulty.easy,
          )).length ==
          1,
      'Retire must remove current content',
    );
    final restored = await mutate(b.id, 'restore', retired['revision'] as int);
    await reconcile();
    try {
      check(
        (await source.publishedWords([b.id])).isEmpty,
        'Restore stays draft',
      );
    } on ContentFailure catch (e) {
      check(e.code == 'content-public-query-unavailable', 'Draft reads denied');
    }
    await mutate(b.id, 'publish', restored['revision'] as int, {
      'reviewed': true,
    });
    await reconcile();
    check(
      (await db.browse(
            category: Category.intermediate,
            difficulty: Difficulty.easy,
          )).length ==
          2,
      'Republish must restore same ID',
    );
    a = await word('content-a');
    final hidden = await mutate(a.id, 'unpublish', a.revision);
    await reconcile();
    await mutate(a.id, 'publish', hidden['revision'] as int, {
      'reviewed': true,
    });
    await reconcile();
    a = await word('content-a');
    await mutate(a.id, 'edit', a.revision, {
      'reviewed': true,
      'content': {...content(a), 'category': 'advanced'},
    });
    await reconcile();
    check(
      (await db.downloads()).length == 6,
      'Content refresh must not download unselected advanced category',
    );
    check(
      (await db.browse(
        category: Category.advanced,
        difficulty: Difficulty.easy,
      )).isEmpty,
      'Outside-scope payload must not become active',
    );
    a = await word('content-a');
    await mutate(a.id, 'edit', a.revision, {
      'reviewed': true,
      'content': {...content(a), 'category': 'basic'},
    });
    await reconcile();
    check(
      (await db.rows('SELECT * FROM pending_sync_operations'))
              .single['request_payload'] ==
          pending['request_payload'],
      'Content changes must preserve frozen progress operations',
    );

    a = await word('content-a');
    await mutate(a.id, 'edit', a.revision, {
      'reviewed': true,
      'content': {...content(a), 'spelling': 'Concurrent starting fixture'},
    });
    source.afterPublished = () async {
      source.afterPublished = null;
      final current = await word('content-a');
      await mutate(current.id, 'edit', current.revision, {
        'reviewed': true,
        'content': {
          ...content(current),
          'spelling': 'Concurrent final fixture',
        },
      });
    };
    await reconcile();
    check(
      (await db.browse(
            category: Category.basic,
            difficulty: Difficulty.easy,
          )).single.spelling ==
          'Concurrent final fixture',
      'Concurrent publication must retry to stable version',
    );
    a = await word('content-a');
    await mutate(a.id, 'edit', a.revision, {
      'reviewed': true,
      'content': {...content(a), 'spelling': 'Interrupted fixture'},
    });
    final before = await state();
    var manifestReads = 0;
    source.onManifest = () async {
      if (++manifestReads == 2) throw const SyncFailure('offline');
    };
    var failed = false;
    try {
      await reconcile();
    } on SyncFailure {
      failed = true;
    }
    check(
      failed && await state() == before,
      'Interrupted reconciliation must retain all previous metadata/content',
    );
    source.onManifest = null;
    await db.close();
    db = LearningStore(NativeDatabase(file));
    await reconcile();

    a = await word('content-a');
    final missing = await mutate(a.id, 'edit', a.revision, {
      'reviewed': true,
      'content': {...content(a), 'spelling': 'Recovered from missing feed'},
    });
    await mutate('another-draft', 'create', 0, {
      'content': {
        ...content(a),
        'spelling': 'Another private fixture',
        'pronunciation': '',
        'senses': [],
      },
    });
    await source.maintenance(
      'contentChanges/${(missing['revision'] as int).toString().padLeft(16, '0')}',
      delete: true,
    );
    final oldFull = source.fullPages;
    await reconcile();
    check(
      source.fullPages > oldFull,
      'Gap must use verified snapshot recovery',
    );
    final freshDraft = await mutate('last-draft', 'create', 0, {
      'content': {
        ...content(a),
        'spelling': 'Final private fixture',
        'pronunciation': '',
        'senses': [],
      },
    });
    await source.maintenance(
      'contentManifest/current',
      fields: {'oldestRetainedRevision': freshDraft['revision'] as int},
    );
    final expiryPages = source.fullPages;
    await reconcile();
    check(
      source.fullPages > expiryPages,
      'Expired cursor must recover a snapshot',
    );
    final recovered = await state();
    final latest = await source.manifest();
    await source.maintenance(
      'contentManifest/current',
      fields: {
        'currentRevision': latest.revision - 1,
        'oldestRetainedRevision': 0,
      },
    );
    failed = false;
    try {
      await reconcile();
    } on ContentFailure catch (e) {
      failed = e.code == 'content-revision-rollback';
    }
    check(
      failed && await state() == recovered,
      'Revision rollback must preserve valid cache',
    );
    await source.maintenance(
      'contentManifest/current',
      fields: {'currentRevision': latest.revision, 'oldestRetainedRevision': 0},
    );
    check(
      await db.pendingCount('demo-learner') == 1,
      'Learning intent must remain pending and unchanged',
    );
    check(
      (await db.rows('SELECT * FROM content_delta_staging')).isEmpty,
      'Completed/failed runs must discard staging',
    );
    stdout.writeln(
      'PASS: public Firestore feed + real publication API + temporary Drift: edits, group moves, noops, draft exclusion, unpublish/retire/restore/republish, interruption/restart, concurrent publication, feed gaps, expiry and rollback.',
    );
  } finally {
    await db.close();
    source.close();
    client.close();
    await directory.delete(recursive: true);
  }
}
