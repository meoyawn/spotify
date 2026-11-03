import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/generated/connect.pb.dart';
import 'package:spotify_flutter/protocol/native_cef_context.dart';
import 'package:spotify_flutter/protocol/native_cef_http3_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_connect_state_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';
import 'package:spotify_flutter/transport/quiche/client.dart';

// One outgoing protocol owner: actual original603-byte startup states and459-
// byte gzip uploads reach an independent local H3 peer through the real plan.
// Private captured input/expected bytes remain ignored and are never printed,
// including on comparison failure. No account or remote server is contacted.
void main() {
  test('Native Connect state PUT original headers and gzip reach the H3 peer', () async {
    final evidence = jsonDecode(File('reverse-engineering/evidence/native-connect-state-http.json')
      .readAsStringSync()) as Map;
    final profile = (evidence['profiles'] as List).singleWhere(
      (entry) => entry['profileId'] == 1) as Map;
    final captured = (profile['headers'] as Map).cast<String, String>();
    final bodies = <int, List<int>>{};
    final compressedBodies = <int, List<int>>{};
    for (final source in const [829, 836]) {
      final protobuf = File('.local/connect-state-evidence/source-$source-request.pb');
      final compressed = File('.local/connect-state-evidence/source-$source-request.gz');
      if (!protobuf.existsSync() || !compressed.existsSync()) {
        throw StateError('Independent private original Connect body capture is unavailable');
      }
      bodies[source] = protobuf.readAsBytesSync();
      compressedBodies[source] = compressed.readAsBytesSync();
    }
    final server = await Process.start('uv', ['run', '--project', 'tools/oracles',
      '--locked', '--no-sync', 'python', 'test/support/http3_loopback_server.py']);
    addTearDown(() async { server.kill(); await server.exitCode; });
    server.stderr.drain<void>();
    final line = await server.stdout.transform(utf8.decoder)
      .transform(const LineSplitter()).first.timeout(const Duration(seconds: 15));
    final peer = jsonDecode(line) as Map;
    final authority = 'localhost:${peer['port']}';
    final origin = 'https://$authority';
    final transport = QuicheHttp3Client(
      libraryPath: File('.local/native/libquiche.dylib').absolute.path,
      trustedCertificatesPath: peer['certificate'] as String);
    addTearDown(transport.close);
    final sender = NativeCefHttp3Transport(client: transport,
      defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
      options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
      context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']));
    addTearDown(sender.close);
    final connectionId = 'synthetic-${List.filled(190, '0').join()}';
    const credentials = {'authorization': 'Bearer synthetic-local-capture-token',
      'client-token': 'synthetic-local-client-token'};
    final inherited = {for (final name in const ['accept-language', 'app-platform',
      'spotify-app-version', 'time-zone', 'user-agent', 'authorization', 'client-token'])
        name: credentials[name] ?? captured[name]!};

    final paths = jsonDecode(File('reverse-engineering/evidence/native-connect-state-paths.json')
      .readAsStringSync()) as Map;
    for (final entry in paths['cases'] as List) {
      final identity = entry['deviceId'] as String;
      if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(identity)) continue;
      final plan = NativeConnectStatePutRequestPlan(origin: origin, deviceId: identity,
        request: PutStateRequest(), template: RequestEnvelope(method: 'GET',
          url: origin, headers: inherited));
      expect(plan.request.url == '$origin/${entry['relativePath']}', isTrue,
        reason: 'Independently executed native unreserved/UUID device path');
    }

    for (final source in const [829, 836]) {
      final state = PutStateRequest.fromBuffer(bodies[source]!);
      final deviceId = state.device.deviceInfo.deviceId;
      final plan = NativeConnectStatePutRequestPlan(origin: origin, deviceId: deviceId,
        request: state, connectionId: connectionId,
        template: RequestEnvelope(method: 'GET', url: origin, headers: inherited,
          responseType: 'bytes'));
      // Boolean checks avoid exposing original device/state bytes in failures.
      expect(_equal(plan.protobufBody, bodies[source]!), isTrue,
        reason: 'Original source$source protobuf request bytes');
      expect(_equal(plan.request.body, compressedBodies[source]!), isTrue,
        reason: 'Original source$source gzip bytes');
      expect(plan.request.nativeTimeoutMilliseconds, 3000);
      final response = await sender.send(plan.request);
      expect(response.statusCode, 200);
      final received = jsonDecode(response.body) as Map;
      final pairs = received['headers'] as List;
      final expected = <String, String>{for (final entry in captured.entries)
        entry.key: switch (entry.key) {
          ':authority' => authority,
          ':path' => '/connect-state/v1/devices/$deviceId',
          'origin' => origin,
          'authorization' || 'client-token' => credentials[entry.key]!,
          'x-spotify-connection-id' => connectionId,
          _ => entry.value,
        }};
      expect([for (final pair in pairs) pair[0]], expected.keys.toList(),
        reason: 'Original source$source ordered decoded H3 header names');
      final actual = {for (final pair in pairs) pair[0] as String: pair[1] as String};
      expect({for (final entry in expected.entries) entry.key: actual[entry.key] == entry.value},
        {for (final key in expected.keys) key: true},
        reason: 'Original source$source decoded H3 values, without printing private fields');
      expect(received['bodyBase64'] == base64Encode(compressedBodies[source]!), isTrue,
        reason: 'Original source$source complete outgoing gzip upload');
      expect(received['protocol'], 'h3');
    }
  });
}

bool _equal(List<int> first, List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
