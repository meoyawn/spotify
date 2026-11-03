import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';
import 'package:spotify_flutter/protocol/native_login5_request.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-login5-retry.json').readAsStringSync()) as Map<String, dynamic>;

  test('Shared v3/v4 request headers follow original counter sequences at exact nanosecond boundaries', () {
    for (final item in fixture['scenarios'] as List<dynamic>) {
      final row = item as Map<String, dynamic>;
      // Nonzero seeds are original uint32 wrap probes, not a production state
      // restoration API. Normal owner construction always starts at zero.
      if (row['initialCount'] != 0) continue;
      var now = 0, requestNumber = 0;
      final planner = NativeLogin5RequestPlanner(counter: NativeLogin5RetryCounter(monotonicNowNanoseconds: () => now));
      for (final value in row['steps'] as List<dynamic>) {
        final step = value as Map<String, dynamic>;
        now = step['nowNanoseconds'] as int;
        switch (step['action']) {
          case 'failure': planner.recordHttpResponse(statusCode: 503, parsedNonemptyBody: false);
          case 'reset': planner.recordHttpResponse(statusCode: 200, parsedNonemptyBody: true);
          case 'read':
            final version = requestNumber++ % 2 == 0 ? NativeLogin5Version.v3 : NativeLogin5Version.v4;
            final request = planner.plan(version: version, body: const []).request;
            expect(request.headers['X-Retry-Count'], '${step['returnedCount']}', reason: '${row['name']} at $now');
        }
      }
    }
  });

  test('Credential planning retains original body bytes and native explicit header spelling/override semantics', () {
    final bodies = jsonDecode(File('reverse-engineering/fixtures/native-login5-credentials.json').readAsStringSync()) as Map<String, dynamic>;
    final stored = (bodies['cases'] as List<dynamic>).cast<Map<String, dynamic>>().singleWhere((row) => row['name'] == 'stored binary');
    final input = stored['credential'] as Map<String, dynamic>;
    final planner = NativeLogin5RequestPlanner(counter: NativeLogin5RetryCounter(monotonicNowNanoseconds: () => 100),
      inheritedHeaders: const {'content-type': 'wrong', 'cache-CONTROL': 'cached', 'x-RETRY-count': '999', 'X-Fixture': 'value'});
    planner.recordHttpResponse(statusCode: 500, parsedNonemptyBody: false);
    final plan = planner.credentialsV3(NativeLogin5Credentials(clientId: stored['clientId'] as String, deviceId: stored['deviceId'] as String),
      NativeLogin5StoredCredential(username: input['id'] as String, data: hex.decode(input['secretHex'] as String)));
    expect(plan.request.toJson(), {'method': 'POST', 'url': 'https://login5.spotify.com/v3/login',
      'headers': {'content-type': 'application/x-protobuf', 'cache-CONTROL': 'no-cache, no-store, max-age=0', 'x-RETRY-count': '1', 'X-Fixture': 'value'},
      'bodyBase64': base64.encode(hex.decode((stored['result'] as Map<String, dynamic>)['hex'] as String)),
      'authorize': false, 'includeCredentials': false, 'responseType': 'bytes', 'nativeTimeoutMilliseconds': 30000});
    expect(plan.option101c203a8, 30000);
    final explicit = planner.plan(version: NativeLogin5Version.v4, body: const [0, 255, 0]).request;
    expect(explicit.url, 'https://login5.spotify.com/v4/login');
    expect(explicit.body, [0, 255, 0]);
  });

  test('Response reporting counts HTTP/parser failures, ignores only native abort, and resets parsed 200 before dispatch', () {
    final planner = NativeLogin5RequestPlanner(counter: NativeLogin5RetryCounter(monotonicNowNanoseconds: () => 100));
    String count() => planner.plan(version: NativeLogin5Version.v3, body: const []).request.headers['X-Retry-Count']!;
    planner.recordHttpResponse(statusCode: 400, parsedNonemptyBody: true);
    expect(count(), '1');
    planner.recordHttpResponse(statusCode: 200, parsedNonemptyBody: false);
    expect(count(), '2');
    planner.recordTransportFailure(const NativeLogin5HttpFailure(10));
    expect(count(), '2');
    planner.recordTransportFailure(const NativeLogin5HttpFailure(7));
    expect(count(), '3');
    planner.recordTransportFailure(StateError('other category'));
    expect(count(), '4');
    planner.recordHttpResponse(statusCode: 200, parsedNonemptyBody: true);
    expect(count(), '0');
  });
}
