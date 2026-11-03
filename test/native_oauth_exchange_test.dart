import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/native_oauth_exchange.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

const _tokens = <String, Object?>{'access_token': 'access-fixture', 'expires_in': 3600,
  'token_type': 'DPoP', 'refresh_token': 'refresh-fixture', 'username': 'fixture-user'};

Future<String?> _proof({required String method, required String url, required String? nonce}) async =>
  'proof-fixture';

void main() {
  final formFixture = jsonDecode(File('reverse-engineering/fixtures/native-form.json').readAsStringSync()) as Map;
  final form = (formFixture['cases'] as List).singleWhere((item) => item['name'] == 'authorization code');
  final fields = (form['fields'] as Map).cast<String, String>();
  Future<NativeOAuthTokenResponse> acquire(NativeOAuthExchange exchange,
      {Map<String, String> nativeHeaders = const {}}) => exchange.exchangeAuthorizationCode(
    clientId: fields['client_id']!, code: fields['code']!, codeVerifier: fields['code_verifier']!,
    redirectUri: fields['redirect_uri']!, nativeHeaders: nativeHeaders);
  NativeOAuthExchange exchange(NativeOAuthSend send, {NativeOAuthProof proof = _proof,
      int Function()? nowMicroseconds}) => NativeOAuthExchange(send: send, proof: proof,
    nowMicroseconds: nowMicroseconds ?? () => 123456789);

  test('Native HTTP status mapping is preserved without generic retries', () async {
    for (final (status, code) in [(400, 108), (401, 107), (403, 105), (408, 109),
      (429, 110), (504, 109), (201, 106), (302, 106), (500, 106), (503, 106)]) {
      var sent = 0;
      final service = exchange((_) async {
        sent++;
        return http.Response('{"error":"use_dpop_nonce"}', status,
          headers: status == 400 ? {} : {'dpop-nonce': 'fixture-challenge'});
      });
      await expectLater(acquire(service), throwsA(isA<NativeOAuthFailure>()
        .having((error) => error.code, 'native error', code)
        .having((error) => error.httpStatus, 'HTTP status', status)), reason: '$status');
      expect(sent, 1, reason: '$status');
    }
  });

  test('A nonce challenge regenerates only the proof and resends the saved form bytes', () async {
    for (final nonce in ['', 'nonce+/=~-fixture']) {
      final proofKey = nonce.isEmpty ? 'dpop' : 'DPOP';
      final contentTypeKey = nonce.isEmpty ? 'Content-Type' : 'content-type';
      final events = <String>[];
      final requests = <RequestEnvelope>[];
      final service = exchange((request) async {
        events.add('send:${request.headers[proofKey]}');
        requests.add(request);
        return requests.length == 1 ? http.Response('{"error":"use_dpop_nonce"}', 400,
          headers: {'DPoP-Nonce': nonce}) : http.Response(jsonEncode(_tokens), 200);
      }, proof: ({required String method, required String url, required String? nonce}) async {
        expect(method, 'POST');
        expect(url, 'https://accounts.spotify.com/api/token');
        events.add(nonce == null ? 'initial proof' : 'nonce proof:$nonce');
        return nonce == null ? 'first-proof' : 'replacement-proof';
      });
      final result = await acquire(service, nativeHeaders: {
        'User-Agent': 'supplied-native-identity',
        if (nonce.isNotEmpty) 'DPOP': 'inherited proof',
        if (nonce.isNotEmpty) 'content-type': 'inherited type',
      });
      expect(events, ['initial proof', 'send:${nonce.isEmpty ? 'first-proof' : 'inherited proof'}',
        'nonce proof:$nonce', 'send:${nonce.isEmpty ? 'replacement-proof' : 'inherited proof'}']);
      expect(result.accessToken, 'access-fixture');
      for (final request in requests) {
        expect(request.method, 'POST');
        expect(request.url, 'https://accounts.spotify.com/api/token');
        expect(request.authorize, isFalse);
        expect(request.nativeTimeoutMilliseconds, 30000);
        expect(request.headers[contentTypeKey], 'application/x-www-form-urlencoded');
        expect(request.headers['User-Agent'], 'supplied-native-identity');
        expect(request.body, utf8.encode(form['body'] as String));
      }
    }
  });

  test('A second nonce challenge is returned as native 108 without a third proof or send', () async {
    var sent = 0;
    final nonces = <String?>[];
    final service = exchange((_) async => http.Response('{"error":"use_dpop_nonce"}', 400,
      headers: {'dpop-nonce': 'nonce-${++sent}'}),
      proof: ({required String method, required String url, required String? nonce}) async {
        nonces.add(nonce);
        return 'proof-fixture';
      });
    await expectLater(acquire(service), throwsA(isA<NativeOAuthFailure>()
      .having((error) => error.code, 'native error', 108)));
    expect(sent, 2);
    expect(nonces, [null, 'nonce-1']);
  });

  test('Malformed and nonmatching error documents do not activate nonce retry', () async {
    for (final body in ['{', '[]', '{}', '{"error":null}', '{"error":123}',
      '{"error":"Use_dpop_nonce"}', '{"error":"use_dpop_nonce "}']) {
      var sent = 0;
      final service = exchange((_) async {
        sent++;
        return http.Response(body, 400, headers: {'dpop-nonce': 'fixture-nonce'});
      });
      await expectLater(acquire(service), throwsA(isA<NativeOAuthFailure>()
        .having((error) => error.code, 'native error', 108)), reason: body);
      expect(sent, 1, reason: body);
    }
  });

  test('Access denied maps to native 15 on HTTP 400 before or after the nonce retry', () async {
    for (final retryFirst in [false, true]) {
      var sent = 0;
      final service = exchange((_) async {
        if (++sent == 1 && retryFirst) {
          return http.Response('{"error":"use_dpop_nonce"}', 400,
            headers: {'dpop-nonce': 'fixture-nonce'});
        }
        return http.Response('{"error":"access_denied"}', 400);
      });
      await expectLater(acquire(service), throwsA(isA<NativeOAuthFailure>()
        .having((error) => error.code, 'native error', 15)
        .having((error) => error.reason, 'reason', NativeOAuthFailureReason.accessDenied)));
      expect(sent, retryFirst ? 2 : 1);
    }
    await expectLater(acquire(exchange((_) async => http.Response('{"error":"access_denied"}', 401))),
      throwsA(isA<NativeOAuthFailure>().having((error) => error.code, 'native error', 107)));
  });

  test('Missing or failed proofs prevent the initial or repeated send with native 104', () async {
    for (final failOnRetry in [false, true]) {
      for (final throws in [false, true]) {
        var sent = 0;
        var proofs = 0;
        final service = exchange((_) async {
          sent++;
          return http.Response('{"error":"use_dpop_nonce"}', 400,
            headers: {'dpop-nonce': 'fixture-nonce'});
        }, proof: ({required String method, required String url, required String? nonce}) async {
          if (++proofs == 1 && failOnRetry) return 'initial-proof';
          if (throws) throw StateError('synthetic signer failure');
          return null;
        });
        await expectLater(acquire(service), throwsA(isA<NativeOAuthFailure>()
          .having((error) => error.code, 'native error', 104)
          .having((error) => error.reason, 'reason', NativeOAuthFailureReason.proofUnavailable)));
        expect(sent, failOnRetry ? 1 : 0);
        expect(proofs, failOnRetry ? 2 : 1);
      }
    }
  });

  test('A present empty proof is not confused with provider failure', () async {
    String? observed;
    final service = exchange((request) async {
      observed = request.headers['dpop'];
      return http.Response(jsonEncode(_tokens), 200);
    }, proof: ({required String method, required String url, required String? nonce}) async => '');
    await acquire(service);
    expect(observed, '');
  });

  test('Sender failure propagates without an invented native transport code or retry', () async {
    final failure = StateError('synthetic sender failure');
    var sent = 0;
    final service = exchange((_) async { sent++; throw failure; });
    await expectLater(acquire(service), throwsA(same(failure)));
    expect(sent, 1);
  });

  test('Success preserves optional string presence and uses the injected microsecond clock', () async {
    for (final populated in [false, true]) {
      var clocks = 0;
      final body = {..._tokens, if (populated) ...{'scope': 'streaming fixture',
        'id_token': '', 'issued_token_type': 'urn:fixture:token'}};
      final service = exchange((_) async => http.Response(jsonEncode(body), 200),
        nowMicroseconds: () { clocks++; return 123456789; });
      final response = await acquire(service);
      expect(response.accessToken, 'access-fixture');
      expect(response.tokenType, 'DPoP');
      expect(response.refreshToken, 'refresh-fixture');
      expect(response.username, 'fixture-user');
      expect(response.scope, populated ? 'streaming fixture' : '');
      expect(response.idToken, populated ? '' : isNull);
      expect(response.issuedTokenType, populated ? 'urn:fixture:token' : isNull);
      expect(response.expiresIn, 3600);
      expect(response.expiresAtMicroseconds, 3723456789);
      expect(clocks, 1);
    }
    final empty = await acquire(exchange((_) async => http.Response(jsonEncode({
      'access_token': '', 'token_type': '', 'refresh_token': '', 'username': '', 'expires_in': 0}), 200)));
    expect(empty.username, '');
    expect(empty.accessToken, '');
  });

  test('Success schema rejects missing required fields and present nonstring values', () async {
    for (final field in ['access_token', 'token_type', 'refresh_token', 'username', 'expires_in']) {
      for (final omit in [true, false]) {
        final body = Map<String, Object?>.from(_tokens);
        if (omit) { body.remove(field); } else { body[field] = null; }
        var clocks = 0;
        await expectLater(acquire(exchange((_) async => http.Response(jsonEncode(body), 200),
          nowMicroseconds: () { clocks++; return 0; })), throwsA(isA<FormatException>()), reason: field);
        expect(clocks, 0);
      }
    }
    for (final (field, invalid) in [('access_token', <Object?>[]), ('token_type', false),
      ('refresh_token', <String, Object?>{}), ('username', 5), ('expires_in', '3600'),
      ('expires_in', true), ('scope', null), ('id_token', null), ('issued_token_type', null)]) {
      final body = {..._tokens, field: invalid};
      await expectLater(acquire(exchange((_) async => http.Response(jsonEncode(body), 200))),
        throwsA(isA<FormatException>()), reason: field);
    }
    for (final body in ['', '[]', 'null', '{} trailing']) {
      await expectLater(acquire(exchange((_) async => http.Response(body, 200))),
        throwsA(isA<FormatException>()));
    }
  });

  test('Original native numeric reader vectors match through the full exchange boundary', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-oauth-response.json').readAsStringSync()) as Map;
    for (final scenario in fixture['numericCases'] as List) {
      final token = scenario['token'] as String;
      final body = jsonEncode(_tokens).replaceFirst('"expires_in":3600', '"expires_in":$token');
      final result = acquire(exchange((_) async => http.Response(body, 200)));
      if (scenario.containsKey('error')) {
        await expectLater(result, throwsA(isA<FormatException>()), reason: token);
      } else {
        final response = await result;
        expect(response.expiresIn, scenario['value'], reason: token);
        expect(response.expiresAtMicroseconds, 123456789 + (scenario['value'] as int) * 1000000,
          reason: token);
      }
    }
  });

  test('Numeric token extraction respects escaped keys and string content', () async {
    final body = jsonEncode({..._tokens, 'access_token': 'literal "expires_in":99999'})
      .replaceFirst('"expires_in":3600', r'"expires\u005fin":2147483647.999999999999999999');
    final result = await acquire(exchange((_) async => http.Response(body, 200)));
    expect(result.expiresIn, 2147483647);
    expect(result.accessToken, 'literal "expires_in":99999');
  });
}
