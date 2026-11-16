import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:admin_panel/features/words/models.dart';
import 'package:admin_panel/features/words/controllers.dart';

import 'support/fake_vocabulary.dart';

void main() {
  test('incomplete drafts remain editable; publication requires every bilingual field', () {
    final draft = WordDraft(spelling: 'Draft');
    expect(draft.validate(), isNull);
    expect(draft.validate(publishing: true), isNotNull);
    final complete = fixtureDraft();
    expect(complete.validate(publishing: true), isNull);
    complete.senses.first.examples.first.bengali = '';
    expect(complete.validate(publishing: true), isNotNull);
  });
  test('sense/example reorder preserves IDs, paired Unicode and server array ordering', () {
    final draft = fixtureDraft();
    draft.senses.add(
      SenseDraft(
        id: 'sense-2',
        examples: [
          ExampleDraft(
            english: 'Second',
            bengali: '\u09a6\u09cd\u09ac\u09bf\u09a4\u09c0\u09df',
          ),
        ],
      ),
    );
    final first = draft.senses.removeAt(0);
    draft.senses.add(first);
    final json = draft.toJson();
    expect((json['senses'] as List)[1]['id'], 'sense-1');
    expect((json['senses'] as List)[1]['ordering'], 1);
    final roundtrip = WordDraft.fromJson(json);
    expect(
      roundtrip.senses.last.examples.first.bengali,
      first.examples.first.bengali,
    );
    roundtrip.senses.last.examples.first.english = 'Changed';
    expect(draft.senses.last.examples.first.english, 'Fixture only.');
  });
  test('validation rejects malformed Unicode, controls, oversized fields and duplicate sense IDs', () {
    for (final text in ['\ud800', 'bad\u0000text', 'x' * 129]) {
      expect(WordDraft(spelling: text).validate(), isNotNull);
    }
    final draft = fixtureDraft();
    draft.senses.add(SenseDraft(id: 'sense-1'));
    expect(draft.validate(), isNotNull);
    expect(WordDraft(spelling: '\ud83d\ude00').validate(), isNull);
  });
  test('prefix successor handles Unicode and maximum scalar', () {
    expect(prefixEnd('Test'), 'Tesu');
    expect(prefixEnd('\ud83d\ude00'), '\ud83d\ude01');
    expect(prefixEnd(String.fromCharCode(0x10ffff)), isNull);
  });
  test('out-of-order search replies cannot replace a newer filter', () async {
    final repo = FakeVocabulary();
    final old = Completer<WordPage>();
    final next = Completer<WordPage>();
    repo.listHandler = (f, _) => f.prefix == 'old' ? old.future : next.future;
    final c = WordListController(repo);
    final a = c.filter(const WordFilters(prefix: 'old'));
    final b = c.filter(const WordFilters(prefix: 'new'));
    next.complete(WordPage([fixtureWord(spelling: 'new')]));
    await b;
    old.complete(WordPage([fixtureWord(spelling: 'old')]));
    await a;
    expect(c.page!.words.single.draft.spelling, 'new');
    c.dispose();
  });
  test('cursor paging and changing filters reset the page without fabricated totals', () async {
    final repo = FakeVocabulary();
    for (var i = 0; i < 26; i++) {
      repo.words['$i'] = fixtureWord(
        id: '$i',
        spelling: 'Fixture ${i.toString().padLeft(2, '0')}',
      );
    }
    final c = WordListController(repo);
    await c.load();
    expect(c.page!.words, hasLength(25));
    await c.next();
    expect(c.page!.words, hasLength(1));
    expect(repo.cursors, [null, 25]);
    await c.previous();
    expect(c.pageIndex, 0);
    await c.filter(const WordFilters(prefix: 'Fixture 25'));
    expect(c.pageIndex, 0);
    expect(repo.cursors.last, isNull);
    expect(c.page!.words, hasLength(1));
    c.dispose();
  });
  test('lost create acknowledgement retries the exact request and ID without duplicate creation', () async {
    final repo = FakeVocabulary()..throwAfterCommit = true;
    final c = WordEditorController(repository: repo, uid: 'bob');
    c.draft = fixtureDraft();
    c.changed();
    await c.apply('create');
    expect(c.pending, isNotNull);
    expect(c.locked, isTrue);
    expect(repo.words.length, 1);
    final bytes = c.pending!.body;
    await c.retry();
    expect(repo.requests, [bytes, bytes]);
    expect(repo.words.length, 1);
    expect(c.pending, isNull);
    expect(c.word!.revision, 1);
    expect(c.dirty, isFalse);
    c.dispose();
  });
  test(
    'published edits require review and changed drafts invalidate review',
    () async {
      final repo = FakeVocabulary();
      final word = fixtureWord(published: true);
      repo.words[word.id] = word;
      final c = WordEditorController(repository: repo, uid: 'bob', word: word);
      c.draft.spelling = 'Updated';
      c.changed();
      await c.apply('edit');
      expect(repo.requests, isEmpty);
      c.review(true);
      await c.apply('edit');
      expect(jsonDecode(repo.requests.single)['reviewed'], isTrue);
      expect(c.reviewed, isFalse);
      c.review(true);
      c.draft.spelling = 'Again';
      c.changed();
      expect(c.reviewed, isFalse);
      c.dispose();
    },
  );
  test(
    'revision conflict keeps the local draft until explicit comparison/rebase',
    () async {
      final repo = FakeVocabulary();
      final old = fixtureWord();
      repo.words[old.id] = fixtureWord(revision: 2, spelling: 'Remote');
      repo.failures.add(
        const PublicationFailure('revision-conflict', 'Conflict'),
      );
      final c = WordEditorController(repository: repo, uid: 'bob', word: old);
      c.draft.spelling = 'Local';
      c.changed();
      await c.apply('edit');
      expect(c.conflict, isTrue);
      expect(c.draft.spelling, 'Local');
      await c.compare();
      expect(c.draft.spelling, 'Local');
      expect(c.remote!.revision, 2);
      c.resolve(keepDraft: true);
      expect(c.word!.revision, 2);
      expect(c.dirty, isTrue);
      await c.apply('edit');
      expect(jsonDecode(repo.requests.last)['expectedRevision'], 2);
      c.dispose();
    },
  );
  test('acknowledged save with failed reload is never resent as an uncertain operation', () async {
    final repo = FakeVocabulary()..failGet = true;
    final c = WordEditorController(repository: repo, uid: 'bob');
    c.draft = fixtureDraft();
    c.changed();
    await c.apply('create');
    expect(c.pending, isNull);
    expect(c.word!.revision, 1);
    expect(c.needsReload, isTrue);
    expect(c.locked, isTrue);
    expect(repo.requests, hasLength(1));
    repo.failGet = false;
    await c.reload();
    expect(c.needsReload, isFalse);
    c.dispose();
  });
  test('duplicate spelling remains editable and never silently overwrites another word', () async {
    final repo = FakeVocabulary()
      ..failures.add(
        const PublicationFailure('duplicate-spelling', 'Duplicate'),
      );
    final c = WordEditorController(repository: repo, uid: 'bob');
    c.draft = fixtureDraft();
    await c.apply('create');
    expect(c.pending, isNull);
    expect(c.locked, isFalse);
    expect(c.error, 'Duplicate');
    expect(repo.words, isEmpty);
    c.dispose();
  });
  test(
    'authorization failure retains an uncertain request for same-UID retry',
    () async {
      final repo = FakeVocabulary()
        ..failures.add(
          const PublicationFailure(
            'permission-denied',
            'Refresh role',
            denied: true,
          ),
        );
      final c = WordEditorController(repository: repo, uid: 'bob');
      c.draft = fixtureDraft();
      await c.apply('create');
      expect(c.pending, isNotNull);
      final body = c.pending!.body;
      await c.retry();
      expect(repo.requests, [body, body]);
      c.dispose();
    },
  );
  test(
    'double save while a local request is in flight sends only one operation',
    () async {
      final pending = Completer<MutationAck>();
      final repo = FakeVocabulary()..mutationResult = pending;
      final c = WordEditorController(repository: repo, uid: 'bob');
      c.draft = fixtureDraft();
      final first = c.apply('create');
      await c.apply('create');
      expect(repo.requests, hasLength(1));
      repo.failGet = true;
      pending.complete(MutationAck(c.id, 1, false, false));
      await first;
      c.dispose();
    },
  );
}
