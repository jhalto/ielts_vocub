/// Wire values are stable. Unknown values fail rather than silently migrating.
enum Category { basic, intermediate, advanced }

enum Difficulty { easy, medium, advanced }

enum PartOfSpeech {
  noun,
  verb,
  adjective,
  adverb,
  pronoun,
  preposition,
  conjunction,
  interjection,
  determiner,
}

enum ProgressStatus {
  alreadyKnow('already_know'),
  learned('learned'),
  didntKnow('didnt_know');

  const ProgressStatus(this.wireValue);
  final String wireValue;
  static ProgressStatus parse(String value) => values.firstWhere(
    (status) => status.wireValue == value,
    orElse: () => throw FormatException('Unknown progress status: $value'),
  );
}

enum UserRole {
  superAdmin('super_admin'),
  contentManager('content_manager'),
  student('student');

  const UserRole(this.wireValue);
  final String wireValue;
}

String _text(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty || value.length > 4000) {
    throw FormatException('Invalid $key');
  }
  return value;
}

int _number(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

T _enum<T extends Enum>(List<T> values, Object? value) => values.firstWhere(
  (item) => item.name == value,
  orElse: () => throw FormatException('Unknown enum: $value'),
);
List<T> _list<T>(Object? value, T Function(Map<String, dynamic>) parse) {
  if (value is! List || value.isEmpty || value.length > 100) {
    throw const FormatException('Expected 1-100 nested records');
  }
  return List.unmodifiable(
    value.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Invalid record');
      }
      return parse(item);
    }),
  );
}

final class ExamplePair {
  const ExamplePair({required this.english, required this.bengali});
  final String english;
  final String bengali;
  factory ExamplePair.fromJson(Map<String, dynamic> json) => ExamplePair(
    english: _text(json, 'english'),
    bengali: _text(json, 'bengali'),
  );
  Map<String, dynamic> toJson() => {'english': english, 'bengali': bengali};
}

final class WordSense {
  WordSense({
    required this.id,
    required this.partOfSpeech,
    required this.englishMeaning,
    required this.bengaliMeaning,
    required this.ordering,
    required List<ExamplePair> examples,
  }) : examples = List.unmodifiable(examples);
  final String id;
  final PartOfSpeech partOfSpeech;
  final String englishMeaning;
  final String bengaliMeaning;
  final int ordering;
  final List<ExamplePair> examples;
  factory WordSense.fromJson(Map<String, dynamic> json) => WordSense(
    id: _text(json, 'id'),
    partOfSpeech: _enum(PartOfSpeech.values, json['partOfSpeech']),
    englishMeaning: _text(json, 'englishMeaning'),
    bengaliMeaning: _text(json, 'bengaliMeaning'),
    ordering: _number(json, 'ordering'),
    examples: _list(json['examples'], ExamplePair.fromJson),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'partOfSpeech': partOfSpeech.name,
    'englishMeaning': englishMeaning,
    'bengaliMeaning': bengaliMeaning,
    'ordering': ordering,
    'examples': examples.map((e) => e.toJson()).toList(),
  };
}

/// Content payload; Firestore timestamps are converted by repository adapters.
final class VocabularyWord {
  VocabularyWord({
    required this.id,
    required this.spelling,
    required this.pronunciation,
    required this.category,
    required this.difficulty,
    required this.ordering,
    required this.revision,
    required this.isPublished,
    required this.isRetired,
    required List<WordSense> senses,
  }) : senses = List.unmodifiable(senses);
  final String id;
  final String spelling;
  final String pronunciation;
  final Category category;
  final Difficulty difficulty;
  final int ordering;
  final int revision;
  final bool isPublished;
  final bool isRetired;
  final List<WordSense> senses;
  factory VocabularyWord.fromJson(Map<String, dynamic> json) {
    if (json['isPublished'] is! bool || json['isRetired'] is! bool) {
      throw const FormatException('Invalid publication flags');
    }
    final senses = _list(json['senses'], WordSense.fromJson);
    if (senses.map((s) => s.id).toSet().length != senses.length) {
      throw const FormatException('Duplicate sense ID');
    }
    return VocabularyWord(
      id: _text(json, 'id'),
      spelling: _text(json, 'spelling'),
      pronunciation: _text(json, 'pronunciation'),
      category: _enum(Category.values, json['category']),
      difficulty: _enum(Difficulty.values, json['difficulty']),
      ordering: _number(json, 'ordering'),
      revision: _number(json, 'revision'),
      isPublished: json['isPublished'] as bool,
      isRetired: json['isRetired'] as bool,
      senses: senses,
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'spelling': spelling,
    'pronunciation': pronunciation,
    'category': category.name,
    'difficulty': difficulty.name,
    'ordering': ordering,
    'revision': revision,
    'isPublished': isPublished,
    'isRetired': isRetired,
    'senses': senses.map((s) => s.toJson()).toList(),
  };
}
