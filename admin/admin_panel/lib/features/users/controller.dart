import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../imports/models.dart' show jsonObject;
import '../imports/platform_types.dart' show ImportSession;
import '../words/models.dart' show PublicationFailure;
import 'client.dart';
import 'models.dart';

const rejectedChanges = {
  'invalid-input',
  'revision-conflict',
  'auth-state-conflict',
  'last-super-admin',
  'self-change-not-allowed',
  'already-in-state',
  'target-not-eligible',
  'unsupported-role',
  'custom-claims-too-large',
  'user-not-found',
  'admin-state-drift',
  'administration-busy',
};

class UserAdminController extends ChangeNotifier {
  UserAdminController({
    required this.uid,
    required this.client,
    required this.session,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    try {
      final saved = session.read();
      if (saved != null) {
        final d = jsonObject(jsonDecode(saved));
        if (d['schemaVersion'] != 1 ||
            d['uid'] != uid ||
            (d['key'] != null && !securityHash(d['key']))) {
          throw const FormatException('Invalid checkpoint.');
        }
        final body = d['body'];
        if (body != null && body is! String) {
          throw const FormatException('Invalid request.');
        }
        final restored = body == null
            ? null
            : FrozenUserChange.parse(body as String);
        if (restored == null && d['key'] == null) {
          throw const FormatException('Empty checkpoint.');
        }
        frozen = restored;
        operationKey = d['key'] as String?;
      }
    } catch (_) {
      error = const PublicationFailure(
        'checkpoint',
        'Recovery storage could not be read. Use a saved operation key or ask a trusted operator; no request was submitted.',
      );
    }
  }
  final String uid;
  final UserAdminClient client;
  final ImportSession session;
  final DateTime Function() clock;
  UserDirectoryPage? directory;
  UserSummary? selected;
  UserOperation? operation;
  FrozenUserChange? frozen;
  String? operationKey;
  Map<String, dynamic> filters = const {};
  final List<String?> _previous = [];
  String? _cursor;
  bool busy = false,
      available = true,
      selectedStale = true,
      _disposed = false,
      rejected = false;
  int _epoch = 0;
  PublicationFailure? error;
  DateTime? nextRetry;
  bool get canRequest =>
      available &&
      !busy &&
      (nextRetry == null || !clock().isBefore(nextRetry!));
  bool get hasPrevious => _previous.isNotEmpty;
  bool get hasIntent => frozen != null || operationKey != null;
  bool get canChange =>
      canRequest &&
      !hasIntent &&
      selected != null &&
      !selectedStale &&
      !selected!.pending &&
      selected!.uid != uid &&
      selected!.role != 'unsupported';
  bool get canResume =>
      canRequest &&
      operation != null &&
      operation!.state == 'pending' &&
      !operation!.worker &&
      operation!.target != uid;
  bool get mustWarn =>
      busy ||
      frozen != null ||
      (operationKey != null && operation?.complete != true);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _save() {
    try {
      if (!hasIntent) {
        session.clear();
        return;
      }
      session.write(
        jsonEncode({
          'schemaVersion': 1,
          'uid': uid,
          if (operationKey != null) 'key': operationKey,
          if (frozen != null) 'body': frozen!.body,
        }),
      );
    } catch (_) {
      throw const PublicationFailure(
        'checkpoint',
        'Recovery storage is unavailable. Keep the operation ID/key. A new change is not sent until its frozen request can be stored.',
      );
    }
  }

  void setAccess(bool allowed, {bool clearPrivate = false}) {
    if (clearPrivate) {
      _epoch++;
      directory = null;
      selected = null;
      operation = null;
      frozen = null;
      operationKey = null;
      _previous.clear();
      _cursor = null;
      filters = const {};
      selectedStale = true;
      rejected = false;
      try {
        session.clear();
      } catch (_) {
        /* Owner/environment isolation still prevents another account loading it. */
      }
    }
    if (available != allowed) {
      _epoch++;
      available = allowed;
      selectedStale = true;
    }
    _notify();
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> body, int epoch) =>
      _sendBody(jsonEncode(body), epoch);
  Future<Map<String, dynamic>> _sendBody(String body, int epoch) => client.send(
    uid,
    body,
    active: () => !_disposed && available && epoch == _epoch,
  );
  Future<void> _run(
    Future<void> Function(int epoch) work, {
    bool submitting = false,
  }) async {
    if (!canRequest) return;
    final epoch = _epoch;
    busy = true;
    error = null;
    nextRetry = null;
    _notify();
    try {
      await work(epoch);
    } catch (e) {
      final sameDenied =
          e is PublicationFailure && e.denied && client.currentUid == uid;
      if (!_disposed && (epoch == _epoch || sameDenied)) {
        error = e is PublicationFailure
            ? e
            : const PublicationFailure(
                'invalid-response',
                'The result could not be confirmed. Keep the operation and inspect status before changing intent.',
                retryable: true,
              );
        if (submitting &&
            frozen != null &&
            epoch == _epoch &&
            rejectedChanges.contains(error!.code)) {
          rejected = true;
        }
        if (error!.retryable) {
          nextRetry = clock().add(
            Duration(
              seconds: error!.code == 'rate-limited'
                  ? 60
                  : error!.code == 'administration-busy'
                  ? 5
                  : 2,
            ),
          );
        }
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<UserDirectoryPage> _page(
    int epoch,
    Map<String, dynamic> chosen,
    String? cursor,
  ) async => UserDirectoryPage.parse(
    await _send({
      'action': 'list',
      'limit': 25,
      'filters': chosen,
      'cursor': ?cursor,
    }, epoch),
    25,
  );
  Future<void> firstPage(Map<String, dynamic> chosen) => _run((epoch) async {
    final snapshot = jsonObject(jsonDecode(jsonEncode(chosen)));
    final page = await _page(epoch, snapshot, null);
    directory = page;
    filters = Map.unmodifiable(snapshot);
    _cursor = null;
    _previous.clear();
  });
  Future<void> nextPage() => _run((epoch) async {
    final next = directory?.next;
    if (next == null) return;
    final page = await _page(epoch, filters, next);
    if (page.next == next) {
      throw const FormatException('Repeated continuation.');
    }
    _previous.add(_cursor);
    _cursor = next;
    directory = page;
  });
  Future<void> previousPage() => _run((epoch) async {
    if (_previous.isEmpty) return;
    final target = _previous.last, page = await _page(epoch, filters, target);
    _previous.removeLast();
    _cursor = target;
    directory = page;
  });
  Future<void> lookup(String value, {required bool byEmail}) =>
      _run((epoch) async {
        if (hasIntent) {
          throw const PublicationFailure(
            'unfinished-operation',
            'Resolve or explicitly finish reviewing the current operation before selecting another target.',
          );
        }
        final response = await _send({
          'action': 'get',
          if (byEmail) 'email': value else 'uid': value,
        }, epoch);
        if (response['schemaVersion'] != 1) {
          throw const FormatException('Unsupported account response.');
        }
        final user = UserSummary.parse(response['user']);
        if (!byEmail && user.uid != value) {
          throw const FormatException('Mismatched user.');
        }
        selected = user;
        selectedStale = false;
      });
  Future<void> refreshSelected() => _run((epoch) async {
    if (selected == null) return;
    final response = await _send({
      'action': 'get',
      'uid': selected!.uid,
    }, epoch);
    if (response['schemaVersion'] != 1) {
      throw const FormatException('Unsupported account response.');
    }
    final user = UserSummary.parse(response['user']);
    if (user.uid != selected!.uid) {
      throw const FormatException('Mismatched user.');
    }
    selected = user;
    selectedStale = false;
  });
  Future<void> submit(
    String action,
    Object value,
    String reason, {
    UserSummary? reviewedTarget,
  }) async {
    if (!canChange) return;
    if (reviewedTarget != null &&
        (reviewedTarget.uid != selected!.uid ||
            reviewedTarget.revision != selected!.revision ||
            reviewedTarget.authState != selected!.authState)) {
      error = const PublicationFailure(
        'local-target-changed',
        'The displayed target changed during confirmation. Review it again.',
      );
      _notify();
      return;
    }
    if ((action == 'setRole' &&
            (value == selected!.role ||
                !userRoles.contains(value) ||
                (value != 'student' &&
                    (selected!.disabled || !selected!.verified)))) ||
        (action == 'setDisabled' && value == selected!.disabled)) {
      error = const PublicationFailure(
        'target-not-eligible',
        'Choose a different permitted state. Administrative grants require enabled, verified targets.',
      );
      _notify();
      return;
    }
    try {
      frozen = FrozenUserChange.create(selected!, action, value, reason);
      rejected = false;
    } catch (_) {
      error = const PublicationFailure(
        'invalid-input',
        'A valid choice and a reason of 5–500 characters are required.',
      );
      _notify();
      return;
    }
    await retryOriginal();
  }

  void _accept(Map<String, dynamic> response, {String? key}) {
    final value = UserOperation.parse(response, expectedKey: key);
    final original = frozen?.data;
    if (original != null &&
        (value.id != original['operationId'] ||
            value.actor != uid ||
            value.target != original['targetUid'] ||
            value.action != original['action'] ||
            value.revision != (original['expectedRevision'] as int) + 1 ||
            (value.action == 'setRole'
                ? value.after['role'] != original['role']
                : value.after['disabled'] != original['disabled']))) {
      throw const FormatException(
        'Operation does not match the frozen intent.',
      );
    }
    operation = value;
    operationKey = value.key;
    frozen = null;
    rejected = false;
    selectedStale = true;
    _save(); // Once confirmed, retain only owner/key; no cached reason/body.
    if (value.errorCode != null &&
        value.retryable &&
        !value.worker &&
        !value.complete) {
      error = PublicationFailure(
        value.errorCode!,
        userAdminMessage(value.errorCode!),
        retryable: true,
      );
      nextRetry = clock().add(
        Duration(seconds: value.errorCode == 'rate-limited' ? 60 : 2),
      );
    }
  }

  Future<void> retryOriginal() => _run((epoch) async {
    final body = frozen?.body;
    if (body == null) return;
    _save(); // BEFORE any mutating request, including a retried unknown outcome.
    _accept(await _sendBody(body, epoch));
  }, submitting: true);
  Future<void> inspect(String key) => _run((epoch) async {
    if (!securityHash(key)) {
      throw const PublicationFailure(
        'operation-key',
        'Enter the 64-character lowercase operation key.',
      );
    }
    final data = await _send({
      'action': 'operation',
      'operationKey': key,
    }, epoch);
    _accept(data, key: key);
  });
  Future<void> refreshOperation() async {
    final key = operationKey;
    if (key != null) await inspect(key);
  }

  Future<void> resume() => _run((epoch) async {
    final current = operation;
    if (current == null ||
        current.state != 'pending' ||
        current.worker ||
        current.target == uid) {
      return;
    }
    _accept(
      await _send({'action': 'resume', 'operationKey': current.key}, epoch),
      key: current.key,
    );
  });
  void beginNewChange() {
    if (!canRequest || (!rejected && operation?.complete != true)) return;
    try {
      session.clear();
    } catch (_) {
      error = const PublicationFailure(
        'checkpoint',
        'Could not clear the old recovery checkpoint. Keep its ID/key and retry.',
      );
      _notify();
      return;
    }
    frozen = null;
    operationKey = null;
    operation = null;
    rejected = false;
    error = null;
    selectedStale = true;
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
