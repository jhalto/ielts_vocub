import 'dart:convert';
import 'dart:math';

import 'package:shared_models/shared_models.dart';
export 'package:shared_models/shared_models.dart'
    show Category, Difficulty, PartOfSpeech;

String newId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class ExampleDraft {
  ExampleDraft({this.english = '', this.bengali = ''});
  String english, bengali;
  Map<String, dynamic> toJson() => {'english': english, 'bengali': bengali};
}

class SenseDraft {
  SenseDraft({
    String? id,
    this.partOfSpeech = PartOfSpeech.noun,
    this.englishMeaning = '',
    this.bengaliMeaning = '',
    List<ExampleDraft>? examples,
  }) : id = id ?? newId(),
       examples = examples ?? [];
  final String id;
  PartOfSpeech partOfSpeech;
  String englishMeaning, bengaliMeaning;
  final List<ExampleDraft> examples;
  Map<String, dynamic> toJson(int ordering) => {
    'id': id,
    'partOfSpeech': partOfSpeech.name,
    'englishMeaning': englishMeaning,
    'bengaliMeaning': bengaliMeaning,
    'ordering': ordering,
    'examples': examples.map((e) => e.toJson()).toList(),
  };
}

/// Incomplete editorial content is deliberately separate from VocabularyWord.
class WordDraft {
  WordDraft({
    this.spelling = '',
    this.pronunciation = '',
    this.category = Category.basic,
    this.difficulty = Difficulty.easy,
    this.ordering = 0,
    List<SenseDraft>? senses,
  }) : senses = senses ?? [];
  String spelling, pronunciation;
  Category category;
  Difficulty difficulty;
  int ordering;
  final List<SenseDraft> senses;
  factory WordDraft.fromJson(Map<String, dynamic> data) => WordDraft(
    spelling: data['spelling'] as String,
    pronunciation: data['pronunciation'] as String,
    category: Category.values.byName(data['category'] as String),
    difficulty: Difficulty.values.byName(data['difficulty'] as String),
    ordering: data['ordering'] as int,
    senses: (data['senses'] as List).map((raw) {
      final sense = Map<String, dynamic>.from(raw as Map);
      return SenseDraft(
        id: sense['id'] as String,
        partOfSpeech: PartOfSpeech.values.byName(
          sense['partOfSpeech'] as String,
        ),
        englishMeaning: sense['englishMeaning'] as String,
        bengaliMeaning: sense['bengaliMeaning'] as String,
        examples: (sense['examples'] as List).map((raw) {
          final e = Map<String, dynamic>.from(raw as Map);
          return ExampleDraft(
            english: e['english'] as String,
            bengali: e['bengali'] as String,
          );
        }).toList(),
      );
    }).toList(),
  );
  WordDraft copy() => WordDraft.fromJson(toJson());
  Map<String, dynamic> toJson() => {
    'spelling': spelling,
    'pronunciation': pronunciation,
    'category': category.name,
    'difficulty': difficulty.name,
    'ordering': ordering,
    'senses': [for (var i = 0; i < senses.length; i++) senses[i].toJson(i)],
  };
  String? validate({bool publishing = false}) {
    bool invalid(String v, int max) =>
        v.length > max ||
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]').hasMatch(v) ||
        _malformed(v);
    if (spelling.trim().isEmpty || invalid(spelling, 128)) {
      return 'Spelling is required (up to 128 characters).';
    }
    if (invalid(pronunciation, 256)) {
      return 'Pronunciation must be text up to 256 characters.';
    }
    if (ordering < 0 || ordering > 2147483647) {
      return 'Ordering must be between 0 and 2147483647.';
    }
    if (senses.length > 100 ||
        senses.map((s) => s.id).toSet().length != senses.length) {
      return 'Senses must have unique IDs; maximum 100.';
    }
    for (final sense in senses) {
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(sense.id)) {
        return 'A sense ID is invalid.';
      }
      if (invalid(sense.englishMeaning, 4000) ||
          invalid(sense.bengaliMeaning, 4000)) {
        return 'Meanings must be valid text up to 4000 characters.';
      }
      if (sense.examples.length > 100) {
        return 'Maximum 100 example pairs per sense.';
      }
      for (final example in sense.examples) {
        if (invalid(example.english, 4000) || invalid(example.bengali, 4000)) {
          return 'Example text must be valid and at most 4000 characters.';
        }
      }
    }
    if (utf8.encode(jsonEncode(toJson())).length > 190000) {
      return 'Content is too large for one word. Reduce the senses/examples.';
    }
    if (publishing &&
        (pronunciation.trim().isEmpty ||
            senses.isEmpty ||
            senses.any(
              (s) =>
                  s.englishMeaning.trim().isEmpty ||
                  s.bengaliMeaning.trim().isEmpty ||
                  s.examples.isEmpty ||
                  s.examples.any(
                    (e) => e.english.trim().isEmpty || e.bengali.trim().isEmpty,
                  ),
            ))) {
      return 'Publication requires pronunciation, at least one sense/example and every English/Bengali translation.';
    }
    return null;
  }
}

