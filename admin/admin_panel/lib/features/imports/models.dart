import 'dart:convert';
import 'dart:typed_data';

import '../words/models.dart';

const importByteLimit = 524288;
bool validImportId(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value);
Map<String, dynamic> jsonObject(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object.');
  }
  return value;
}

Map<String, dynamic> copyJson(Map<String, dynamic> value) =>
    jsonObject(jsonDecode(jsonEncode(value)));
Map<String, dynamic> readImportFile(String name, String mime, Uint8List bytes) {
  if (!name.toLowerCase().endsWith('.json') ||
      !['', 'application/json', 'text/json'].contains(mime.toLowerCase())) {
    throw const FormatException(
      'Select a .json file with JSON content. CSV is not supported.',
    );
  }
  if (bytes.length > importByteLimit) {
    throw const FormatException(
      'JSON files must fit 512 KiB, including the API request envelope.',
    );
  }
  final file = jsonObject(jsonDecode(utf8.decode(bytes)));
  if (file.keys.any((k) => !['schemaVersion', 'items'].contains(k)) ||
      file['schemaVersion'] != 1 ||
      file['items'] is! List ||
      (file['items'] as List).isEmpty ||
      (file['items'] as List).length > 50) {
    throw const FormatException(
      'Expected schemaVersion 1 and 1–50 items. See docs/import_api.md.',
    );
  }
  for (final row in file['items'] as List) {
    if (row is Map) row.remove('reviewed');
  }
  return file;
}

class ImportJob {
  ImportJob(this.id, this.status, this.counts);
  final String id, status;
  final Map<String, int> counts;
  factory ImportJob.parse(Map<String, dynamic> data, String expectedId) {
    final counts = data['counts'];
    if (data['schemaVersion'] != 1 ||
        data['jobId'] != expectedId ||
        ![
          'ready',
          'completed',
          'completed_with_errors',
        ].contains(data['status']) ||
        counts is! Map ||
        counts.length != 5) {
      throw const FormatException('Invalid job response.');
    }
    final result = <String, int>{};
    for (final key in ['total', 'pending', 'applied', 'skipped', 'failed']) {
      final value = counts[key];
      if (value is! int || value < 0 || value > 50) {
        throw const FormatException('Invalid job counts.');
      }
      result[key] = value;
    }
    if (result['total'] == 0 ||
        result['total'] !=
            result['pending']! +
                result['applied']! +
                result['skipped']! +
                result['failed']! ||
        (result['pending']! > 0
            ? data['status'] != 'ready'
            : data['status'] !=
                  (result['failed']! > 0
                      ? 'completed_with_errors'
                      : 'completed'))) {
      throw const FormatException('Inconsistent job counts.');
    }
    return ImportJob(
      expectedId,
      data['status'] as String,
      Map.unmodifiable(result),
    );
  }
}

class ImportReceipt {
  ImportReceipt(
    this.id,
    this.index,
    this.decision,
    this.state,
    this.wordId,
    this.errorCode,
    this.retryable,
    this.result,
  );
  final String id, decision, state;
  final int index;
  final String? wordId, errorCode;
  final bool retryable;
  final Map<String, dynamic>? result;
  factory ImportReceipt.parse(Object? raw) {
    final data = jsonObject(raw), error = data['lastError'];
    if (!validImportId(data['itemId']) ||
        data['index'] is! int ||
        (data['index'] as int) < 0 ||
        (data['index'] as int) >= 50 ||
        !['create', 'update', 'skip'].contains(data['decision']) ||
        !['pending', 'applied', 'skipped', 'failed'].contains(data['state']) ||
        data['attempts'] is! int ||
        (data['attempts'] as int) < 0 ||
        (data['wordId'] != null && !validImportId(data['wordId'])) ||
        (error != null &&
            (error is! Map ||
                error['code'] is! String ||
                error['retryable'] is! bool))) {
      throw const FormatException('Invalid item receipt.');
    }
    final result = data['result'] == null ? null : jsonObject(data['result']);
    if (data['state'] == 'applied' &&
        (result == null ||
            result['wordId'] != data['wordId'] ||
            result['revision'] is! int ||
            (result['revision'] as int) < 1 ||
            result['isPublished'] is! bool ||
            result['isRetired'] is! bool ||
            (data['decision'] == 'create' && result['isPublished'] != false))) {
      throw const FormatException('Invalid applied receipt.');
    }
    return ImportReceipt(
      data['itemId'] as String,
      data['index'] as int,
      data['decision'] as String,
      data['state'] as String,
      data['wordId'] as String?,
      error == null ? null : error['code'] as String,
      error != null && error['retryable'] == true,
      result,
    );
  }
}

List<Map<String, dynamic>> previewItems(
  Map<String, dynamic> data,
  int expectedRows,
) {
  if (data['schemaVersion'] != 1 ||
      data['valid'] is! bool ||
      data['items'] is! List ||
      (data['items'] as List).length != expectedRows) {
    throw const FormatException('Invalid preview response.');
  }
  final rows = (data['items'] as List).map(jsonObject).toList();
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row['index'] != i ||
        row['errors'] is! List ||
        (row['errors'] as List).any((e) => e is! String) ||
        (row['publishable'] != null && row['publishable'] is! bool)) {
      throw const FormatException('Invalid preview row.');
    }
    if (row['content'] != null) WordDraft.fromJson(jsonObject(row['content']));
    if (row['existing'] != null) {
      final existing = jsonObject(row['existing']);
      if (!validImportId(existing['wordId']) ||
          existing['revision'] is! int ||
          existing['isPublished'] is! bool ||
          existing['isRetired'] is! bool) {
        throw const FormatException('Invalid existing target.');
      }
    }
  }
  if (data['valid'] != rows.every((r) => (r['errors'] as List).isEmpty)) {
    throw const FormatException('Inconsistent preview.');
  }
  return rows;
}
