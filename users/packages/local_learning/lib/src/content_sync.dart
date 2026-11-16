import '../local_learning.dart';

class ContentFailure extends SyncFailure {
  const ContentFailure(super.code, {super.retryable});
}

class ContentChange {
  const ContentChange(this.revision, this.action, [this.wordId]);
  final int revision;
  final String action;
  final String? wordId;
  factory ContentChange.fromJson(String documentId, Map<String, dynamic> data) {
    final revision = syncRevision(data['revision']);
    final action = data['action'];
    if (data['schemaVersion'] != 1 ||
        revision == 0 ||
        documentId != revision.toString().padLeft(16, '0') ||
        !['upsert', 'remove', 'noop'].contains(action) ||
        data['updatedAt'] == null ||
        data.keys.any(
          (k) => ![
            'schemaVersion',
            'revision',
            'action',
            'wordId',
            'updatedAt',
          ].contains(k),
        ) ||
        (action == 'noop'
            ? data.containsKey('wordId')
            : !validSyncId(data['wordId']))) {
      throw const ContentFailure('content-feed-invalid');
    }
    return ContentChange(revision, action as String, data['wordId'] as String?);
  }
}

abstract interface class ContentFeedSource implements PublishedContentSource {
  /// Strictly increasing revision/document-ID order, bounded to 100 records.
  Future<List<ContentChange>> changes(int afterRevision, int throughRevision);

  /// Published/non-retired queries only. Missing IDs have no public payload.
  Future<List<VocabularyWord>> publishedWords(List<String> ids);
}

class ContentBaseline {
  ContentBaseline(
    this.generation,
    this.scopes,
    this.checkpoints,
    this.maximumRevision,
  );
  final int generation, maximumRevision;
  final Set<Category> scopes;
  final Map<Category, int> checkpoints;
}

class ContentReconciler {
  ContentReconciler(this.store, this.source);
  final LearningStore store;
  final ContentFeedSource source;
  Future<void> reconcile({
    required bool Function() active,
  }) => store.singleContentSync(() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      _check(active);
      final baseline = await store.contentBaseline();
      if (baseline.scopes.isEmpty) return;
      final run = newId();
      try {
        final opening = await source.manifest();
        _check(active);
        opening.validate(null);
        if (opening.publisherVersion != 1) {
          throw const ContentFailure('content-manifest-unsupported');
        }
        if (opening.revision < baseline.maximumRevision) {
          throw const ContentFailure('content-revision-rollback');
        }
        final cursors = baseline.checkpoints.values;
        final oldest = cursors.isEmpty
            ? 0
            : cursors.reduce((a, b) => a < b ? a : b);
        if (baseline.checkpoints.length != baseline.scopes.length ||
            oldest < opening.oldestRetainedRevision ||
            opening.revision - oldest > 10000) {
          await _recover(baseline, active);
          return;
        }
        var cursor = oldest;
        final latest = <String, ContentChange>{};
        while (cursor < opening.revision) {
          final changes = await source.changes(cursor, opening.revision);
          _check(active);
          if (changes.isEmpty) throw const ContentFailure('content-feed-gap');
          if (changes.length > 100) {
            throw const ContentFailure('content-feed-invalid');
          }
          for (final change in changes) {
            if (change.revision != cursor + 1 ||
                change.revision > opening.revision) {
              throw const ContentFailure('content-feed-gap');
            }
            if (!['upsert', 'remove', 'noop'].contains(change.action) ||
                (change.action == 'noop'
                    ? change.wordId != null
                    : !validSyncId(change.wordId))) {
              throw const ContentFailure('content-feed-invalid');
            }
            cursor = change.revision;
            if (change.wordId != null) latest[change.wordId!] = change;
          }
        }
        final ids = latest.values
            .where((c) => c.action == 'upsert')
            .map((c) => c.wordId!)
            .toList();
        final words = <String, VocabularyWord>{};
        for (var start = 0; start < ids.length; start += 30) {
          final batch = ids.sublist(
            start,
            start + 30 > ids.length ? ids.length : start + 30,
          );
          final published = await source.publishedWords(batch);
          _check(active);
          for (final word in published) {
            VocabularyWord.fromJson(word.toJson());
            if (!batch.contains(word.id) ||
                words.containsKey(word.id) ||
                !word.isPublished ||
                word.isRetired) {
              throw const ContentFailure('content-payload-invalid');
            }
            if (word.revision > opening.revision) {
              throw const ContentFailure('content-changed', retryable: true);
            }
            if (word.revision != latest[word.id]!.revision) {
              throw const ContentFailure('content-payload-invalid');
            }
            words[word.id] = word;
          }
          if (batch.any((id) => !words.containsKey(id))) {
            throw const ContentFailure('content-baseline-invalid');
          }
        }
        await store.stageContentDelta(
          run,
          latest.values.toList(),
          words,
          active: active,
        );
        final closing = await source.manifest();
        _check(active);
        if (!opening.sameVersion(closing)) {
          throw const ContentFailure('content-changed', retryable: true);
        }
        await store.commitContentDelta(run, baseline, opening, active: active);
        return;
      } on ContentFailure catch (e) {
        if ([
          'content-feed-gap',
          'content-public-query-unavailable',
          'content-feed-invalid',
          'content-count-mismatch',
          'content-baseline-invalid',
        ].contains(e.code)) {
          // The existing verified downloader stages the requested scopes and
          // replaces them together, never trusting an incomplete feed.
          await _recover(baseline, active);
          return;
        }
        if (!e.retryable || attempt == 2) rethrow;
      } finally {
        await store.discardContentDelta(run);
      }
    }
  });
  void _check(bool Function() active) {
    if (!active()) throw const ContentFailure('account-changed');
  }

  Future<void> _recover(
    ContentBaseline baseline,
    bool Function() active,
  ) async {
    _check(active);
    await ContentDownloader(store, source).download(
      null,
      scopes: baseline.scopes,
      expectedGeneration: baseline.generation,
      requireTrustedManifest: true,
      cancelled: () => !active(),
    );
  }
}
