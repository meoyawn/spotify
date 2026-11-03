import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/native_oauth.dart';
import 'package:spotify_flutter/protocol/native_accounts_authorization.dart';
import 'package:spotify_flutter/protocol/native_desktop_accounts.dart';
import 'package:spotify_flutter/protocol/native_accounts_callback_server.dart';
import 'package:spotify_flutter/protocol/dpop_key.dart';
import 'package:spotify_flutter/protocol/dpop_proof.dart';
import 'package:spotify_flutter/protocol/native_oauth_exchange.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  // The real HTTP request-target boundary can normalize bytes before the
  // already checked redirect/form owners see them. Expected code bytes are
  // taken from original execution, independently of the socket observer.
  test('Browser HTTP callback preserves original outgoing authorization-code bytes', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-desktop-accounts.json').readAsStringSync()) as Map;
    final row = (fixture['callbackCases'] as List).firstWhere((row) =>
      (row['url'] as String).contains('raw+code')) as Map;
    final expected = (row['original'] as Map)['body'] as String;
    final expectedCode = expected.split('&').singleWhere((field) => field.startsWith('code='));
    final originalUrl = row['url'] as String;
    final server = await NativeAccountsCallbackServer.open();
    final captured = <RequestEnvelope>[];
    final login = NativeDesktopAccountsLogin(nowMicroseconds: () => 0,
      proofs: DpopProofGenerator(key: P256DpopKey.generate()), send: (request) async {
        captured.add(request);
        return http.Response(jsonEncode({'access_token': 'synthetic-access', 'token_type': 'DPoP',
          'refresh_token': 'synthetic-refresh', 'username': 'synthetic-user', 'expires_in': 3600}), 200);
      });
    try {
      await server.authenticate(login: login, openBrowser: (_) async {
        final port = Uri.parse(server.redirectUri).port;
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        final response = socket.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
        final target = '/login${originalUrl.substring(originalUrl.indexOf('?'))}';
        socket.add(ascii.encode('GET $target HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n\r\n'));
        await socket.flush();
        await response;
        socket.destroy();
      }).timeout(const Duration(seconds: 10));
      expect(captured, hasLength(1));
      expect(captured.single.method, 'POST');
      expect(captured.single.url, 'https://accounts.spotify.com/api/token');
      expect(captured.single.headers['Content-Type'], 'application/x-www-form-urlencoded');
      expect(ascii.decode(captured.single.body).split('&').singleWhere((field) => field.startsWith('code=')), expectedCode);
    } finally { await server.close(); }
  });

  // Primary desktop owner, distinct from consent mode below. Original native
  // execution supplies all expected URLs, including native identity/scopes,
  // PKCE, nested queries and conditional campaign/context members. This owns
  // outgoing query correctness and needs no test-only production API.
  test('Primary desktop Accounts URL matches original identity PKCE and outgoing query bytes', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-desktop-accounts.json').readAsStringSync()) as Map;
    final cases = fixture['cases'] as List;
    for (var i = 0; i < cases.length; i++) {
      final row = cases[i] as Map, original = row['original'] as Map;
      var clockReads = 0;
      int clock() { clockReads++; return row['nowSeconds'] as int; }
      final owner = i == 0 ? NativeDesktopAccountsAuthorization(nowSeconds: clock) :
        NativeDesktopAccountsAuthorization(clientId: row['clientId'] as String,
          scopes: (row['scopes'] as List).cast<String>(), nowSeconds: clock);
      final hex = row['entropyHex'] as String;
      final pkce = NativeAccountsPkce.fromEntropy([
        for (var offset = 0; offset < hex.length; offset += 2)
          int.parse(hex.substring(offset, offset + 2), radix: 16),
      ]);
      expect(owner.url(pkce: pkce, redirectUri: row['redirectUri'] as String,
        dpopThumbprint: row['dpopThumbprint'] as String, flow: row['flow'] as String,
        signUp: row['signUp'] as bool, flowContext: row['flowContext'] as String,
        campaign: NativeAccountsCampaign(source: row['source'] as String,
          medium: row['medium'] as String, campaign: row['campaign'] as String,
          referral: row['referral'] as String, msclkid: row['msclkid'] as String?)),
        original['url'], reason: row['name'] as String);
      // The verifier is subsequently sent in the token exchange body; checking
      // the original producer here binds that body input to this URL's challenge.
      expect(pkce.verifier, (original['pkce'] as Map)['verifier'], reason: row['name'] as String);
      expect(clockReads, original['timeReads'], reason: row['name'] as String);
    }
  });

  // The callback's first-raw-member rule is separate from form encoding. A
  // normal Uri query decoder would change the actual token POST bytes even
  // though the existing standalone form-encoder checks still passed.
  test('Accounts callback produces original token POST body without decoding raw code', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-desktop-accounts.json').readAsStringSync()) as Map;
    for (final row in fixture['callbackCases'] as List) {
      final expected = row['original'] as Map;
      final requests = <RequestEnvelope>[];
      final exchange = NativeOAuthExchange(nowMicroseconds: () => 0,
        proof: ({required method, required url, required nonce}) async => 'synthetic-proof',
        send: (request) async {
          requests.add(request);
          return http.Response(jsonEncode({'access_token': 'synthetic-access', 'token_type': 'DPoP',
            'refresh_token': 'synthetic-refresh', 'username': 'synthetic-user', 'expires_in': 3600}), 200);
        });
      final redirect = NativeAccountsRedirectExchange(exchange: exchange,
        pkce: NativeAccountsPkce.fromEntropy(List.generate(32, (index) => index)),
        redirectUri: 'http://127.0.0.1:4381/login');
      if (expected.containsKey('errorCode')) {
        await expectLater(redirect.complete(row['url'] as String),
          throwsA(isA<NativeAccountsRedirectFailure>().having((error) => error.code, 'code', expected['errorCode'])));
        expect(requests, isEmpty, reason: row['url'] as String);
      } else {
        await redirect.complete(row['url'] as String);
        expect(requests, hasLength(1), reason: row['url'] as String);
        final request = requests.single;
        expect(request.method, 'POST');
        expect(request.url, 'https://accounts.spotify.com/api/token');
        expect(request.headers, {'Content-Type': 'application/x-www-form-urlencoded', 'dpop': 'synthetic-proof'});
        expect(request.body, ascii.encode(expected['body'] as String), reason: row['url'] as String);
      }
    }
  });

  test('Accounts consent URL matches the original outgoing authorization query', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-accounts-authorization.json').readAsStringSync()) as Map;
    for (final row in fixture['cases'] as List) {
      final owner = NativeAccountsAuthorization(clientId: row['clientId'] as String,
        scope: row['scope'] as String, codeChallenge: row['codeChallenge'] as String,
        redirectUri: row['redirectUri'] as String);
      expect(owner.consentUrl(idTokenHint: row['idTokenHint'] as String), row['url'],
        reason: row['name'] as String);
    }
  });

  group('Original native OAuth form contract', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-form.json')
      .readAsStringSync()) as Map<String, dynamic>;
    for (final scenario in fixture['cases'] as List) {
      if (scenario['name'] == 'authorization code') continue;
      test(scenario['name'] as String, () {
        expect(encodeNativeForm((scenario['fields'] as Map).cast<String, String>()),
          scenario['body']);
      });
    }

    test('Authorization-code builder uses native endpoint, headers, and body', () {
      final scenario = (fixture['cases'] as List)
        .singleWhere((item) => item['name'] == 'authorization code');
      final fields = (scenario['fields'] as Map).cast<String, String>();
      final request = nativeAuthorizationCodeRequest(
        clientId: fields['client_id']!, code: fields['code']!,
        codeVerifier: fields['code_verifier']!, redirectUri: fields['redirect_uri']!,
        dpopProof: 'synthetic-proof', nativeHeaders: {'User-Agent': 'synthetic-native-identity'});
      expect(request.url, 'https://accounts.spotify.com/api/token');
      expect(request.method, 'POST');
      expect(request.headers, {'User-Agent': 'synthetic-native-identity',
        'Content-Type': 'application/x-www-form-urlencoded', 'dpop': 'synthetic-proof'});
      expect(request.body, utf8.encode(scenario['body'] as String));
    });
  });
}
