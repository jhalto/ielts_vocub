import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'repository.dart';

class WordListController extends ChangeNotifier {
  WordListController(this.repository);
  final VocabularyRepository repository;
  WordFilters filters = const WordFilters();
  WordPage? page;
  final List<Object?> _cursors = [null];
  int pageIndex = 0, _request = 0;
  bool loading = false, _disposed = false;
  String? error;
  DateTime? refreshedAt;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load({bool reset = false}) async {
    if (reset) {
      pageIndex = 0;
      _cursors
        ..clear()
        ..add(null);
      page = null;
    }
    final request = ++_request;
    loading = true;
    error = null;
    _emit();
    try {
      final result = await repository.list(filters, after: _cursors[pageIndex]);
      if (_disposed || request != _request) return;
      page = result;
      refreshedAt = DateTime.now();
    } catch (e) {
      if (!_disposed && request == _request) {
        page = null;
        error = e is PublicationFailure
            ? e.message
            : 'Could not load words. Retry.';
      }
    } finally {
      if (!_disposed && request == _request) {
        loading = false;
        _emit();
      }
    }
  }

  Future<void> filter(WordFilters next) {
    filters = next;
    return load(reset: true);
  }

  Future<void> next() async {
    if (loading || page?.hasNext != true) return;
    if (_cursors.length > pageIndex + 1) {
      _cursors.removeRange(pageIndex + 1, _cursors.length);
    }
    _cursors.add(page!.nextCursor);
    pageIndex++;
    await load();
  }

  Future<void> previous() async {
    if (loading || pageIndex == 0) return;
    pageIndex--;
    await load();
  }

  void invalidate() {
    _request++;
    loading = false;
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    super.dispose();
  }
}

class WordEditorController extends ChangeNotifier {
  WordEditorController({
    required this.repository,
    required this.uid,
    AdminWord? word,
  }) : word = word,
       id = word?.id ?? newId(),
       draft = word?.draft.copy() ?? WordDraft() {
    _baseline = jsonEncode(draft.toJson());
  }
  final VocabularyRepository repository;
  final String uid, id;
  AdminWord? word, remote;
  WordDraft draft;
  late String _baseline;
  PendingMutation? pending;
  bool busy = false,
      reviewed = false,
      conflict = false,
      needsReload = false,
      _disposed = false;
  int formGeneration = 0;
  String? error, notice;
  bool get dirty => jsonEncode(draft.toJson()) != _baseline;
  bool get locked =>
      busy ||
      pending != null ||
      word?.retired == true ||
      conflict ||
      needsReload;
  bool get mustWarn => dirty || pending != null;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void changed() {
    reviewed = false;
    error = null;
    notice = null;
    _emit();
  }

  void review(bool value) {
    reviewed = value;
    _emit();
  }

  Future<void> apply(String action) async {
    if (busy || conflict || needsReload) return;
    if (pending != null) {
      await retry();
      return;
    }
    final saving = action == 'create' || action == 'edit';
    if (!saving && dirty) {
      error = 'Save or discard your content changes before changing publication status.';
      _emit();
      return;
    }
    if (saving) {
      final invalid = draft.validate(publishing: word?.published == true);
      if (invalid != null) {
        error = invalid;
        _emit();
        return;
      }
    }
    if ((action == 'publish' || (saving && word?.published == true)) &&
        !reviewed) {
      error = 'Confirm editorial review before publishing or changing published content.';
      _emit();
      return;
    }
    if (action == 'publish') {
      final invalid = draft.validate(publishing: true);
      if (invalid != null) {
        error = invalid;
        _emit();
        return;
      }
    }
    pending = PendingMutation(
      uid: uid,
      wordId: id,
      action: action,
      revision: word?.revision ?? 0,
      draft: saving ? draft.copy() : null,
      reviewed: reviewed,
    );
    await _send();
  }

  Future<void> retry() async {
    if (pending != null && !busy) await _send();
  }

  Future<void> _send() async {
    final command = pending;
    if (command == null) return;
    busy = true;
    error = null;
    notice = null;
    _emit();
    try {
      final result = await repository.mutate(command);
      if (_disposed) return;
      word = AdminWord(
        id: result.wordId,
        revision: result.revision,
        published: result.published,
        retired: result.retired,
        draft: draft.copy(),
      );
      pending = null;
      reviewed = false;
      _baseline = jsonEncode(draft.toJson());
      notice =
          'Saved revision ${result.revision}. Server state: ${word!.status}.';
      try {
        final fresh = await repository.get(id);
        if (_disposed) return;
        _useServer(fresh);
        if (fresh.revision > result.revision) {
          notice =
              'Your operation succeeded. A newer server revision ${fresh.revision} is now displayed.';
        }
      } catch (_) {
        needsReload = true;
        if (!_disposed) {
          notice =
              'Save confirmed at revision ${result.revision}, but reload failed. Reload before making another change.';
        }
      }
    } on PublicationFailure catch (e) {
      if (_disposed) return;
      error = e.message;
      if (!e.retryable && !e.denied) pending = null;
      conflict = [
        'revision-conflict',
        'word-exists',
        'operation-id-reused',
      ].contains(e.code);
    } catch (_) {
      if (!_disposed) error = 'The result is uncertain. Retry the same operation; do not start another save.';
    } finally {
      if (!_disposed) {
        busy = false;
        _emit();
      }
    }
  }

  void _useServer(AdminWord server) {
    word = server;
    draft = server.draft.copy();
    _baseline = jsonEncode(draft.toJson());
    formGeneration++;
    reviewed = false;
    remote = null;
    conflict = false;
    needsReload = false;
  }

  Future<void> compare() async {
    if (busy) return;
    busy = true;
    error = null;
    _emit();
    try {
      final latest = await repository.get(id);
      if (!_disposed) remote = latest;
    } catch (e) {
      if (!_disposed) {
        error = e is PublicationFailure
            ? e.message
            : 'Could not fetch the current server version.';
      }
    } finally {
      if (!_disposed) {
        busy = false;
        _emit();
      }
    }
  }

  void resolve({required bool keepDraft}) {
    final latest = remote;
    if (latest == null || busy) return;
    pending = null;
    if (keepDraft) {
      word = latest;
      _baseline = jsonEncode(latest.draft.toJson());
      reviewed = false;
      conflict = false;
      needsReload = false;
      remote = null;
    } else {
      _useServer(latest);
    }
    error = null;
    notice = keepDraft
        ? 'Local draft kept against revision ${word!.revision}. Review it carefully before saving.'
        : 'Server version loaded.';
    _emit();
  }

  Future<void> reload() async {
    await compare();
    if (remote != null) resolve(keepDraft: false);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
