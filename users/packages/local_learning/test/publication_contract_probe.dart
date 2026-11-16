// Run after the publication emulator suite exports a synthetic public snapshot.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:local_learning/local_learning.dart';

class SnapshotSource implements PublishedContentSource {
  SnapshotSource(this.snapshot, this.words);
  final ContentSnapshot snapshot;
  final List<VocabularyWord> words;
  @override
  Future<ContentSnapshot> manifest() async => snapshot;
  @override
  Future<List<VocabularyWord>> page(
    Category? category,
    String? afterId,
  ) async => words
      .where(
        (word) =>
            (category == null || word.category == category) &&
            (afterId == null || word.id.compareTo(afterId) > 0),
      )
      .take(100)
      .toList();
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError(
      'Pass the emulator-exported public snapshot JSON file.',
    );
  }
  final json = jsonDecode(
    await File(arguments.single).readAsString(),
  ) as Map<String, dynamic>;
  final manifest = json['manifest'] as Map<String, dynamic>;
  final snapshot = ContentSnapshot.fromJson(manifest);
  final words =
      (json['words'] as List)
          .map(
            (item) =>
                VocabularyWord.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  if (words.length != 2 || snapshot.groupCounts.length != 9) {
    throw StateError(
      'Expected two published synthetic fixtures and nine groups',
    );
  }
  final db = LearningStore(NativeDatabase.memory());
  try {
    final count = await ContentDownloader(
      db,
      SnapshotSource(snapshot, words),
    ).download(null, cancelled: () => false);
    if (count != 2 || (await db.downloads()).length != 9) {
      throw StateError('Snapshot did not download completely');
    }
    final allGroups = await db.downloads();
    if (allGroups.any(
      (group) =>
          group['complete'] != 1 || group['revision'] != snapshot.revision,
    )) {
      throw StateError('Completeness/version mismatch');
    }
    for (final word in words) {
      final local = await db.browse(
        category: word.category,
        difficulty: word.difficulty,
      );
      if (local.single.toJson().toString() != word.toJson().toString()) {
        throw StateError('Lossy bilingual serialization');
      }
      if (!local.single.senses.first.bengaliMeaning.codeUnits.any(
        (code) => code >= 0x0980 && code <= 0x09ff,
      )) {
        throw StateError('Bengali text was lost');
      }
    }
    stdout.writeln(
      'PASS: server publication -> shared Dart models -> unchanged Drift downloader; all nine groups complete.',
    );
  } finally {
    await db.close();
  }
}
