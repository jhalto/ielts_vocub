import 'dart:convert';

import '../imports/models.dart' show jsonObject;
import '../words/models.dart' show newId;

const userRoles = ['student', 'content_manager', 'super_admin'];
bool userIdValid(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 128 &&
    !RegExp(r'[\x00-\x1f\x7f/]').hasMatch(value) &&
    !['.', '..'].contains(value);
bool securityHash(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
bool revisionValid(Object? value) =>
    value is int && value >= 0 && value < 9007199254740991;

class UserSummary {
  UserSummary(
    this.uid,
    this.name,
    this.email,
    this.providers,
    this.verified,
    this.disabled,
    this.role,
    this.created,
    this.lastSignIn,
    this.revision,
    this.pending,
    this.authState,
  );
  final String uid, name, role, created, authState;
  final String? email, lastSignIn;
  final List<String> providers;
  final bool verified, disabled, pending;
  final int revision;
  factory UserSummary.parse(Object? raw) {
    final d = jsonObject(raw);
    if (!userIdValid(d['uid']) ||
        d['name'] is! String ||
        (d['email'] != null && d['email'] is! String) ||
        d['providers'] is! List ||
        (d['providers'] as List).length > 100 ||
        (d['providers'] as List).any((p) => p is! String) ||
        d['emailVerified'] is! bool ||
        d['disabled'] is! bool ||
        ![...userRoles, 'unsupported'].contains(d['role']) ||
        d['createdAt'] is! String ||
        (d['lastSignInAt'] != null && d['lastSignInAt'] is! String) ||
        !revisionValid(d['administrationRevision']) ||
        d['administrationPending'] is! bool ||
        !securityHash(d['authState'])) {
      throw const FormatException('Unsupported user details.');
    }
    return UserSummary(
      d['uid'] as String,
      d['name'] as String,
      d['email'] as String?,
      List.unmodifiable((d['providers'] as List).cast<String>()),
      d['emailVerified'] as bool,
      d['disabled'] as bool,
      d['role'] as String,
      d['createdAt'] as String,
      d['lastSignInAt'] as String?,
      d['administrationRevision'] as int,
      d['administrationPending'] as bool,
      d['authState'] as String,
    );
  }
}

class UserDirectoryPage {
  UserDirectoryPage(this.users, this.scanned, this.next);
  final List<UserSummary> users;
  final int scanned;
  final String? next;
  factory UserDirectoryPage.parse(Map<String, dynamic> d, int limit) {
    if (d['schemaVersion'] != 1 ||
        d['users'] is! List ||
        (d['users'] as List).length > limit ||
        d['scanned'] is! int ||
        (d['scanned'] as int) < 0 ||
        (d['scanned'] as int) > limit ||
        (d['users'] as List).length > (d['scanned'] as int) ||
        (d['nextCursor'] != null &&
            (d['nextCursor'] is! String ||
                !RegExp(r'^[A-Za-z0-9_-]{1,4096}$')
                    .hasMatch(d['nextCursor'] as String)))) {
      throw const FormatException('Unsupported directory page.');
    }
    final users = (d['users'] as List).map(UserSummary.parse).toList();
    if (users.map((u) => u.uid).toSet().length != users.length) {
      throw const FormatException('Duplicate directory users.');
    }
    return UserDirectoryPage(
      List.unmodifiable(users),
      d['scanned'] as int,
      d['nextCursor'] as String?,
    );
  }
}

Map<String, dynamic> safeState(Object? raw) {
  final d = jsonObject(raw);
  if (!userRoles.contains(d['role']) ||
      d['disabled'] is! bool ||
      d['emailVerified'] is! bool) {
    throw const FormatException('Invalid operation state.');
  }
  return Map.unmodifiable({
    'role': d['role'],
    'disabled': d['disabled'],
    'emailVerified': d['emailVerified'],
  });
}

class UserOperation {
  UserOperation(
    this.key,
    this.id,
    this.actor,
    this.target,
    this.action,
    this.state,
    this.phase,
    this.revision,
    this.before,
    this.after,
    this.worker,
    this.errorCode,
    this.retryable,
    this.signInAfter,
  );
  final String key, id, actor, target, action, state, phase;
  final int revision;
  final Map<String, dynamic> before, after;
  final bool worker, retryable;
  final String? errorCode;
  final int? signInAfter;
  bool get complete => state == 'complete';
  factory UserOperation.parse(Map<String, dynamic> d, {String? expectedKey}) {
    final error = d['lastError'], result = d['result'];
    if (d['schemaVersion'] != 1 ||
        !securityHash(d['operationKey']) ||
        (expectedKey != null && d['operationKey'] != expectedKey) ||
        d['operationId'] is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')
            .hasMatch(d['operationId'] as String) ||
        !userIdValid(d['actorUid']) ||
        !userIdValid(d['targetUid']) ||
        !['setRole', 'setDisabled'].contains(d['action']) ||
        !['pending', 'complete', 'recovery_required'].contains(d['state']) ||
        ![
          'reserved',
          'claims',
          'account-status',
          'revocation',
          'confirmation',
          'complete',
        ].contains(d['phase']) ||
        !revisionValid(d['revision']) ||
        d['revision'] == 0 ||
        d['workerActive'] is! bool ||
        (error != null &&
            (error is! Map ||
                error['code'] is! String ||
                error['retryable'] is! bool))) {
      throw const FormatException('Unsupported operation response.');
    }
    final before = safeState(d['before']), after = safeState(d['after']);
    if (before['emailVerified'] != after['emailVerified'] ||
        (d['action'] == 'setRole'
            ? before['disabled'] != after['disabled']
            : before['role'] != after['role'])) {
      throw const FormatException('Unexpected operation effects.');
    }
    int? signInAfter;
    if (d['state'] == 'complete') {
      if (d['workerActive'] != false ||
          d['phase'] != 'complete' ||
          result is! Map ||
          result['uid'] != d['targetUid'] ||
          result['administrationRevision'] != d['revision'] ||
          !securityHash(result['authState']) ||
          !revisionValid(result['reauthenticateAfter']) ||
          result['reauthenticateAfter'] == 0 ||
          result['role'] != after['role'] ||
          result['disabled'] != after['disabled'] ||
          result['emailVerified'] != after['emailVerified']) {
        throw const FormatException('Unconfirmed completion.');
      }
      signInAfter = result['reauthenticateAfter'] as int;
      if (signInAfter > 253402300799) {
        throw const FormatException('Invalid sign-in timestamp.');
      }
    } else if (result != null ||
        (d['state'] == 'recovery_required' &&
            (d['workerActive'] != true ||
                error == null ||
                error['retryable'] != false))) {
      throw const FormatException('Invalid pending operation.');
    }
    return UserOperation(
      d['operationKey'] as String,
      d['operationId'] as String,
      d['actorUid'] as String,
      d['targetUid'] as String,
      d['action'] as String,
      d['state'] as String,
      d['phase'] as String,
      d['revision'] as int,
      before,
      after,
      d['workerActive'] as bool,
      error == null ? null : error['code'] as String,
      error != null && error['retryable'] == true,
      signInAfter,
    );
  }
}

class FrozenUserChange {
  FrozenUserChange._(this.body, this.data);
  final String body;
  final Map<String, dynamic> data;
  factory FrozenUserChange.create(
    UserSummary user,
    String action,
    Object value,
    String reason,
  ) => FrozenUserChange.parse(
    jsonEncode({
      'action': action,
      'operationId': newId(),
      'targetUid': user.uid,
      'expectedRevision': user.revision,
      'expectedState': user.authState,
      'confirmed': true,
      'reason': reason,
      if (action == 'setRole') 'role': value else 'disabled': value,
    }),
  );
  factory FrozenUserChange.parse(String body) {
    final d = jsonObject(jsonDecode(body)), action = d['action'];
    final allowed = [
      'action',
      'operationId',
      'targetUid',
      'expectedRevision',
      'expectedState',
      'confirmed',
      'reason',
      action == 'setRole' ? 'role' : 'disabled',
    ];
    if (utf8.encode(body).length > 16384 ||
        d.keys.any((k) => !allowed.contains(k)) ||
        !['setRole', 'setDisabled'].contains(action) ||
        !userIdValid(d['targetUid']) ||
        !revisionValid(d['expectedRevision']) ||
        !securityHash(d['expectedState']) ||
        d['confirmed'] != true ||
        d['reason'] is! String ||
        (d['reason'] as String).trim().length < 5 ||
        (d['reason'] as String).length > 500 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(d['reason'] as String) ||
        d['operationId'] is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$')
            .hasMatch(d['operationId'] as String) ||
        (action == 'setRole'
            ? !userRoles.contains(d['role'])
            : d['disabled'] is! bool)) {
      throw const FormatException('Invalid frozen change.');
    }
    return FrozenUserChange._(body, Map.unmodifiable(d));
  }
}
