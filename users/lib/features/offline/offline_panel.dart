import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:drift/native.dart';
import 'package:local_learning/local_learning.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

Future<LearningStore>? _store;
Future<LearningStore> openStore() => _store ??= () async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return LearningStore(
    NativeDatabase.createInBackground(
      File('${directory.path}/vocabulary.sqlite'),
    ),
  );
}();
Widget offlinePanel(String? uid) =>
    OfflinePanel(key: ValueKey(uid ?? 'guest'), uid: uid);
Future<void> clearOfflinePrivate(String uid) async {
  await (await openStore()).clearPrivate(uid);
}

class FirestoreContentSource implements PublishedContentSource {
  FirestoreContentSource(this.firestore);
  final FirebaseFirestore firestore;
  @override
  Future<ContentSnapshot> manifest() async {
    final snapshot = await firestore
        .doc('contentManifest/current')
        .get(const GetOptions(source: Source.server));
    final data = snapshot.data();
    if (data == null ||
        data['schemaVersion'] != 1 ||
        data['currentRevision'] is! int ||
        data['groupCounts'] is! Map) {
      throw StateError(
        'Published manifest unavailable. Downloads require the trusted publication backend.',
      );
    }
    return ContentSnapshot(
      data['currentRevision'] as int,
      Map<String, int>.from(data['groupCounts'] as Map),
    );
  }

  @override
  Future<List<VocabularyWord>> page(Category? category, String? afterId) async {
    Query<Map<String, dynamic>> query = firestore
        .collection('words')
        .where('isPublished', isEqualTo: true)
        .where('isRetired', isEqualTo: false);
    if (category != null) {
      query = query.where('category', isEqualTo: category.name);
    }
    query = query.orderBy(FieldPath.documentId).limit(100);
    if (afterId != null) {
      query = query.startAfter([firestore.doc('words/$afterId')]);
    }
    final page = await query.get(const GetOptions(source: Source.server));
    return page.docs
        .map((doc) => VocabularyWord.fromJson({...doc.data(), 'id': doc.id}))
        .toList();
  }
}

class OfflinePanel extends StatefulWidget {
  const OfflinePanel({super.key, required this.uid});
  final String? uid;
  @override
  State<OfflinePanel> createState() => _OfflinePanelState();
}

