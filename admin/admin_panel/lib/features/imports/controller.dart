import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../words/models.dart';
import 'client.dart';
import 'models.dart';
import 'platform_types.dart';

class ImportController extends ChangeNotifier {
  ImportController({
    required this.uid,
    required this.client,
    required this.session,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    try {
      final saved = session.read();
      if (saved != null) {
        final value = jsonObject(jsonDecode(saved));
        if (value['schemaVersion'] != 1 ||
            value['uid'] != uid ||
            !validImportId(value['jobId'])) {
          throw const FormatException('Invalid recovery checkpoint.');
        }
        jobId = value['jobId'] as String;
        frozenCreate = value['body'] as String?;
        if (frozenCreate != null) {
          final command = jsonObject(jsonDecode(frozenCreate!));
          if (command['action'] != 'create' ||
              command['jobId'] != jobId ||
              utf8.encode(frozenCreate!).length > importByteLimit) {
            throw const FormatException('Invalid recovery request.');
          }
        }
      }
    } catch (_) {
      error = const PublicationFailure(
        'checkpoint',
        'Browser recovery storage could not be read. Use your saved job ID to look up status.',
      );
    }
  }
  final String uid;
  final ImportClient client;
  final ImportSession session;
  final DateTime Function() clock;
  Map<String, dynamic>? _file;
  List<Map<String, dynamic>> previews = [];
  List<ImportReceipt> receipts = [];
  ImportJob? job;
  String? jobId, frozenCreate, fileName;
  PublicationFailure? error;
  DateTime? nextRetry;
  bool busy = false, available = true, confirmed = false, _disposed = false;
  int _epoch = 0, _version = 0, _previewVersion = -1;
  bool get editable => !busy && available && jobId == null;
  bool get canCreate =>
      editable &&
      _file != null &&
      _previewVersion == _version &&
      previews.isNotEmpty &&
      previews.every((r) => (r['errors'] as List).isEmpty);
  bool get canRequest =>
      !busy &&
      available &&
      (nextRetry == null || !clock().isBefore(nextRetry!));
  bool get mustWarn =>
      busy ||
      _file != null ||
      (jobId != null &&
          (!confirmed || job == null || job!.counts['pending']! > 0));
  List<Object?> get rows => _file == null
      ? []
      : List.unmodifiable(
          (_file!['items'] as List).map((r) => jsonDecode(jsonEncode(r))),
        );
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkpoint() {
    try {
      if (jobId == null) {
        session.clear();
        return;
      }
      session.write(
        jsonEncode({
          'schemaVersion': 1,
          'uid': uid,
          'jobId': jobId,
          if (frozenCreate != null) 'body': frozenCreate,
        }),
      );
    } catch (_) {
      throw const PublicationFailure(
        'checkpoint',
        'Recovery storage is unavailable. Enable session storage before creating a job; keep the displayed job ID.',
      );
    }
  }

  void setAvailable(bool value, {bool clearPrivate = false}) {
    if (clearPrivate) {
      _epoch++;
      _file = null;
      previews = [];
      receipts = [];
      frozenCreate = null;
      jobId = null;
      job = null;
      confirmed = false;
      try {
        session.clear();
      } catch (_) {
        /* The owner-scoped checkpoint is never loaded for another UID. */
      }
    }
    if (available != value) {
      _epoch++;
      available = value;
    }
    _notify();
  }

  void load(PickedJson picked) {
    if (!editable) return;
    try {
      final next = readImportFile(picked.name, picked.mime, picked.bytes);
      _file = next;
      fileName = picked.name;
      previews = [];
      _version++;
      _previewVersion = -1;
      error = null;
    } catch (e) {
      error = PublicationFailure(
        'file',
        e is FormatException ? e.message.toString() : 'Could not read JSON.',
      );
    }
    _notify();
  }

  void changeRow(int index, Map<String, dynamic> value) {
    if (!editable || _file == null) return;
    (_file!['items'] as List)[index] = copyJson(value);
    for (final row in _file!['items'] as List) {
      if (row is Map) row.remove('reviewed');
    }
    _version++;
    previews = [];
    _previewVersion = -1;
    error = null;
    _notify();
  }

  void attest(int index) {
    if (!editable ||
        index >= previews.length ||
        previews[index]['existing']?['isPublished'] != true) {
      return;
    }
    final row = (_file!['items'] as List)[index];
    if (row is! Map || row['decision'] != 'update') return;
    row['reviewed'] = true;
    _version++;
    previews = [];
    _previewVersion = -1;
    _notify();
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> body, int epoch) =>
      _sendFrozen(jsonEncode(body), epoch);
  Future<Map<String, dynamic>> _sendFrozen(String body, int epoch) =>
      client.send(
        uid,
        body,
        active: () => !_disposed && available && epoch == _epoch,
      );
  Future<void> _run(Future<void> Function(int epoch) action) async {
    if (!canRequest) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    nextRetry = null;
    _notify();
    try {
      await action(epoch);
    } catch (e) {
      if (!_disposed && epoch == _epoch) {
        error = e is PublicationFailure
            ? e
            : const PublicationFailure(
                'invalid-response',
                'The server outcome or local recovery could not be confirmed. Check status before retrying.',
                retryable: true,
              );
        if (error!.retryable) {
          nextRetry = clock().add(
            Duration(seconds: error!.code == 'rate-limited' ? 60 : 2),
          );
        }
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> preview() => _run((epoch) async {
    if (_file == null || jobId != null) return;
    final response = await _send({'action': 'preview', 'import': _file}, epoch);
    previews = previewItems(response, (_file!['items'] as List).length);
    _previewVersion = _version;
  });
  Future<void> create() => _run((epoch) async {
    if (frozenCreate == null) {
      // _run has set busy; use the version/preview preconditions directly.
      if (_file == null ||
          jobId != null ||
          _previewVersion != _version ||
          previews.any((r) => (r['errors'] as List).isNotEmpty)) {
        return;
      }
      final id = newId();
      final body = jsonEncode({
        'action': 'create',
        'jobId': id,
        'import': _file,
      });
      if (utf8.encode(body).length > importByteLimit) {
        throw const PublicationFailure(
          'payload-too-large',
          'The create request including its envelope exceeds 512 KiB. Reduce the file.',
        );
      }
      jobId = id;
      frozenCreate = body;
    }
    _checkpoint(); // Durable immutable bytes BEFORE the first potentially mutating request.
    final response = await _sendFrozen(frozenCreate!, epoch);
    if (response['code'] == 'import-invalid') {
      final file = jsonObject(jsonObject(jsonDecode(frozenCreate!))['import']);
      previews = previewItems(response, (file['items'] as List).length);
      _file = file;
      _previewVersion = _version;
      jobId = null;
      frozenCreate = null;
      confirmed = false;
      _checkpoint();
      return;
    }
    job = ImportJob.parse(response, jobId!);
    confirmed = true;
    frozenCreate = null;
    _file = null;
    previews = [];
    _checkpoint();
    await _refresh(epoch);
  });
  Future<void> _refresh(int epoch) async {
    if (jobId == null) return;
    final selected = jobId!;
    final staged = <ImportReceipt>[];
    String? cursor;
    ImportJob? latest;
    for (var page = 0; page < 3; page++) {
      final response = await _send({
        'action': 'get',
        'jobId': selected,
        'limit': 25,
        'afterItemId': ?cursor,
      }, epoch);
      latest = ImportJob.parse(response, selected);
      if (response['items'] is! List ||
          (response['items'] as List).length > 25) {
        throw const FormatException('Invalid status page.');
      }
      final values = (response['items'] as List)
          .map(ImportReceipt.parse)
          .toList();
      for (final item in values) {
        if (staged.any((r) => r.id == item.id || r.index == item.index) ||
            (staged.isNotEmpty && staged.last.id.compareTo(item.id) >= 0)) {
          throw const FormatException('Invalid status order.');
        }
        staged.add(item);
      }
      final next = response['nextAfterItemId'];
      if (next == null) {
        if (staged.length != latest.counts['total']) {
          throw const FormatException('Incomplete status.');
        }
        // Counts are live; never manufacture a consistent snapshot by replacing them.
        job = latest;
        receipts = staged;
        confirmed = true;
        frozenCreate = null;
        _file = null;
        previews = [];
        _checkpoint();
        return;
      }
      if (!validImportId(next) ||
          values.isEmpty ||
          next != values.last.id ||
          next == cursor) {
        throw const FormatException('Invalid status cursor.');
      }
      cursor = next as String;
    }
    throw const FormatException('Too many status pages.');
  }

  Future<void> refresh() => _run(_refresh);
  Future<void> resume(String id) => _run((epoch) async {
    if (!validImportId(id)) {
      throw const PublicationFailure('job-id', 'Enter a valid job ID.');
    }
    if (frozenCreate != null && id != jobId) {
      throw const PublicationFailure(
        'frozen',
        'Resolve the unconfirmed creation before looking up another job.',
      );
    }
    final oldId = jobId;
    jobId = id;
    try {
      await _refresh(epoch);
    } catch (_) {
      if (epoch == _epoch) jobId = oldId;
      rethrow;
    }
  });
  Future<void> processNext() => _run((epoch) async {
    if (!confirmed || jobId == null) return;
    await _refresh(
      epoch,
    ); // Reconcile unknown acknowledgements before selecting more work.
    final ids = receipts
        .where((r) => r.state == 'pending')
        .take(5)
        .map((r) => r.id)
        .toList();
    if (ids.isEmpty) return;
    final response = await _send({
      'action': 'process',
      'jobId': jobId,
      'itemIds': ids,
    }, epoch);
    final next = ImportJob.parse(response, jobId!);
    if (response['items'] is! List ||
        (response['items'] as List).isEmpty ||
        (response['items'] as List).length > ids.length) {
      throw const FormatException('Invalid process receipts.');
    }
    final values = (response['items'] as List)
        .map(ImportReceipt.parse)
        .toList();
    for (var i = 0; i < values.length; i++) {
      if (values[i].id != ids[i]) {
        throw const FormatException('Mismatched process receipt.');
      }
    }
    job = next;
    await _refresh(epoch);
    final pending = values.where((r) => r.state == 'pending').toList();
    if (pending.isNotEmpty) {
      final code = pending.first.errorCode ?? 'service-unavailable';
      error = PublicationFailure(code, importMessage(code), retryable: true);
      nextRetry = clock().add(
        Duration(seconds: code == 'rate-limited' ? 60 : 2),
      );
    }
  });
  void newPlan() {
    if (busy || !available) return;
    // The UI confirms this does not cancel any existing server job.
    try {
      session.clear();
    } catch (_) {
      error = const PublicationFailure(
        'checkpoint',
        'Could not clear the previous recovery checkpoint.',
      );
      _notify();
      return;
    }
    _file = null;
    previews = [];
    receipts = [];
    job = null;
    jobId = null;
    frozenCreate = null;
    confirmed = false;
    fileName = null;
    error = null;
    nextRetry = null;
    _version++;
    _previewVersion = -1;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    client.close();
    super.dispose();
  }
}
