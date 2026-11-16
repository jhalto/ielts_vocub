import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:admin_panel/features/users/client.dart';

import 'fake_imports.dart' show ImportCredentials;

Map<String, dynamic> userDto(
  String uid, {
  String role = 'student',
  int revision = 0,
  bool pending = false,
}) => {
  'uid': uid,
  'name': 'Synthetic $uid',
  'email': '$uid@example.test',
  'providers': ['password'],
  'emailVerified': true,
  'disabled': false,
  'role': role,
  'createdAt': 'Mon, 16 Nov 2026 00:00:00 GMT',
  'lastSignInAt': null,
  'administrationRevision': revision,
  'administrationPending': pending,
  'authState': revision.toRadixString(16).padLeft(64, '0'),
};
http.Response userReply(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class FakeUserAdmin {
  final credentials = ImportCredentials();
  final users = <String, Map<String, dynamic>>{
    'bob': userDto('bob', role: 'super_admin'),
    'target': userDto('target'),
  };
  final requests = <Map<String, dynamic>>[],
      bodies = <String>[],
      waits = <Duration>[];
  final operations = <String, Map<String, dynamic>>{};
  final operationBodies = <String, String>{};
  List<Map<String, dynamic>>? pages;
  String mode = 'complete';
  bool worker = false;
  String? refusal, transientCode;
  int loseMutations = 0, loseResumes = 0;
  Future<http.Response> Function(http.Request)? intercept;
  UserAdminClient client({void Function()? onDenied}) => UserAdminClient(
    credentials: credentials,
    endpoint: Uri.parse('https://demo.test/userAdminApi'),
    onDenied: onDenied,
    delay: (d) async => waits.add(d),
    client: MockClient(handle),
  );
  void finish(Map<String, dynamic> op) {
    final target = users[op['targetUid']]!;
    final after = op['after'] as Map;
    target['role'] = after['role'];
    target['disabled'] = after['disabled'];
    target['administrationRevision'] = op['revision'];
    target['administrationPending'] = false;
    target['authState'] = (op['revision'] as int)
        .toRadixString(16)
        .padLeft(64, '0');
    op['state'] = 'complete';
    op['phase'] = 'complete';
    op['workerActive'] = false;
    op['lastError'] = null;
    op['result'] = {
      'uid': target['uid'],
      'administrationRevision': op['revision'],
      'authState': target['authState'],
      'role': target['role'],
      'disabled': target['disabled'],
      'emailVerified': target['emailVerified'],
      'reauthenticateAfter': 1760000000,
    };
  }

  Future<http.Response> handle(http.Request request) async {
    final data = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add(data);
    bodies.add(request.body);
    if (intercept != null) return intercept!(request);
    final action = data['action'];
    if (action == 'list') {
      if (pages != null) {
        return userReply(pages![data['cursor'] == null ? 0 : 1]);
      }
      return userReply({
        'schemaVersion': 1,
        'users': users.values.toList(),
        'scanned': users.length,
        'nextCursor': null,
      });
    }
    if (action == 'get') {
      final found = users.values
          .where(
            (u) => data['uid'] != null
                ? u['uid'] == data['uid']
                : u['email'] == data['email'],
          )
          .toList();
      return found.isEmpty
          ? userReply({'code': 'user-not-found'}, 404)
          : userReply({'schemaVersion': 1, 'user': found.single});
    }
    if (action == 'operation' || action == 'resume') {
      final op = operations[data['operationKey']];
      if (op == null) return userReply({'code': 'operation-not-found'}, 404);
      if (action == 'resume' &&
          op['state'] == 'pending' &&
          op['workerActive'] == false) {
        finish(op);
        if (loseResumes-- > 0) {
          throw http.ClientException('Synthetic lost resume acknowledgement');
        }
      }
      return userReply(op);
    }
    if (refusal != null) return userReply({'code': refusal}, 409);
    final id = data['operationId'] as String;
    final existing = operations.values
        .where((o) => o['operationId'] == id)
        .toList();
    Map<String, dynamic> op;
    if (existing.isNotEmpty) {
      op = existing.single;
      if (operationBodies[id] != request.body) {
        return userReply({'code': 'operation-id-reused'}, 409);
      }
    } else {
      final target = users[data['targetUid']];
      if (target == null) return userReply({'code': 'user-not-found'}, 404);
      if (target['administrationRevision'] != data['expectedRevision']) {
        return userReply({'code': 'revision-conflict'}, 409);
      }
      if (target['authState'] != data['expectedState']) {
        return userReply({'code': 'auth-state-conflict'}, 409);
      }
      final before = {
        'role': target['role'],
        'disabled': target['disabled'],
        'emailVerified': target['emailVerified'],
      };
      final after = {
        ...before,
        if (action == 'setRole')
          'role': data['role']
        else
          'disabled': data['disabled'],
      };
      final key = id.padRight(64, '0');
      op = {
        'schemaVersion': 1,
        'operationKey': key,
        'operationId': id,
        'actorUid': 'bob',
        'targetUid': target['uid'],
        'action': action,
        'state': mode == 'recovery_required' ? 'recovery_required' : 'pending',
        'phase': 'confirmation',
        'revision': (target['administrationRevision'] as int) + 1,
        'before': before,
        'after': after,
        'workerActive': mode == 'recovery_required' || worker,
        'lastError': mode == 'recovery_required'
            ? {'code': 'service-unavailable', 'retryable': false}
            : transientCode == null
            ? null
            : {'code': transientCode, 'retryable': true},
        'result': null,
      };
      target['administrationPending'] = true;
      operationBodies[id] = request.body;
      operations[key] = op;
      if (mode == 'complete') finish(op);
    }
    if (loseMutations-- > 0) {
      throw http.ClientException('Synthetic lost mutation acknowledgement');
    }
    return userReply(op);
  }
}