class _OfflinePanelState extends State<OfflinePanel> {
  LearningStore? store;
  final tts = FlutterTts();
  final search = TextEditingController();
  Timer? debounce;
  Category category = Category.basic;
  Difficulty difficulty = Difficulty.easy;
  ProgressStatus? status;
  PartOfSpeech? partOfSpeech;
  bool unmarkedOnly = false;
  List<VocabularyWord> words = [];
  List<Map<String, dynamic>> downloads = [];
  Map<String, int> stats = {};
  Map<String, dynamic>? session;
  String? error;
  String? info;
  int pending = 0, offset = 0, _request = 0, _downloadGeneration = 0;
  bool busy = false, downloading = false, speaking = false, _disposed = false;
  bool get authorized =>
      widget.uid == null ||
      FirebaseAuth.instance.currentUser?.uid == widget.uid;
  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      store = await openStore();
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Local database unavailable. Check disk access and retry.',
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _downloadGeneration++;
    debounce?.cancel();
    search.dispose();
    unawaited(tts.stop());
    super.dispose();
  }

  Future<void> _refresh() async {
    final db = store;
    if (db == null) return;
    final request = ++_request;
    final next = await db.browse(
      category: category,
      difficulty: difficulty,
      search: search.text,
      uid: widget.uid,
      status: unmarkedOnly ? null : status,
      partOfSpeech: partOfSpeech,
      unmarkedOnly: unmarkedOnly,
      offset: offset,
    );
    final counts = await db.statistics(widget.uid, category, difficulty);
    final manifests = await db.downloads();
    final restored = widget.uid == null ? null : await db.session(widget.uid!);
    final queued = widget.uid == null ? 0 : await db.pendingCount(widget.uid!);
    if (!mounted || request != _request || !authorized) return;
    setState(() {
      words = next;
      stats = counts;
      downloads = manifests;
      session = restored;
      pending = queued;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is StateError
              ? e.message.toString()
              : 'Local save failed. Check disk space and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _download(Category? selected) async {
    if (downloading || store == null) return;
    final generation = ++_downloadGeneration;
    setState(() {
      downloading = true;
      error = null;
      info = 'Downloading published vocabulary...';
    });
    try {
      final count =
          await ContentDownloader(
            store!,
            FirestoreContentSource(FirebaseFirestore.instance),
          ).download(
            selected,
            cancelled: () =>
                _disposed || generation != _downloadGeneration || !authorized,
            onProgress: (count) {
              if (mounted) {
                setState(
                  () =>
                      info = 'Downloaded $count words; validating snapshot...',
                );
              }
            },
          );
      if (mounted) setState(() => info = 'Available offline: $count words.');
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is StateError ? e.message.toString() : 'Download failed. Check internet and retry; existing offline content is preserved.',
        );
      }
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  Future<void> _speak(VocabularyWord word) async {
    try {
      await tts.stop();
      final voices = (await tts.getVoices as List)
          .where(
            (v) =>
                (v['locale'] as String? ?? '').toLowerCase().startsWith('en'),
          )
          .toList();
      if (voices.isEmpty) throw StateError('No English voice');
      await tts.setVoice({
        'name': voices.first['name'] as String,
        'locale': voices.first['locale'] as String,
      });
      await tts.awaitSpeakCompletion(true);
      if (mounted) setState(() => speaking = true);
      await tts.speak(word.spelling);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Install a compatible local English voice in system speech settings.',
        );
      }
    } finally {
      if (mounted) setState(() => speaking = false);
    }
  }

  Widget _content(VocabularyWord word) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(word.pronunciation),
      IconButton(
        onPressed: speaking ? null : () => _speak(word),
        icon: const Icon(Icons.volume_up),
        tooltip: 'Speak English spelling',
      ),
      for (final sense in word.senses) ...[
        Text(
          sense.partOfSpeech.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Text(sense.englishMeaning),
        Text(sense.bengaliMeaning),
        for (final example in sense.examples) ...[
          const SizedBox(height: 6),
          Text(example.english),
          Text(example.bengali),
        ],
        const Divider(),
      ],
    ],
  );
  Future<void> _detail(VocabularyWord word) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(word.spelling),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(child: _content(word)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    await tts.stop();
  }

  Future<void> _swipe(bool right, VocabularyWord word) => _run(() async {
    await tts.stop();
    await store!.swipe(
      widget.uid!,
      word.id,
      right,
      stillAuthorized: () => !_disposed && authorized,
    );
  });
  Future<void> _start({ProgressStatus? review}) async {
    if (session != null && (session!['queue'] as List).isNotEmpty) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Start a new session?'),
          content: const Text(
            'Your saved progress stays, but this replaces the unfinished queue.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Resume existing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Start new'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    await _run(
      () => store!.startSession(
        widget.uid!,
        category,
        difficulty,
        review: review,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final queue = List<VocabularyWord>.from(session?['queue'] as List? ?? []);
    final total = stats.values.fold(0, (a, b) => a + b);
    final known = (stats['already_know'] ?? 0) + (stats['learned'] ?? 0);
    final complete = downloads.any(
      (g) =>
          g['category'] == category.name &&
          g['difficulty'] == difficulty.name &&
          g['complete'] == 1,
    );
    final sessionComplete = downloads.any(
      (g) =>
          g['category'] == session?['category'] &&
          g['difficulty'] == session?['difficulty'] &&
          g['complete'] == 1,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 32),
        Text(
          'Offline vocabulary',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        if (store == null)
          TextButton(
            onPressed: _initialize,
            child: const Text('Open local database'),
          ),
        if (error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (info != null) Semantics(liveRegion: true, child: Text(info!)),
        const Text(
          'Downloads require internet. Reading, search and learning use this device\'s SQLite database.',
        ),
        const Text(
          'Pronunciation needs an installed English voice. Verify voice availability with networking disabled.',
        ),
        if (downloading) ...[
          const LinearProgressIndicator(),
          TextButton(
            onPressed: () {
              _downloadGeneration++;
              setState(() => info = 'Stopping download; retry to restart.');
            },
            child: const Text('Cancel download (retry restarts)'),
          ),
        ],
        Wrap(
          spacing: 8,
          children: [
            for (final c in Category.values)
              OutlinedButton(
                onPressed: downloading || store == null
                    ? null
                    : () => _download(c),
                child: Text('Download ${c.name}'),
              ),
            OutlinedButton(
              onPressed: downloading || store == null
                  ? null
                  : () => _download(null),
              child: const Text('Download all published'),
            ),
          ],
        ),
        DropdownButtonFormField<Category>(
          initialValue: category,
          decoration: const InputDecoration(labelText: 'Category'),
          items: Category.values
              .map((v) => DropdownMenuItem(value: v, child: Text(v.name)))
              .toList(),
          onChanged: busy || downloading
              ? null
              : (v) {
                  setState(() {
                    category = v!;
                    offset = 0;
                  });
                  unawaited(_refresh());
                },
        ),
        DropdownButtonFormField<Difficulty>(
          initialValue: difficulty,
          decoration: const InputDecoration(labelText: 'Difficulty'),
          items: Difficulty.values
              .map((v) => DropdownMenuItem(value: v, child: Text(v.name)))
              .toList(),
          onChanged: busy || downloading
              ? null
              : (v) {
                  setState(() {
                    difficulty = v!;
                    offset = 0;
                  });
                  unawaited(_refresh());
                },
        ),
        Text(
          complete
              ? 'Available offline - verified complete snapshot'
              : 'Downloaded content only - this group is not verified complete',
        ),
        for (final group in downloads.where(
          (g) =>
              g['category'] == category.name &&
              g['difficulty'] == difficulty.name,
        ))
          Text(
            'Version ${group['revision']}; last successful download ${group['updated_at']}',
          ),
        Text(
          'Locally published: $total; unmarked: ${stats['unmarked'] ?? 0}; already know: ${stats['already_know'] ?? 0}; learned: ${stats['learned'] ?? 0}; learning: ${stats['didnt_know'] ?? 0}',
        ),
        if (widget.uid != null)
          Text(
            'Completion: ${total == 0 ? 0 : (known / total * 100).round()}% of local group. $pending changes pending cloud sync (not yet implemented).',
          ),
        TextField(
          controller: search,
          decoration: const InputDecoration(
            labelText: 'Search downloaded English or Bengali',
          ),
          onChanged: (_) {
            debounce?.cancel();
            debounce = Timer(const Duration(milliseconds: 300), () {
              offset = 0;
              unawaited(_refresh());
            });
          },
        ),
        if (widget.uid != null)
          DropdownButtonFormField<ProgressStatus?>(
            initialValue: status,
            decoration: const InputDecoration(labelText: 'Progress filter'),
            items: [
              const DropdownMenuItem<ProgressStatus?>(
                value: null,
                child: Text('All statuses'),
              ),
              for (final v in ProgressStatus.values)
                DropdownMenuItem(
                  value: v,
                  child: Text(
                    v == ProgressStatus.didntKnow ? 'Learning' : v.wireValue,
                  ),
                ),
            ],
            onChanged: (v) {
              setState(() {
                status = v;
                offset = 0;
              });
              unawaited(_refresh());
            },
          ),
        DropdownButtonFormField<PartOfSpeech?>(
          initialValue: partOfSpeech,
          decoration: const InputDecoration(labelText: 'Part of speech'),
          items: [
            const DropdownMenuItem<PartOfSpeech?>(
              value: null,
              child: Text('All parts of speech'),
            ),
            for (final p in PartOfSpeech.values)
              DropdownMenuItem(value: p, child: Text(p.name)),
          ],
          onChanged: (value) {
            setState(() {
              partOfSpeech = value;
              offset = 0;
            });
            unawaited(_refresh());
          },
        ),
        if (widget.uid != null)
          CheckboxListTile(
            title: const Text('Unmarked words only'),
            value: unmarkedOnly,
            onChanged: (value) {
              setState(() {
                unmarkedOnly = value!;
                offset = 0;
              });
              unawaited(_refresh());
            },
          ),
        if (words.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No matching downloaded words.'),
          ),
        for (final word in words)
          ListTile(
            title: Text(word.spelling),
            subtitle: Text(word.pronunciation),
            onTap: () => _detail(word),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: offset == 0
                  ? null
                  : () {
                      offset = (offset - 50).clamp(0, 100000);
                      unawaited(_refresh());
                    },
              child: const Text('Previous'),
            ),
            TextButton(
              onPressed: words.length < 50
                  ? null
                  : () {
                      offset += 50;
                      unawaited(_refresh());
                    },
              child: const Text('Next'),
            ),
          ],
        ),
        if (widget.uid == null)
          const Text(
            'Sign in to save learning progress. Guest progress is not retained.',
          )
        else ...[
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: busy || store == null ? null : _start,
                child: const Text('Start learning this group'),
              ),
              for (final review in ProgressStatus.values)
                TextButton(
                  onPressed: busy || store == null
                      ? null
                      : () => _start(review: review),
                  child: Text('Review ${review.wireValue}'),
                ),
            ],
          ),
          if (session != null) ...[
            Text(
              'Session: ${session!['category']} / ${session!['difficulty']} - ${queue.length} remaining',
            ),
            Text(
              'Committed outcomes: ${(jsonDecode(session!["outcomes"] as String) as Map).length} words; pending cloud sync.',
            ),
            if (queue.isEmpty)
              Text(
                'Session complete for available downloaded words. ${sessionComplete ? '' : 'This group may contain words not downloaded.'}',
              ),
            if (session!['waiting'] == 1)
              FilledButton(
                onPressed: busy
                    ? null
                    : () => _run(() => store!.tryAgain(widget.uid!)),
                child: const Text('Try Again'),
              ),
            if (queue.isNotEmpty && session!['waiting'] != 1) ...[
              _SwipeCard(
                key: ValueKey(queue.first.id),
                enabled: !busy,
                onSwipe: (right) => _swipe(right, queue.first),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          queue.first.spelling,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        _content(queue.first),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy ? null : () => _swipe(false, queue.first),
                      child: const Text("Didn't Know"),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy ? null : () => _swipe(true, queue.first),
                      child: const Text('Know It'),
                    ),
                  ),
                ],
              ),
            ],
            const Text(
              'Sessions save automatically. Close the app and resume later. Local saves are not cloud backups.',
            ),
          ],
        ],
      ],
    );
  }
}

class _SwipeCard extends StatefulWidget {
  const _SwipeCard({
    super.key,
    required this.enabled,
    required this.onSwipe,
    required this.child,
  });
  final bool enabled;
  final Future<void> Function(bool) onSwipe;
  final Widget child;
  @override
  State<_SwipeCard> createState() => _SwipeCardState();
}

class _SwipeCardState extends State<_SwipeCard> {
  double distance = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onHorizontalDragStart: widget.enabled
        ? (_) {
            distance = 0;
          }
        : null,
    onHorizontalDragUpdate: widget.enabled
        ? (d) {
            distance += d.delta.dx;
          }
        : null,
    onHorizontalDragEnd: widget.enabled
        ? (_) {
            if (distance.abs() > 80) unawaited(widget.onSwipe(distance > 0));
          }
        : null,
    child: widget.child,
  );
}
