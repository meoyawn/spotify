import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_cef_context.dart';
import 'package:spotify_flutter/protocol/native_cef_http2_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_client_data.dart';
import 'package:spotify_flutter/protocol/native_client_token_provider.dart';
import 'package:spotify_flutter/protocol/native_http_credentials.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';
import 'package:spotify_flutter/protocol/native_login5_request.dart';
import 'package:spotify_flutter/protocol/native_token_provider.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('PREAUTH Login5 H2 fields and body match original without recursive Authorization', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-login5-preauth-headers.json').readAsStringSync()) as Map;
    final native = fixture['cefNativeOptions'] as Map;
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/native_cef_h2_peer.py']);
    final stderr = peer.stderr.drain<void>();
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    NativeCefHttp2Transport? sender;
    final access = NativeTokenProvider(operationFactory: _NoPreauthAccessRefresh.new,
      nowMicroseconds: () => 0, nowNanoseconds: () => 0, schedule: (_, __) => () {});
    const data = NativeClientDataFactory(clientId: 'synthetic-client', deviceId: 'synthetic-device',
      facts: MacOSPlatformFacts(systemVersionString: 'synthetic', majorVersion: 0,
        minorVersion: 0, patchVersion: 0, hardwareModel: 'synthetic', cpuType: 0, cpuSubtype: 0));
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map;
      final authority = 'localhost:${ready['port']}';
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ready['certificate'] as String);
      sender = NativeCefHttp2Transport(defaults: NativeHttpDefaults(userAgent: fixture['userAgent'] as String),
        options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
        context: NativeCefContext.fromLocale(selectedLocale: native['selectedLocale'] as String,
          appleLanguages: (native['suppliedAppleLanguages'] as List).cast<String>()), securityContext: trust);
      for (final value in fixture['cases'] as List) {
        final row = value as Map, credential = row['credential'] as Map;
        final client = NativeClientTokenProvider(clientData: data, nowMicroseconds: () => 0,
          encodeToken: (_) => '', onError: Error.throwWithStackTrace,
          sendOwned: (_) => throw StateError('Cached original field comparison cannot acquire a token'),
          initialToken: NativeClientToken(token: row['clientToken'] as String,
            clientDataHash: nativeClientDataHash(data), expiresAtMicroseconds: 1000000,
            refreshAtMicroseconds: 1000000, domains: (row['clientTokenDomains'] as List).cast<String>()));
        if (row['clientTokenEnabled'] == true) client.enable();
        try {
          final plan = NativeLogin5RequestPlanner(counter:
            NativeLogin5RetryCounter(monotonicNowNanoseconds: () => 0)).credentialsV3(
              NativeLogin5Credentials(clientId: row['clientId'] as String, deviceId: row['deviceId'] as String),
              NativeLogin5StoredCredential(username: credential['id'] as String,
                data: hex.decode(credential['secretHex'] as String)));
          final credentials = NativeHttpCredentials(accessTokens: access, clientTokens: client,
            loadAccessToken: ({cancellationToken}) async => throw StateError('PREAUTH Login5 cannot request its own bearer token'));
          // Decorate the actual original authority first. Only the independently
          // supplied local peer authority/Origin replaces it at the send boundary.
          final original = await credentials.withClientToken(plan.request);
          final response = await sender.send(RequestEnvelope(method: original.method,
            url: 'https://$authority/v3/login', headers: original.headers, body: original.body,
            authorize: original.authorize, responseType: original.responseType,
            nativeTimeoutMilliseconds: original.nativeTimeoutMilliseconds));
          expect(response.statusCode, 200);
          expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
          final actual = (jsonDecode(output.current) as Map)['capture'] as Map;
          final pairs = actual['headers'] as List;
          final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
          expect(fields.length, pairs.length);
          expect(fields, {...(row['expectedHttp2Headers'] as Map),
            ':authority': authority, 'origin': 'https://$authority'}, reason: row['name'] as String);
          expect(actual['bodyBase64'], base64Encode(hex.decode(row['bodyHex'] as String)));
          expect(actual['alpn'], 'h2');
        } finally { client.close(); }
      }
    } finally {
      sender?.close();
      access.close();
      await output.cancel();
      peer.kill();
      await peer.exitCode;
      await stderr;
    }
  });
}

class _NoPreauthAccessRefresh implements NativeTokenRefreshOperation {
  @override
  NativeTokenCancel start(void Function(NativeTokenRefreshResult) callback) =>
    throw StateError('PREAUTH Login5 cannot refresh an access token');
  @override
  void stop() {}
}
