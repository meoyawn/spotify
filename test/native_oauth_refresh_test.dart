import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/native_oauth_exchange.dart';
import 'package:spotify_flutter/protocol/native_oauth_refresh.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

const _token = <String, Object?>{'access_token': 'refreshed-access',
  'token_type': 'Bearer', 'expires_in': 3600};

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-oauth-refresh.json').readAsStringSync()) as Map;
  final template = fixture['template'] as Map;
  NativeOAuthRefresh service(NativeOAuthSend send, {NativeOAuthRefreshState? state,
      NativeOAuthProof? proof, String clientId = 'client-fixture', int Function()? nowMicroseconds,
      Map<String, String> nativeHeaders = const {}}) => NativeOAuthRefresh(clientId: clientId,
    state: state ?? NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: 'stored-nonce'),
    send: send, proof: proof, nowMicroseconds: nowMicroseconds ?? () => 123456789,
    nativeHeaders: nativeHeaders);

  test('Refresh forms and application Content-Type match the native request constructor', () async {
    for (final scenario in fixture['formCases'] as List) {
      RequestEnvelope? observed;
      const headers = {'X-Fixture': 'native-default'};
      final provider = service((request) async {
        observed = request;
        return http.Response(jsonEncode(_token), 200);
      }, clientId: scenario['clientId'] as String,
        state: NativeOAuthRefreshState(refreshToken: scenario['refreshToken'] as String, dpopNonce: ''),
        nativeHeaders: headers);
      await provider.refresh();
      expect(observed!.url, template['url']);
      expect(observed!.method, template['method']);
      expect(observed!.authorize, isFalse);
      expect(observed!.nativeTimeoutMilliseconds, template['nativeTimeoutMilliseconds']);
      expect(observed!.headers, {...headers, ...(template['headers'] as Map).cast<String, String>()});
      expect(observed!.body, utf8.encode(scenario['body'] as String));
    }
  });

  test('Configured proof receives a present nonce including empty and is replaced on retry', () async {
    for (final challenge in ['', 'nonce+/=~-fixture']) {
      final state = NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: '');
      final calls = <String>[];
      var proofs = 0;
      var sends = 0;
      final provider = service((request) async {
        calls.add('send:${request.headers['dpop']}');
        return ++sends == 1 ? http.Response('{"error":"use_dpop_nonce"}', 400,
          headers: {'DPoP-Nonce': challenge}) : http.Response(jsonEncode(_token), 200);
      }, state: state, proof: ({required String method, required String url, required String? nonce}) async {
        expect(method, 'POST');
        expect(url, 'https://accounts.spotify.com/api/token');
        expect(nonce, isNotNull);
        calls.add('proof:$nonce');
        return 'proof-${++proofs}';
      });
      await provider.refresh();
      expect(calls, ['proof:', 'send:proof-1', 'proof:$challenge', 'send:proof-2']);
      expect(state.dpopNonce, challenge);
    }
  });

  test('Refresh proof headers retain the original bulk-insertion behavior', () async {
    final headerFixture = jsonDecode(File('reverse-engineering/fixtures/native-header-overrides.json').readAsStringSync()) as Map;
    for (final scenario in (headerFixture['cases'] as List).where((item) => item['insertions'] != null)) {
      final inherited = {for (final pair in scenario['headers'] as List) pair[0] as String: pair[1] as String};
      final expected = {for (final pair in scenario['result'] as List) pair[0] as String: pair[1] as String,
        'Content-Type': 'application/x-www-form-urlencoded'};
      final generated = (scenario['insertions'] as List).single[1] as String;
      var proofs = 0;
      Map<String, String>? observed;
      await service((request) async {
        observed = Map.of(request.headers);
        return http.Response(jsonEncode(_token), 200);
      }, nativeHeaders: inherited,
        proof: ({required String method, required String url, required String? nonce}) async {
          proofs++;
          return generated;
        }).refresh();
      expect(observed, expected, reason: scenario['name'] as String);
      expect(proofs, 1, reason: 'inherited proof does not bypass native proof generation');
    }
  });

  test('The nonce challenge path also preserves the native optional-provider mode', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: 'initial');
    var sent = 0;
    final provider = service((request) async {
      expect(request.headers, {'Content-Type': 'application/x-www-form-urlencoded'});
      return ++sent == 1 ? http.Response('{"error":"use_dpop_nonce"}', 400,
        headers: {'dpop-nonce': 'challenge'}) : http.Response(jsonEncode(_token), 200);
    }, state: state);
    await provider.refresh();
    expect(sent, 2);
    expect(state.dpopNonce, 'challenge');
  });

  test('Retry rereads the owned refresh token while each attempt snapshots before proof generation', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'first-refresh', dpopNonce: 'first-nonce');
    final requests = <RequestEnvelope>[];
    final nonces = <String?>[];
    final provider = service((request) async {
      requests.add(request);
      if (requests.length == 1) {
        state.refreshToken = 'replacement-refresh';
        return http.Response('{"error":"use_dpop_nonce"}', 400, headers: {'dpop-nonce': 'replacement-nonce'});
      }
      return http.Response(jsonEncode(_token), 200);
    }, state: state, proof: ({required String method, required String url, required String? nonce}) async {
      nonces.add(nonce);
      return 'proof-fixture';
    });
    await provider.refresh();
    expect(utf8.decode(requests[0].body),
      'client_id=client-fixture&grant_type=refresh_token&refresh_token=first-refresh');
    expect(utf8.decode(requests[1].body),
      'client_id=client-fixture&grant_type=refresh_token&refresh_token=replacement-refresh');
    expect(nonces, ['first-nonce', 'replacement-nonce']);

    final entered = Completer<void>();
    final signing = Completer<String?>();
    String? sent;
    final waiting = service((request) async {
      sent = utf8.decode(request.body);
      return http.Response(jsonEncode(_token), 200);
    }, state: state, proof: ({required String method, required String url, required String? nonce}) {
      entered.complete();
      return signing.future;
    }).refresh();
    await entered.future;
    state.refreshToken = 'later-refresh';
    signing.complete('proof-fixture');
    await waiting;
    expect(sent, 'client_id=client-fixture&grant_type=refresh_token&refresh_token=replacement-refresh');
    expect(state.refreshToken, 'later-refresh');
  });

  test('Exhaustion retains the latest nonce and the next operation gets its own retry budget', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: 'initial');
    var sent = 0;
    final nonces = <String?>[];
    final provider = service((_) async {
      if (++sent == 4) return http.Response(jsonEncode(_token), 200);
      return http.Response('{"error":"use_dpop_nonce"}', 400, headers: {'dpop-nonce': 'nonce-$sent'});
    }, state: state, proof: ({required String method, required String url, required String? nonce}) async {
      nonces.add(nonce);
      return 'proof-fixture';
    });
    await expectLater(provider.refresh(), throwsA(isA<NativeOAuthRefreshFailure>()
      .having((error) => error.code, 'native failure', 6)));
    expect(sent, 2);
    expect(state.dpopNonce, 'nonce-2');
    await provider.refresh();
    expect(sent, 4);
    expect(nonces, ['initial', 'nonce-1', 'nonce-2', 'nonce-3']);
    expect(state.dpopNonce, 'nonce-3');
  });

  test('Success rotates only a nonempty refresh token and persists nonce before reading the clock', () async {
    for (final rotation in <String?>[null, '', 'rotated-refresh', ' ']) {
      for (final nonce in <String?>[null, '', 'success-nonce']) {
        final state = NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: 'stored-nonce');
        var clocks = 0;
        final provider = service((_) async => http.Response(jsonEncode({
          ..._token, 'refresh_token': ?rotation}), 200,
          headers: nonce == null ? {} : {'dpop-nonce': nonce}), state: state,
          nowMicroseconds: () {
            clocks++;
            expect(state.refreshToken, rotation == null || rotation.isEmpty ? 'stored-refresh' : rotation);
            expect(state.dpopNonce, nonce ?? 'stored-nonce');
            return 123456789;
          });
        final result = await provider.refresh();
        expect(result.accessToken, 'refreshed-access');
        expect(result.tokenType, 'Bearer');
        expect(result.expiresIn, 3600);
        expect(result.expiresAtMicroseconds, 3723456789);
        expect(clocks, 1);
      }
    }
  });

  test('HTTP error mapping remains distinct from authorization-code errors and has no generic retry', () async {
    for (final (status, code) in [(503, 4), (401, 1), (403, 1), (408, 1),
      (429, 1), (500, 1), (504, 1), (302, 1)]) {
      var sent = 0;
      final provider = service((_) async {
        sent++;
        return http.Response('not JSON', status, headers: {'dpop-nonce': 'unused'});
      });
      await expectLater(provider.refresh(), throwsA(isA<NativeOAuthRefreshFailure>()
        .having((error) => error.code, 'native failure', code)
        .having((error) => error.httpStatus, 'HTTP status', status)));
      expect(sent, 1);
    }
    for (final (error, code) in [('invalid_grant', 2), ('access_denied', 2),
      ('invalid_dpop_proof', 7), ('invalid_client', 8), ('Invalid_client', 1),
      ('invalid_client_extra', 1), ('unknown', 1)]) {
      var sent = 0;
      final provider = service((_) async {
        sent++;
        return http.Response(jsonEncode({'error': error}), 400);
      });
      await expectLater(provider.refresh(), throwsA(isA<NativeOAuthRefreshFailure>()
        .having((error) => error.code, 'native failure', code)), reason: error);
      expect(sent, 1);
    }
  });

  test('A missing nonce is an ordinary failure and does not alter owned state', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: 'stored-nonce');
    var sent = 0;
    final provider = service((_) async {
      sent++;
      return http.Response('{"error":"use_dpop_nonce"}', 400);
    }, state: state);
    await expectLater(provider.refresh(), throwsA(isA<NativeOAuthRefreshFailure>()
      .having((error) => error.code, 'native failure', 1)));
    expect(sent, 1);
    expect(state.refreshToken, 'stored-refresh');
    expect(state.dpopNonce, 'stored-nonce');
  });

  test('Configured proof failure prevents send and leaves an already committed challenge nonce intact', () async {
    for (final retryFirst in [false, true]) {
      for (final throws in [false, true]) {
        final state = NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: 'stored-nonce');
        var sent = 0;
        var proofs = 0;
        final provider = service((_) async {
          sent++;
          return http.Response('{"error":"use_dpop_nonce"}', 400, headers: {'dpop-nonce': 'challenge'});
        }, state: state, proof: ({required String method, required String url, required String? nonce}) async {
          if (++proofs == 1 && retryFirst) return 'initial-proof';
          if (throws) throw StateError('synthetic signer failure');
          return null;
        });
        await expectLater(provider.refresh(), throwsA(isA<NativeOAuthRefreshFailure>()
          .having((error) => error.code, 'native failure', 7)));
        expect(sent, retryFirst ? 1 : 0);
        expect(proofs, retryFirst ? 2 : 1);
        expect(state.dpopNonce, retryFirst ? 'challenge' : 'stored-nonce');
      }
    }
    RequestEnvelope? observed;
    await service((request) async {
      observed = request;
      return http.Response(jsonEncode(_token), 200);
    }, proof: ({required String method, required String url, required String? nonce}) async => '').refresh();
    expect(observed!.headers['dpop'], '');
  });

  test('Only explicit native HTTP aborted identity maps to refresh failure 5', () async {
    for (final (failure, code) in <(Object, int)>[(const NativeOAuthRefreshHttpError(10), 5),
      (const NativeOAuthRefreshHttpError(7), 1), (const NativeOAuthRefreshHttpError(9), 1),
      (http.RequestAbortedException(), 1), (10, 1), (StateError('synthetic sender failure'), 1)]) {
      var sent = 0;
      await expectLater(service((_) async { sent++; throw failure; }).refresh(),
        throwsA(isA<NativeOAuthRefreshFailure>().having((error) => error.code, 'native failure', code)));
      expect(sent, 1);
    }
  });

  test('Owned cancellation settles promptly with the proven native request-cancel error', () async {
    final response = Completer<http.Response>();
    var aborts = 0;
    final run = service((_) => throw StateError('Future-only sender was used')).startOwned(
      sendOwned: (_) => NativeOAuthRefreshOwnedSend(response: response.future, abort: () { aborts++; }));
    final cancelled = expectLater(run.result, throwsA(isA<NativeOAuthRefreshFailure>()
      .having((error) => error.code, 'native cancellation', 5)
      .having((error) => error.reason, 'request-owner cancellation', NativeOAuthRefreshFailureReason.cancelled)));
    run.cancel();
    run.cancel();
    await cancelled.timeout(const Duration(seconds: 1));
    expect(aborts, 1);
    response.completeError(const NativeOAuthRefreshHttpError(10));
    await Future<void>.delayed(Duration.zero);
  });

  test('The distinct refresh schema rejects malformed payloads before committing any state', () async {
    final invalidBodies = <String>['', '[]', '{} trailing'];
    for (final field in ['access_token', 'token_type', 'expires_in']) {
      final missing = Map<String, Object?>.from(_token)..remove(field);
      invalidBodies.add(jsonEncode(missing));
      invalidBodies.add(jsonEncode({..._token, field: null}));
    }
    for (final (field, value) in [('access_token', false), ('token_type', 1),
      ('expires_in', '3600'), ('expires_in', true), ('refresh_token', null)]) {
      invalidBodies.add(jsonEncode({..._token, field: value}));
    }
    for (final body in invalidBodies) {
      final state = NativeOAuthRefreshState(refreshToken: 'stored-refresh', dpopNonce: 'stored-nonce');
      var clocks = 0;
      await expectLater(service((_) async => http.Response(body, 200,
        headers: {'dpop-nonce': 'must-not-commit'}), state: state,
        nowMicroseconds: () { clocks++; return 0; }).refresh(), throwsA(isA<FormatException>()));
      expect(state.refreshToken, 'stored-refresh');
      expect(state.dpopNonce, 'stored-nonce');
      expect(clocks, 0);
    }
    for (final body in ['{', '[]', '{"error":null}', '{"error":123}']) {
      await expectLater(service((_) async => http.Response(body, 400)).refresh(),
        throwsA(isA<FormatException>()));
    }
    await expectLater(service((_) async => http.Response('{}', 400)).refresh(),
      throwsA(isA<NativeOAuthRefreshFailure>().having((error) => error.code, 'native failure', 1)));
    final empty = await service((_) async => http.Response(
      '{"access_token":"","token_type":"","expires_in":0}', 200)).refresh();
    expect(empty.accessToken, '');
    expect(empty.tokenType, '');
  });

  test('Refresh signed-int64 expiry matches original instruction vectors', () async {
    for (final scenario in fixture['numericCases'] as List) {
      final token = scenario['token'] as String;
      final body = jsonEncode(_token).replaceFirst('"expires_in":3600', '"expires_in":$token');
      final result = service((_) async => http.Response(body, 200)).refresh();
      if (scenario.containsKey('error')) {
        await expectLater(result, throwsA(isA<FormatException>()), reason: token);
      } else {
        expect((await result).expiresIn, scenario['value'], reason: token);
      }
    }
  });

  test('Expiry arithmetic retains signed microsecond wrapping and exact root decimal input', () async {
    for (final (seconds, expiresAt) in [('0', 100), ('-1', -999900),
      ('9223372036854775807', -999900), ('-9223372036854775808', 100)]) {
      final body = jsonEncode(_token).replaceFirst('"expires_in":3600', '"expires_in":$seconds');
      final result = await service((_) async => http.Response(body, 200), nowMicroseconds: () => 100).refresh();
      expect(result.expiresAtMicroseconds, expiresAt, reason: seconds);
    }
    final body = jsonEncode({..._token, 'access_token': 'literal "expires_in":7'})
      .replaceFirst('"expires_in":3600', r'"expires\u005fin":9223372036854775807.9999999999999999');
    final result = await service((_) async => http.Response(body, 200)).refresh();
    expect(result.expiresIn, 9223372036854775807);
    expect(result.accessToken, 'literal "expires_in":7');
  });
}