bool _malformed(String value) {
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        return true;
      }
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      return true;
    }
  }
  return false;
}

class AdminWord {
  AdminWord({
    required this.id,
    required this.revision,
    required this.published,
    required this.retired,
    required this.draft,
  });
  final String id;
  final int revision;
  final bool published, retired;
  final WordDraft draft;
  factory AdminWord.fromJson(String id, Map<String, dynamic> data) {
    final draft = WordDraft.fromJson(data);
    if (draft.validate() != null ||
        data['revision'] is! int ||
        (data['revision'] as int) < 0 ||
        data['isPublished'] is! bool ||
        data['isRetired'] is! bool ||
        (data['isPublished'] == true && data['isRetired'] == true)) {
      throw const FormatException('Unsupported word schema');
    }
    return AdminWord(
      id: id,
      revision: data['revision'] as int,
      published: data['isPublished'] as bool,
      retired: data['isRetired'] as bool,
      draft: draft,
    );
  }
  String get status => retired
      ? 'Retired'
      : published
      ? 'Published'
      : 'Draft / unpublished';
}

enum PublicationFilter { all, published, draft, retired }

class WordFilters {
  const WordFilters({
    this.prefix = '',
    this.publication = PublicationFilter.all,
    this.category,
    this.difficulty,
  });
  final String prefix;
  final PublicationFilter publication;
  final Category? category;
  final Difficulty? difficulty;
}

/// A Unicode prefix successor avoids relying on an unsupported full-text query.
String? prefixEnd(String prefix) {
  final runes = prefix.runes.toList();
  while (runes.isNotEmpty && runes.last == 0x10ffff) {
    runes.removeLast();
  }
  if (runes.isEmpty) return null;
  var next = runes.removeLast() + 1;
  if (next == 0xd800) next = 0xe000;
  return String.fromCharCodes([...runes, next]);
}

class WordPage {
  const WordPage(this.words, {this.nextCursor, this.hasNext = false});
  final List<AdminWord> words;
  final Object? nextCursor;
  final bool hasNext;
}

class PublicationFailure implements Exception {
  const PublicationFailure(
    this.code,
    this.message, {
    this.retryable = false,
    this.denied = false,
  });
  final String code, message;
  final bool retryable, denied;
  @override
  String toString() => message;
}

class PendingMutation {
  PendingMutation({
    required this.uid,
    required String wordId,
    required String action,
    required int revision,
    WordDraft? draft,
    bool reviewed = false,
  }) : body = jsonEncode({
         'operationId': newId(),
         'wordId': wordId,
         'action': action,
         'expectedRevision': revision,
         'reviewed': reviewed,
         if (draft != null) 'content': draft.toJson(),
       });
  final String uid;

  /// Frozen exact request bytes: retries cannot acquire a new ID or changed payload.
  final String body;
}

class MutationAck {
  const MutationAck(this.wordId, this.revision, this.published, this.retired);
  final String wordId;
  final int revision;
  final bool published, retired;
}
