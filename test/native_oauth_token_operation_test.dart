import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/native_oauth_exchange.dart';
import 'package:spotify_flutter/protocol/native_oauth_refresh.dart';
import 'package:spotify_flutter/protocol/native_oauth_token_operation.dart';
import 'package:spotify_flutter/protocol/native_token_provider.dart';

http.Response _success({String token = 'access', String refreshToken = 'rotated', String nonce = 'success-nonce'}) =>
  http.Response(jsonEncode({'access_token': token, 'token_type': 'DPoP',
    'expires_in': 3600, 'refresh_token': refreshToken}), 200, headers: {'dpop-nonce': nonce});

NativeOAuthRefresh _refresh(NativeOAuthRefreshState state, {NativeOAuthProof? proof, int Function()? clock}) =>
  NativeOAuthRefresh(clientId: 'client-fixture', state: state, proof: proof,
    send: (_) => throw StateError('The adapter must use its owned sender'),
    nowMicroseconds: clock ?? () => 100);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('The real OAuth owner serves the provider and provider close aborts its next refresh', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'stored', dpopNonce: 'initial');
    final nonces = <String?>[];
    final pending = Completer<http.Response>();
    final entered = Completer<void>();
    var sends = 0;
    var aborts = 0;
    final operation = NativeOAuthTokenOperation(refresh: _refresh(state,
      proof: ({required String method, required String url, required String? nonce}) async {
        nonces.add(nonce);
        return 'proof-${nonces.length}';
      }), sendOwned: (_) {
        sends++;
        final Future<http.Response> response;
        if (sends == 1) {
          response = Future.value(http.Response('{"error":"use_dpop_nonce"}', 400,
            headers: {'dpop-nonce': 'challenge'}));
        } else if (sends == 2) {
          response = Future.value(_success());
        } else {
          entered.complete();
          response = pending.future;
        }
        return NativeOAuthRefreshOwnedSend(response: response, abort: () { aborts++; });
      }, onError: (error, stack) => fail('Unexpected unclassified failure: $error'));
    final provider = NativeTokenProvider(operationFactory: () => operation,
      nowMicroseconds: () => 100, nowNanoseconds: () => 0);
    addTearDown(provider.close);
    final initial = Completer<NativeTokenResult>();
    provider.request(initial.complete);
    final token = (await initial.future.timeout(const Duration(seconds: 1)) as NativeTokenSuccess).token;
    expect((token.accessToken, token.tokenType, token.expiresAtMicroseconds), ('access', 'DPoP', 3600000100));
    expect(nonces, ['initial', 'challenge']);
    expect((state.refreshToken, state.dpopNonce), ('rotated', 'success-nonce'));
    expect(aborts, 0, reason: 'completed sends are not aborted');

    final waiting = Completer<NativeTokenResult>();
    provider.request(waiting.complete, forceRefresh: true);
    await entered.future.timeout(const Duration(seconds: 1));
    provider.close();
    expect((await waiting.future as NativeTokenFailure).code, 1);
    expect(aborts, 1);
    pending.complete(_success(refreshToken: 'must-not-rotate', nonce: 'must-not-commit'));
    await _flush();
    expect((state.refreshToken, state.dpopNonce), ('rotated', 'success-nonce'));
    expect(sends, 3);
    expect(provider.peek(), isNull);
  });

  test('Detaching observation leaves owned work and state commits intact and allows another start', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'stored', dpopNonce: 'initial');
    final response = Completer<http.Response>();
    final committed = Completer<void>();
    var aborts = 0;
    var sends = 0;
    final delivered = <NativeTokenRefreshResult>[];
    final operation = NativeOAuthTokenOperation(refresh: _refresh(state, clock: () {
      if (!committed.isCompleted) committed.complete();
      return 100;
    }), sendOwned: (_) => NativeOAuthRefreshOwnedSend(
      response: ++sends == 1 ? response.future : Future.value(_success(token: 'second')),
      abort: () { aborts++; }), onError: (error, stack) => fail('Unexpected failure: $error'));
    addTearDown(operation.stop);
    final detach = operation.start(delivered.add);
    detach();
    detach();
    expect(aborts, 0);
    response.complete(_success());
    await committed.future.timeout(const Duration(seconds: 1));
    await _flush();
    expect(delivered, isEmpty);
    expect(state.refreshToken, 'rotated');
    expect(state.dpopNonce, 'success-nonce');
    final next = Completer<NativeTokenRefreshResult>();
    operation.start(next.complete);
    expect((await next.future as NativeTokenRefreshSuccess).token.accessToken, 'second');
    expect(aborts, 0);
  });

  test('Stop during pending proof prevents send even after a late proof succeeds or fails', () async {
    for (final failProof in [false, true]) {
      final state = NativeOAuthRefreshState(refreshToken: 'stored', dpopNonce: 'initial');
      final proof = Completer<String?>();
      var proofs = 0;
      var sends = 0;
      final operation = NativeOAuthTokenOperation(refresh: _refresh(state,
        proof: ({required String method, required String url, required String? nonce}) {
          proofs++;
          return proof.future;
        }), sendOwned: (_) {
          sends++;
          throw StateError('Canceled proof must not reach send');
        }, onError: (error, stack) => fail('Stopped operation published error: $error'));
      operation.start((_) => fail('Stopped operation published a result'));
      expect(proofs, 1);
      operation.stop();
      operation.stop();
      if (failProof) {
        proof.completeError(StateError('Late signer failure'));
      } else {
        proof.complete('late-proof');
      }
      await _flush();
      operation.start((_) => fail('A stopped owner restarted'));
      await _flush();
      expect(sends, 0);
      expect(proofs, 1);
      expect((state.refreshToken, state.dpopNonce), ('stored', 'initial'));
    }
  });

  test('Stop aborts once and suppresses late success, nonce challenge, and transport failure', () async {
    for (final late in ['success', 'challenge', 'error']) {
      final state = NativeOAuthRefreshState(refreshToken: 'stored', dpopNonce: 'initial');
      final response = Completer<http.Response>();
      var aborts = 0;
      var sends = 0;
      var clocks = 0;
      final operation = NativeOAuthTokenOperation(refresh: _refresh(state, clock: () { clocks++; return 0; }),
        sendOwned: (_) {
          sends++;
          return NativeOAuthRefreshOwnedSend(response: response.future, abort: () { aborts++; });
        }, onError: (error, stack) => fail('Stopped operation published error: $error'));
      final detach = operation.start((_) => fail('Stopped operation published a result'));
      detach();
      operation.stop();
      operation.stop();
      expect(aborts, 1);
      if (late == 'success') {
        response.complete(_success());
      } else if (late == 'challenge') {
        response.complete(http.Response('{"error":"use_dpop_nonce"}', 400,
          headers: {'dpop-nonce': 'late-challenge'}));
      } else {
        response.completeError(const NativeOAuthRefreshHttpError(10));
      }
      await _flush();
      expect(sends, 1);
      expect(clocks, 0);
      expect((state.refreshToken, state.dpopNonce), ('stored', 'initial'));
    }
  });

  test('Stopping retry proof preserves the prior challenge but prevents a second send', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'stored', dpopNonce: 'initial');
    final retryProof = Completer<String?>();
    final enteredRetry = Completer<void>();
    var proofs = 0;
    var sends = 0;
    var aborts = 0;
    final operation = NativeOAuthTokenOperation(refresh: _refresh(state,
      proof: ({required String method, required String url, required String? nonce}) {
        if (++proofs == 1) return Future.value('initial-proof');
        enteredRetry.complete();
        return retryProof.future;
      }), sendOwned: (_) {
        sends++;
        return NativeOAuthRefreshOwnedSend(response: Future.value(http.Response(
          '{"error":"use_dpop_nonce"}', 400, headers: {'dpop-nonce': 'committed-challenge'})),
          abort: () { aborts++; });
      }, onError: (error, stack) => fail('Stopped retry published error: $error'));
    operation.start((_) => fail('Stopped retry published a result'));
    await enteredRetry.future.timeout(const Duration(seconds: 1));
    expect(state.dpopNonce, 'committed-challenge');
    operation.stop();
    retryProof.complete('late-retry-proof');
    await _flush();
    expect((sends, aborts), (1, 0));
    expect((state.refreshToken, state.dpopNonce), ('stored', 'committed-challenge'));
  });

  test('Stop racing synchronous send-owner creation aborts the returned owner', () async {
    final state = NativeOAuthRefreshState(refreshToken: 'stored', dpopNonce: 'initial');
    final response = Completer<http.Response>();
    var aborts = 0;
    late NativeOAuthTokenOperation operation;
    operation = NativeOAuthTokenOperation(refresh: _refresh(state), sendOwned: (_) {
      operation.stop();
      return NativeOAuthRefreshOwnedSend(response: response.future, abort: () { aborts++; });
    }, onError: (error, stack) => fail('Stopped creation published error: $error'));
    operation.start((_) => fail('Stopped creation published a result'));
    expect(aborts, 1);
    response.complete(_success());
    await _flush();
    expect((state.refreshToken, state.dpopNonce), ('stored', 'initial'));
  });

  test('Known refresh errors publish their domain and malformed responses retain a separate error channel', () async {
    for (final malformed in [false, true]) {
      final state = NativeOAuthRefreshState(refreshToken: 'stored', dpopNonce: 'initial');
      final delivered = <NativeTokenRefreshResult>[];
      final errors = <Object>[];
      final finished = Completer<void>();
      final operation = NativeOAuthTokenOperation(refresh: _refresh(state), sendOwned: (_) =>
        NativeOAuthRefreshOwnedSend(response: malformed ? Future.value(http.Response('{}', 200)) :
          Future.error(const NativeOAuthRefreshHttpError(10)), abort: () => fail('Completed send was aborted')),
        onError: (error, stack) { errors.add(error); finished.complete(); });
      operation.start((result) { delivered.add(result); finished.complete(); });
      await finished.future.timeout(const Duration(seconds: 1));
      if (malformed) {
        expect(errors.single, isA<FormatException>());
        expect(delivered, isEmpty);
      } else {
        expect((delivered.single as NativeTokenRefreshFailure).code, 5);
        expect(errors, isEmpty);
      }
      operation.stop();
      expect((state.refreshToken, state.dpopNonce), ('stored', 'initial'));
    }
  });
}
