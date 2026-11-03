import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/generated/spotify/client_token/v0/client_token_http.pb.dart' as backend;
import 'package:spotify_flutter/protocol/native_client_data.dart';
import 'package:spotify_flutter/protocol/native_client_token_codec.dart';
import 'package:spotify_flutter/protocol/native_client_token_provider.dart';

NativeClientToken _token(Map fields, String hash) => NativeClientToken(token: fields['token'] as String,
  expiresAtMicroseconds: fields['expiresAtMicroseconds'] as int,
  refreshAtMicroseconds: fields['refreshAtMicroseconds'] as int, clientDataHash: hash,
  domains: (fields['domains'] as List).cast<String>());

void _expectFields(NativeClientToken token, Map fields, String hash) {
  expect(token.token, fields['token']);
  expect(token.expiresAtMicroseconds, fields['expiresAtMicroseconds']);
  expect(token.refreshAtMicroseconds, fields['refreshAtMicroseconds']);
  expect(token.clientDataHash, hash);
  expect(token.domains, fields['domains']);
}

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-client-token-codec.json').readAsStringSync()) as Map;

  test('Stored token bytes and both codec directions match original framing and captured native assignments', () {
    for (final scenario in fixture['storageCases'] as List) {
      final fields = scenario['fields'] as Map;
      final hash = scenario['clientDataHash'] as String;
      final codec = NativeClientTokenCodec(random: _FixedIv(scenario['ivHex'] as String));
      expect(codec.encode(_token(fields, hash)), scenario['encoded']);
      final decoded = codec.decode(scenario['encoded'] as String, clientDataHash: hash);
      expect(decoded, isNotNull);
      _expectFields(decoded!, fields, hash);
    }
  });

  test('Seed decoding retains native padding/authentication and standard proto3 rejection behavior', () {
    final codec = NativeClientTokenCodec();
    for (final scenario in fixture['decodeCases'] as List) {
      final decoded = codec.decode(scenario['encoded'] as String,
        clientDataHash: scenario['clientDataHash'] as String);
      expect(decoded != null, scenario['accepted'], reason: scenario['name'] as String);
      if (decoded != null && scenario['fields'] != null) {
        _expectFields(decoded, scenario['fields'] as Map, scenario['clientDataHash'] as String);
      }
    }
  });

  test('The production codec publishes and restores native provider state without reacquisition', () async {
    final expected = (fixture['storageCases'] as List)[1] as Map;
    final inputs = jsonDecode(File('reverse-engineering/fixtures/native-client-token-provider.json').readAsStringSync()) as Map;
    final config = (inputs['hashCases'] as List)[1] as Map;
    final codec = NativeClientTokenCodec(random: _FixedIv(expected['ivHex'] as String));
    final clientData = NativeClientDataFactory(
      clientId: config['clientId'] as String, clientVersion: config['clientVersion'] as String,
      deviceId: config['deviceId'] as String, developerApiKey: config['developerApiKey'] as String?,
      facts: MacOSPlatformFacts(systemVersionString: config['systemVersionString'] as String,
        majorVersion: config['majorVersion'] as int, minorVersion: config['minorVersion'] as int,
        patchVersion: config['patchVersion'] as int, hardwareModel: config['hardwareModel'] as String,
        cpuType: config['cpuType'] as int, cpuSubtype: config['cpuSubtype'] as int));
    final provider = NativeClientTokenProvider(clientData: clientData,
      nowMicroseconds: () => 199, encodeToken: codec.encode,
      onError: (error, stack) => fail('Unexpected acquisition/codec failure: $error'),
      sendOwned: (_) => NativeClientTokenOwnedSend(response: Future.value(http.Response.bytes(
        backend.ClientTokenResponse(grantedToken: backend.GrantedTokenResponse(token: 'synthetic-token',
          expiresAfterSeconds: 3600, refreshAfterSeconds: 1800,
          domains: [backend.TokenDomain(domain: 'spotify.com'), backend.TokenDomain(domain: 'api.fixture.invalid')]))
          .writeToBuffer(), 200)), abort: () => fail('A completed send was aborted')));
    addTearDown(provider.close);
    final published = Completer<String>();
    provider.observeEncryptedTokens(published.complete);
    provider.enable();
    final acquired = Completer<NativeClientTokenResult>();
    provider.acquire(acquired.complete);
    expect(await acquired.future, isA<NativeClientTokenSuccess>());
    final encoded = await published.future;
    expect(encoded, expected['encoded']);
    final hash = nativeClientDataHash(clientData);
    final seed = codec.decode(encoded, clientDataHash: hash);
    expect(seed, isNotNull);
    final restored = NativeClientTokenProvider(clientData: clientData, initialToken: seed,
      nowMicroseconds: () => 199, encodeToken: codec.encode,
      onError: (error, stack) => fail('Unexpected seed restoration failure: $error'),
      sendOwned: (_) => fail('A current decoded seed initiated an HTTP acquisition'));
    addTearDown(restored.close);
    restored.enable();
    final cached = Completer<NativeClientTokenResult>();
    restored.acquire(cached.complete);
    final result = await cached.future;
    expect(result, isA<NativeClientTokenSuccess>());
    _expectFields((result as NativeClientTokenSuccess).token, expected['fields'] as Map, hash);
  });
}

class _FixedIv implements Random {
  _FixedIv(String hex) : bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  final List<int> bytes;
  int offset = 0;
  @override
  int nextInt(int max) => bytes[offset++] % max;
  @override
  bool nextBool() => throw UnsupportedError('Fixture supplies IV bytes');
  @override
  double nextDouble() => throw UnsupportedError('Fixture supplies IV bytes');
}
