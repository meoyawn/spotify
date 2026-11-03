import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/generated/spotify/client_token/v0/client_token_http.pb.dart' as backend;
import 'package:spotify_flutter/protocol/native_client_data.dart';
import 'package:spotify_flutter/protocol/native_client_token_provider.dart';
import 'package:spotify_flutter/protocol/native_http_credentials.dart';
import 'package:spotify_flutter/protocol/native_token_provider.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-http-credentials.json').readAsStringSync()) as Map;
  const data = NativeClientDataFactory(clientId: 'fixture', deviceId: 'fixture',
    facts: MacOSPlatformFacts(systemVersionString: 'fixture', majorVersion: 0,
      minorVersion: 0, patchVersion: 0, hardwareModel: 'fixture', cpuType: 0, cpuSubtype: 0));

  test('HTTP credential headers match original outgoing request captures', () async {
    for (final input in fixture['cases'] as List) {
      final scenario = input as Map;
      final access = NativeTokenProvider(operationFactory: _UnusedRefresh.new,
        nowMicroseconds: () => 0, nowNanoseconds: () => 0,
        // This is a seeded cached provider, matching the original oracle input.
        // Suppress its unrelated constructor background schedule.
        schedule: (_, __) => () {},
        initialToken: NativeAccessToken(accessToken: scenario['token'] as String? ?? 'synthetic+/= token',
          tokenType: scenario['token_type'] as String? ?? 'Bearer', expiresAtMicroseconds: 1000000));
      final client = NativeClientTokenProvider(clientData: data,
        nowMicroseconds: () => 0, encodeToken: (_) => '', onError: (error, stack) => Error.throwWithStackTrace(error, stack),
        sendOwned: (_) => throw StateError('Cached HTTP-field capture must not acquire a token'),
        initialToken: NativeClientToken(token: scenario['token'] as String? ?? 'synthetic+/= token',
          clientDataHash: nativeClientDataHash(data), expiresAtMicroseconds: 1000000,
          refreshAtMicroseconds: 1000000,
          domains: (scenario['domains'] as List?)?.cast<String>() ?? const ['spotify.com']));
      if (scenario['enabled'] != false) client.enable();
      try {
        final credentials = NativeHttpCredentials(accessTokens: access, clientTokens: client);
        final request = RequestEnvelope(method: 'POST', url: scenario['url'] as String,
          headers: (scenario['headers'] as Map?)?.cast<String, String>() ?? const {}, body: const [0, 128, 255],
          authorize: false, responseType: 'bytes');
        final result = scenario['kind'] == 'access'
          ? await credentials.withAccessToken(request) : await credentials.withClientToken(request);
        expect(result.headers, (scenario['result'] as Map)['headers'], reason: scenario['name'] as String);
        expect(result.url, request.url, reason: 'Signed URL spelling must survive decoration');
        expect(result.method, request.method);
        expect(result.body, request.body);
      } finally {
        access.close();
        client.close();
      }
    }
  });

  test('Native response chain matches original next outgoing credential fields', () async {
    final captured = jsonDecode(File('reverse-engineering/fixtures/native-http-response-credentials.json').readAsStringSync()) as Map;
    for (final input in captured['cases'] as List) {
      final scenario = input as Map;
      final original = scenario['chain'] as Map;
      final label = '$scenario';
      var selectedAccess = const NativeAccessToken(accessToken: 'cached-access',
        tokenType: 'Bearer', expiresAtMicroseconds: 1000000);
      final access = NativeTokenProvider(operationFactory: _UnusedRefresh.new,
        nowMicroseconds: () => 0, nowNanoseconds: () => 0,
        schedule: (_, __) => () {}, initialToken: selectedAccess);
      final client = NativeClientTokenProvider(clientData: data,
        nowMicroseconds: () => 0, encodeToken: (_) => '',
        onError: (error, stack) => Error.throwWithStackTrace(error, stack),
        sendOwned: (_) => NativeClientTokenOwnedSend(abort: () {},
          response: Future.value(http.Response.bytes(backend.ClientTokenResponse(
            grantedToken: backend.GrantedTokenResponse(token: 'replacement-client',
              expiresAfterSeconds: 3600, refreshAfterSeconds: 1800,
              domains: [backend.TokenDomain(domain: 'spotify.com')])).writeToBuffer(), 200))),
        initialToken: scenario['cached'] == false ? null : NativeClientToken(
          token: 'cached-client', clientDataHash: nativeClientDataHash(data),
          expiresAtMicroseconds: 1000000, refreshAtMicroseconds: 1000000,
          domains: (scenario['domains'] as List?)?.cast<String>() ?? const ['spotify.com']));
      if (scenario['enabled'] != false) client.enable();
      try {
        final credentials = NativeHttpCredentials(accessTokens: access, clientTokens: client,
          loadAccessToken: ({cancellationToken}) async => selectedAccess,
          invalidateAccessToken: () { selectedAccess = const NativeAccessToken(
            accessToken: 'replacement-access', tokenType: 'Bearer', expiresAtMicroseconds: 1000000); });
        String outcome;
        try {
          outcome = credentials.handleResponse(
            url: scenario['url'] as String? ?? 'https://spclient.wg.spotify.com/synthetic',
            statusCode: scenario['status'] as int,
            headers: (scenario['headers'] as Map?)?.cast<String, String>() ?? const {})
            ? 'forward' : 'no-callback';
        } on NativeClientTokenFailure catch (error) {
          expect(error.code, 1, reason: label);
          outcome = 'error';
        }
        expect(outcome, original['outcome'], reason: label);
        final request = RequestEnvelope(method: 'POST',
          url: 'https://spclient.wg.spotify.com/synthetic?keep=%2f+%2F',
          headers: {}, body: [0, 128, 255], authorize: false, responseType: 'bytes');
        final blocked = original['nextRequestClientFailure'];
        if (blocked != null) {
          await expectLater(credentials.prepare(request), throwsA(isA<NativeClientTokenFailure>()
            .having((error) => error.code, 'native client failure', blocked)), reason: label);
        } else {
          final next = await credentials.prepare(request);
          expect(next.headers, original['nextRequestHeaders'], reason: label);
        }
      } finally { access.close(); client.close(); }
    }
  });
}

class _UnusedRefresh implements NativeTokenRefreshOperation {
  @override
  NativeTokenCancel start(void Function(NativeTokenRefreshResult) callback) =>
    throw StateError('Cached HTTP-field capture must not refresh a token');
  @override
  void stop() {}
}
