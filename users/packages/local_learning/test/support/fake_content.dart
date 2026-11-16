import 'package:local_learning/local_learning.dart';

class FakeContentFeed implements ContentFeedSource {
  FakeContentFeed(List<VocabularyWord> initial) {
    for (final word in initial) {
      publish(word);
    }
  }
  final words = <String, VocabularyWord>{};
  final feed = <ContentChange>[];
  final omittedPublishedIds = <String>{};
  int? publisherVersion = 1;
  int revision = 0, watermark = 0, pageLimit = 2, fullPages = 0, feedPages = 0;
  Future<void> Function()? onManifest, onChanges, onPublished, onPage;
  void publish(VocabularyWord word) {
    revision++;
    words[word.id] = VocabularyWord.fromJson({
      ...word.toJson(),
      'revision': revision,
      'isPublished': true,
      'isRetired': false,
    });
    feed.add(ContentChange(revision, 'upsert', word.id));
  }

  void remove(String id) {
    revision++;
    words.remove(id);
    feed.add(ContentChange(revision, 'remove', id));
  }

  void noop() {
    revision++;
    feed.add(ContentChange(revision, 'noop'));
  }

  @override
  Future<ContentSnapshot> manifest() async {
    await onManifest?.call();
    final counts = {
      for (final c in Category.values)
        for (final d in Difficulty.values) '${c.name}/${d.name}': 0,
    };
    for (final word in words.values) {
      counts['${word.category.name}/${word.difficulty.name}'] =
          counts['${word.category.name}/${word.difficulty.name}']! + 1;
    }
    return ContentSnapshot(
      revision,
      counts,
      publisherVersion: publisherVersion,
      oldestRetainedRevision: watermark,
    );
  }

  @override
  Future<List<VocabularyWord>> page(Category? category, String? afterId) async {
    fullPages++;
    await onPage?.call();
    final selected =
        words.values
            .where(
              (w) =>
                  (category == null || w.category == category) &&
                  (afterId == null || w.id.compareTo(afterId) > 0),
            )
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return selected.take(pageLimit).toList();
  }

  @override
  Future<List<ContentChange>> changes(
    int afterRevision,
    int throughRevision,
  ) async {
    feedPages++;
    await onChanges?.call();
    return feed
        .where(
          (c) => c.revision > afterRevision && c.revision <= throughRevision,
        )
        .take(pageLimit)
        .toList();
  }

  @override
  Future<List<VocabularyWord>> publishedWords(List<String> ids) async {
    await onPublished?.call();
    return ids
        .where(
          (id) => words.containsKey(id) && !omittedPublishedIds.contains(id),
        )
        .map((id) => words[id]!)
        .toList();
  }
}
