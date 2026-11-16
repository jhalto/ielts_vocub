import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:admin_panel/features/words/models.dart';
import 'package:admin_panel/features/words/repository.dart';

import 'support/fake_vocabulary.dart';

class Credentials implements AdminCredentials {
  @override
  String? uid = 'bob';
  final List<bool> refreshes = [];
  @override
  Future<String> token(bool refresh) async {
    refreshes.add(refresh);
    return refresh ? 'fresh-token' : 'token';
  }
}

String ack(PendingMutation command) => jsonEncode({
  'wordId': jsonDecode(command.body)['wordId'],
  'revision': 2,
  'isPublished': false,
  'isRetired': false,
});
void main() {
  test(
    'HTTP token refresh resends identical frozen body exactly once',
    () async {
      final credentials = Credentials();
      final bodies = <String>[];
      final tokens = <String>[];
      final command = PendingMutation(
        uid: 'bob',
        wordId: 'word-1',
        action: 'edit',
        revision: 1,
        draft: fixtureDraft(),
      );
      final client = PublicationClient(
        credentials: credentials,
        endpoint: Uri.parse('https://example.test/contentApi'),
        client: MockClient((request) async {
          bodies.add(request.body);
          tokens.add(request.headers['Authorization']!);
          return bodies.length == 1
              ? http.Response('{"code":"unauthenticated"}', 401)
              : http.Response(ack(command), 200);
        }),
      );
      await client.send(command);
      expect(bodies, [command.body, command.body]);
      expect(credentials.refreshes, [false, true]);
      expect(tokens, ['Bearer token', 'Bearer fresh-token']);
      client.close();
    },
  );
  test('account switch mid-request discards the result and blocks another UID retry', () async {
    final credentials = Credentials();
    final response = Completer<http.Response>();
    var denied = 0;
    final command = PendingMutation(
      uid: 'bob',
      wordId: 'word-1',
      action: 'publish',
      revision: 1,
      reviewed: true,
    );
    final client = PublicationClient(
      credentials: credentials,
      endpoint: Uri.parse('https://example.test'),
      onDenied: () => denied++,
      client: MockClient((_) => response.future),
    );
    final future = client.send(command);
    final assertion = expectLater(
      future,
      throwsA(
        isA<PublicationFailure>().having(
          (e) => e.code,
          'code',
          'account-changed',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    credentials.uid = 'alice';
    response.complete(http.Response(ack(command), 200));
    await assertion;
    await expectLater(client.send(command), throwsA(isA<PublicationFailure>()));
    expect(denied, 2);
    client.close();
  });
  test('network/server errors retain retry semantics while duplicate/conflict errors are terminal', () async {
    final credentials = Credentials();
    final command = PendingMutation(
      uid: 'bob',
      wordId: 'word-1',
      action: 'publish',
      revision: 1,
      reviewed: true,
    );
    for (final pair in [
      (503, 'service-unavailable', true),
      (429, 'rate-limited', true),
      (409, 'transaction-contention', true),
      (409, 'revision-conflict', false),
      (409, 'duplicate-spelling', false),
    ]) {
      final client = PublicationClient(
        credentials: credentials,
        endpoint: Uri.parse('https://example.test'),
        client: MockClient(
          (_) async => http.Response(jsonEncode({'code': pair.$2}), pair.$1),
        ),
      );
      await expectLater(
        client.send(command),
        throwsA(
          isA<PublicationFailure>().having(
            (e) => e.retryable,
            'retryable',
            pair.$3,
          ),
        ),
      );
      client.close();
    }
  });
  test(
    'a 403 fails closed and triggers reauthorization without further writes',
    () async {
      var attempts = 0, denials = 0;
      final credentials = Credentials();
      final client = PublicationClient(
        credentials: credentials,
        endpoint: Uri.parse('https://example.test'),
        onDenied: () => denials++,
        client: MockClient((_) async {
          attempts++;
          return http.Response('{"code":"permission-denied"}', 403);
        }),
      );
      await expectLater(
        client.send(
          PendingMutation(
            uid: 'bob',
            wordId: 'w',
            action: 'retire',
            revision: 1,
          ),
        ),
        throwsA(
          isA<PublicationFailure>().having((e) => e.denied, 'denied', true),
        ),
      );
      expect(attempts, 1);
      expect(denials, 1);
      client.close();
    },
  );
}
