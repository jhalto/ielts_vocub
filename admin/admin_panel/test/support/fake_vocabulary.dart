import 'dart:async';
import 'dart:convert';

import 'package:admin_panel/features/words/models.dart';
import 'package:admin_panel/features/words/repository.dart';

WordDraft fixtureDraft([String spelling = 'Fixture']) => WordDraft(
  spelling: spelling,
  pronunciation: 'fixture',
  senses: [
    SenseDraft(
      id: 'sense-1',
      englishMeaning: 'Synthetic test only.',
      bengaliMeaning: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
      examples: [
        ExampleDraft(
          english: 'Fixture only.',
          bengali: '\u09aa\u09b0\u09c0\u0995\u09cd\u09b7\u09be',
        ),
      ],
    ),
  ],
);
AdminWord fixtureWord({
  String id = 'word-1',
  String spelling = 'Fixture',
  int revision = 1,
  bool published = false,
  bool retired = false,
}) => AdminWord(
  id: id,
  revision: revision,
  published: published,
  retired: retired,
  draft: fixtureDraft(spelling),
);

class FakeVocabulary implements VocabularyRepository {
  final Map<String, AdminWord> words = {};
  final List<String> requests = [];
  final List<Object?> cursors = [];
  final List<WordFilters> filters = [];
  final List<PublicationFailure> failures = [];
  final Map<String, MutationAck> results = {};
  Future<WordPage> Function(WordFilters, Object?)? listHandler;
  Completer<MutationAck>? mutationResult;
  bool failGet = false, throwAfterCommit = false;
  int closed = 0;
  @override
  Future<WordPage> list(WordFilters filter, {Object? after}) async {
    cursors.add(after);
    filters.add(filter);
    if (listHandler != null) return listHandler!(filter, after);
    final matches =
        words.values
            .where(
              (w) =>
                  w.draft.spelling.startsWith(filter.prefix.trim()) &&
                  (filter.category == null ||
                      w.draft.category == filter.category) &&
                  (filter.difficulty == null ||
                      w.draft.difficulty == filter.difficulty) &&
                  switch (filter.publication) {
                    PublicationFilter.all => true,
                    PublicationFilter.published => w.published && !w.retired,
                    PublicationFilter.draft => !w.published && !w.retired,
                    PublicationFilter.retired => w.retired,
                  },
            )
            .toList()
          ..sort((a, b) => a.draft.spelling.compareTo(b.draft.spelling));
    final start = after as int? ?? 0;
    final page = matches.skip(start).take(25).toList();
    return WordPage(
      page,
      hasNext: start + 25 < matches.length,
      nextCursor: start + 25,
    );
  }

  @override
  Future<AdminWord> get(String id) async {
    if (failGet) throw const PublicationFailure('network', 'Read failed');
    final word = words[id];
    if (word == null) {
      throw const PublicationFailure('word-not-found', 'Word not found');
    }
    return AdminWord(
      id: word.id,
      revision: word.revision,
      published: word.published,
      retired: word.retired,
      draft: word.draft.copy(),
    );
  }

  @override
  Future<MutationAck> mutate(PendingMutation mutation) async {
    requests.add(mutation.body);
    if (failures.isNotEmpty) throw failures.removeAt(0);
    if (mutationResult != null) return mutationResult!.future;
    final data = jsonDecode(mutation.body) as Map<String, dynamic>;
    final operation = data['operationId'] as String;
    if (results.containsKey(operation)) return results[operation]!;
    final id = data['wordId'] as String;
    final old = words[id];
    final action = data['action'];
    final ack = MutationAck(
      id,
      (old?.revision ?? 0) + 1,
      action == 'publish'
          ? true
          : action == 'edit'
          ? old!.published
          : false,
      action == 'retire'
          ? true
          : action == 'restore'
          ? false
          : old?.retired ?? false,
    );
    final draft = data['content'] != null
        ? WordDraft.fromJson(Map<String, dynamic>.from(data['content'] as Map))
        : old!.draft.copy();
    words[id] = AdminWord(
      id: id,
      revision: ack.revision,
      published: ack.published,
      retired: ack.retired,
      draft: draft,
    );
    results[operation] = ack;
    if (throwAfterCommit) {
      throwAfterCommit = false;
      throw const PublicationFailure(
        'network',
        'Response lost',
        retryable: true,
      );
    }
    return ack;
  }

  @override
  void close() {
    closed++;
  }
}
