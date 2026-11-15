import 'package:shared_models/shared_models.dart';
import 'package:test/test.dart';

Map<String, dynamic> fixture() => {
  'id': 'test-word',
  'spelling': 'test',
  'pronunciation': 'test',
  'category': 'advanced',
  'difficulty': 'advanced',
  'ordering': 0,
  'revision': 1,
  'isPublished': true,
  'isRetired': false,
  'senses': [
    for (var i = 0; i < 2; i++)
      {
        'id': 'sense-$i',
        'partOfSpeech': 'noun',
        'englishMeaning': 'Test fixture $i',
        'bengaliMeaning': 'পরীক্ষা $i',
        'ordering': i,
        'examples': [
          {'english': 'Fixture only.', 'bengali': 'শুধু পরীক্ষা।'},
        ],
      },
  ],
};
void main() {
  test('lossless nested Bengali round trip and repeated part of speech', () {
    final json = fixture();
    final word = VocabularyWord.fromJson(json);
    expect(word.toJson(), json);
    expect(word.senses.length, 2);
    expect(
      word.senses.first.bengaliMeaning.codeUnits.any(
        (c) => c >= 0x0980 && c <= 0x09ff,
      ),
      isTrue,
    );
    expect(word.category, Category.advanced);
    expect(word.difficulty, Difficulty.advanced);
    expect(() => word.senses.clear(), throwsUnsupportedError);
  });
  test('reject unknown enums, missing translations, invalid flags and duplicate sense IDs', () {
    for (final edit in <void Function(Map<String, dynamic>)>[
      (j) => j['category'] = 'new',
      (j) => j['difficulty'] = 'unknown',
      (j) => j['isPublished'] = 'true',
      (j) => j['revision'] = -1,
      (j) => (j['senses'] as List)[0]['bengaliMeaning'] = '',
      (j) => (j['senses'] as List)[1]['id'] = 'sense-0',
    ]) {
      final j = fixture();
      edit(j);
      expect(() => VocabularyWord.fromJson(j), throwsFormatException);
    }
  });
  test('only three persisted progress states', () {
    expect(ProgressStatus.values.length, 3);
    expect(ProgressStatus.parse('didnt_know'), ProgressStatus.didntKnow);
    expect(() => ProgressStatus.parse('learning'), throwsFormatException);
  });
}
