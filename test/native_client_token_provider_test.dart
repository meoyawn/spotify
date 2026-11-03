import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/desktop_client_token_service.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';
import 'package:spotify_flutter/protocol/generated/es_client_token.pb.dart' as es;
import 'package:spotify_flutter/protocol/generated/spotify/client_token/v0/client_token_http.pb.dart' as backend;
import 'package:spotify_flutter/protocol/native_client_data.dart';
import 'package:spotify_flutter/protocol/native_client_token_provider.dart';

Future<void> _flush() => Future<void>.delayed(Duration.zero);

http.Response _grant({String token = 'granted', List<String> domains = const ['fixture.invalid', '', 'fixture.invalid']}) =>
  http.Response.bytes(backend.ClientTokenResponse(grantedToken: backend.GrantedTokenResponse(
    token: token, expiresAfterSeconds: 3600, refreshAfterSeconds: 1800,
    domains: domains.map((value) => backend.TokenDomain(domain: value)))).writeToBuffer(), 200);

NativeClientDataFactory _factory(Map input) => NativeClientDataFactory(
  clientId: input['clientId'] as String, clientVersion: input['clientVersion'] as String,
  deviceId: input['deviceId'] as String, developerApiKey: input['developerApiKey'] as String?,
  facts: MacOSPlatformFacts(systemVersionString: input['systemVersionString'] as String,
    majorVersion: input['majorVersion'] as int, minorVersion: input['minorVersion'] as int,
    patchVersion: input['patchVersion'] as int, hardwareModel: input['hardwareModel'] as String,
    cpuType: input['cpuType'] as int, cpuSubtype: input['cpuSubtype'] as int));

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-client-token-provider.json').readAsStringSync()) as Map;
  final base = (fixture['hashCases'] as List).first as Map;

  NativeClientToken seed({String token = 'seed', int expires = 200, int refresh = 101,
      String? hash, List<String> domains = const ['fixture.invalid']}) => NativeClientToken(token: token,
    expiresAtMicroseconds: expires, refreshAtMicroseconds: refresh,
    clientDataHash: hash ?? base['clientDataHash'] as String, domains: domains);

  test('Client-data cache keys retain the original Mac field order, binary integers, UTF-8 and copied NUL', () {
    for (final scenario in fixture['hashCases'] as List) {
      final harness = _Harness(_factory(scenario as Map), now: 100,
        initial: seed(hash: scenario['clientDataHash'] as String));
      expect(harness.provider.clientDataHash, scenario['clientDataHash'], reason: scenario['name'] as String);
      harness.provider.enable();
      expect(harness.provider.peek()?.token, 'seed');
      expect(harness.requests, isEmpty);
      harness.provider.close();
    }
  });

  test('Cache admission matches original refresh equality, hash and lifecycle instruction cases', () {
    for (final scenario in fixture['cacheCases'] as List) {
      final hash = base['clientDataHash'] as String;
      final harness = _Harness(_factory(base), now: scenario['nowMicroseconds'] as int,
        initial: scenario['present'] as bool ? seed(expires: scenario['expiresAtMicroseconds'] as int,
          refresh: scenario['refreshAtMicroseconds'] as int,
          hash: scenario['hashMatches'] as bool ? hash : hash.substring(0, hash.length - 1)) : null);
      if (scenario['enabled'] as bool) harness.provider.enable();
      if (scenario['closed'] as bool) harness.provider.close();
      expect(harness.provider.peek() != null, scenario['returnsToken'], reason: scenario['name'] as String);
      expect(harness.requests, isEmpty, reason: 'peek never acquires');
      harness.provider.close();
    }
  });

  test('Construction and enable do not acquire; disabled, cached and deferred cancellation paths stay distinct', () async {
    final harness = _Harness(_factory(base), initial: seed(), now: 100);
    addTearDown(harness.provider.close);
    final results = <NativeClientTokenResult>[];
    final cancel = harness.provider.acquire((_) => fail('Canceled disabled callback ran'));
    cancel();
    harness.provider.acquire(results.add);
    expect(results, isEmpty);
    await _flush();
    expect((results.single as NativeClientTokenFailure).code, 3);
    harness.provider.enable();
    final cached = Completer<NativeClientTokenResult>();
    harness.provider.acquire(cached.complete);
    harness.provider.disable();
    expect((await cached.future as NativeClientTokenSuccess).token.token, 'seed',
      reason: 'the independently queued cached delivery retains its snapshot');
    expect(harness.provider.peek(), isNull);
    expect(harness.requests, isEmpty);
  });

  test('Concurrent acquisitions share challenge work and individual cancellation does not abort it', () async {
    final harness = _Harness(_factory(base), initial: seed(refresh: 99), now: 100);
    addTearDown(harness.provider.close);
    harness.provider.enable();
    final cancel = harness.provider.acquire((_) => fail('Canceled acquisition callback ran'));
    final result = Completer<NativeClientTokenResult>();
    harness.provider.acquire(result.complete);
    expect(harness.requests, hasLength(1));
    expect(harness.requests.single.clientData.currentToken, 'seed');
    cancel();
    expect(harness.aborts, 0);
    harness.responses.first.complete(http.Response.bytes(backend.ClientTokenResponse(challenges:
      backend.ChallengesResponse(state: 'opaque-state', challenges: [backend.Challenge(
        evaluateHashcashParameters: backend.HashCashParameters(length: 0, prefix: ''))]))
      .writeToBuffer(), 200));
    await harness.sent(2);
    expect(harness.requests.last.challengeAnswers.state, 'opaque-state');
    harness.responses.last.complete(_grant());
    final token = (await result.future.timeout(const Duration(seconds: 5)) as NativeClientTokenSuccess).token;
    expect((token.token, token.expiresAtMicroseconds, token.refreshAtMicroseconds),
      ('granted', 3600000100, 1800000100));
    expect(token.domains, ['fixture.invalid', '', 'fixture.invalid']);
    expect(token.clientDataHash, base['clientDataHash']);
    expect(harness.provider.peek(), same(token));
    expect(harness.encodedInputs.single, same(token));
    expect(harness.aborts, 0);
    expect(harness.errors, isEmpty);
  });

  test('Only forbidden acquisition latches failure and invalidates; ordinary failure preserves the old cache', () async {
    for (final status in [403, 500]) {
      final harness = _Harness(_factory(base), initial: seed(refresh: 99), now: 100);
      harness.provider.enable();
      final changes = <NativeClientToken?>[];
      final encrypted = <String>[];
      harness.provider.observeTokens(changes.add);
      harness.provider.observeEncryptedTokens(encrypted.add);
      final result = Completer<NativeClientTokenResult>();
      harness.provider.acquire(result.complete);
      harness.responses.single.complete(http.Response('', status));
      expect((await result.future as NativeClientTokenFailure).code, status == 403 ? 104 : 101);
      harness.now = 99;
      expect(harness.provider.peek()?.token, status == 403 ? null : 'seed');
      expect(changes, status == 403 ? [null] : isEmpty);
      expect(encrypted, status == 403 ? [''] : isEmpty);
      harness.now = 100;
      final again = Completer<NativeClientTokenResult>();
      harness.provider.acquire(again.complete);
      if (status == 403) {
        expect((await again.future as NativeClientTokenFailure).code, 104);
        expect(harness.requests, hasLength(1));
        harness.provider.invalidate();
        expect(harness.provider.failure?.code, 104);
      } else {
        expect(harness.requests, hasLength(2));
        harness.responses.last.complete(_grant());
        expect(await again.future, isA<NativeClientTokenSuccess>());
      }
      harness.provider.close();
    }
  });

  test('Close aborts the active send and completes only live waiters, with no late publication or restart', () async {
    final harness = _Harness(_factory(base), now: 100);
    harness.provider.enable();
    final changes = <NativeClientToken?>[];
    harness.provider.observeTokens(changes.add);
    final result = Completer<NativeClientTokenResult>();
    harness.provider.acquire(result.complete);
    harness.provider.acquire((_) => fail('Canceled waiter received close'))();
    harness.provider.close();
    harness.provider.close();
    expect(harness.aborts, 1);
    expect((await result.future as NativeClientTokenFailure).code, 1);
    harness.responses.single.complete(_grant());
    await _flush();
    expect(changes, isEmpty);
    expect(harness.encodedInputs, isEmpty);
    expect(harness.errors, isEmpty);
    harness.provider.enable();
    harness.provider.acquire((_) => fail('Closed provider restarted'));
    expect(harness.requests, hasLength(1));
  });

  test('Known native send errors wrap 101 with nested identity while unrelated failures remain unclassified', () async {
    for (final error in [const NativeClientTokenTransportError(category: 'http', code: 10,
      message: 'http_error_aborted'), StateError('Synthetic unclassified sender failure')]) {
      final harness = _Harness(_factory(base), now: 100);
      harness.provider.enable();
      final received = <NativeClientTokenResult>[];
      harness.provider.acquire(received.add);
      harness.responses.single.completeError(error);
      await _flush();
      if (error is NativeClientTokenTransportError) {
        final failure = received.single as NativeClientTokenFailure;
        expect(failure.code, 101);
        expect(failure.transportError, same(error));
        expect(harness.errors, isEmpty);
      } else {
        expect(harness.errors.single, same(error));
        expect(received, isEmpty);
        harness.provider.close();
        expect((received.single as NativeClientTokenFailure).code, 1);
      }
      harness.provider.close();
    }
  });

  test('getToken serializes original mapper timestamps, hash bytes, domains and populated result', () async {
    for (final scenario in fixture['serviceCases'] as List) {
      final expected = scenario['esperanto'] as Map;
      final config = (fixture['hashCases'] as List)[scenario['clientDataCase'] as int] as Map;
      final harness = _Harness(_factory(config), now: scenario['refreshAtMicroseconds'] as int,
        initial: NativeClientToken(token: scenario['token'] as String,
          expiresAtMicroseconds: scenario['expiresAtMicroseconds'] as int,
          refreshAtMicroseconds: scenario['refreshAtMicroseconds'] as int,
          clientDataHash: scenario['clientDataHash'] as String, domains: (scenario['domains'] as List).cast<String>()));
      harness.provider.enable();
      final dispatcher = EsperantoDispatcher();
      DesktopClientTokenService(harness.provider).register(dispatcher);
      final response = es.AcquireResult.fromBuffer(await dispatcher.callSingle(
        EsperantoCall(DesktopClientTokenService.id, 'getToken', [])));
      expect(response.whichResult(), es.AcquireResult_Result.token);
      expect(response.token.token, expected['token']);
      expect(response.token.expiresAtTimestamp.toInt(), expected['expiresAtTimestamp']);
      expect(response.token.refreshAtTimestamp.toInt(), expected['refreshAtTimestamp']);
      expect(response.token.clientDataHash, expected['clientDataHash']);
      expect(response.token.domains, expected['domains']);
      expect(harness.requests, isEmpty);
      harness.provider.close();
    }
  });

  test('getToken failures retain original category messages and the native optional detail syntax', () async {
    final harness = _Harness(_factory(base), now: 100);
    addTearDown(harness.provider.close);
    harness.provider.enable();
    final dispatcher = EsperantoDispatcher();
    DesktopClientTokenService(harness.provider).register(dispatcher);
    for (final scenario in fixture['errorCases'] as List) {
      for (final detail in ['', 'opaque [detail] \u96ea']) {
        harness.provider.setFailure(NativeClientTokenFailure(scenario['code'] as int, detail: detail));
        final response = es.AcquireResult.fromBuffer(await dispatcher.callSingle(
          EsperantoCall(DesktopClientTokenService.id, 'getToken', [])));
        expect(response.whichResult(), es.AcquireResult_Result.failure);
        expect(response.failure.code, scenario['code']);
        expect(response.failure.message, '${scenario['message']}${detail.isEmpty ? '' : ' [$detail]'}');
      }
    }
    expect(harness.requests, isEmpty);
  });

  test('getEncryptedToken streams changes without replay or acquisition and cancels its own subscription', () async {
    final harness = _Harness(_factory(base), initial: seed(), now: 100);
    addTearDown(harness.provider.close);
    harness.provider.enable();
    final dispatcher = EsperantoDispatcher();
    DesktopClientTokenService(harness.provider).register(dispatcher);
    final messages = <es.EncryptedClientToken>[];
    final subscription = dispatcher.callStream(EsperantoCall(DesktopClientTokenService.id,
      'getEncryptedToken', [])).listen((bytes) => messages.add(es.EncryptedClientToken.fromBuffer(bytes)));
    await _flush();
    expect(messages, isEmpty);
    expect(harness.requests, isEmpty);
    harness.provider.invalidate();
    await _flush();
    expect(messages.single.encryptedToken, '');
    expect(harness.requests, isEmpty);
    final acquired = Completer<NativeClientTokenResult>();
    harness.provider.acquire(acquired.complete);
    harness.responses.single.complete(_grant());
    await acquired.future;
    await _flush();
    expect(messages.map((value) => value.encryptedToken), ['', 'opaque-codec-output']);
    expect(harness.encodedInputs.single.token, 'granted');
    await subscription.cancel();
    harness.provider.invalidate();
    await _flush();
    expect(messages, hasLength(2));
  });
}

class _Harness {
  _Harness(NativeClientDataFactory data, {required this.now, NativeClientToken? initial}) {
    provider = NativeClientTokenProvider(clientData: data, initialToken: initial,
      nowMicroseconds: () => now, encodeToken: (token) {
        encodedInputs.add(token);
        return 'opaque-codec-output';
      }, onError: (error, stack) { errors.add(error); }, sendOwned: (body) {
        requests.add(backend.ClientTokenRequest.fromBuffer(body));
        final response = Completer<http.Response>();
        responses.add(response);
        for (final (count, waiter) in _sendWaiters) {
          if (requests.length >= count && !waiter.isCompleted) waiter.complete();
        }
        return NativeClientTokenOwnedSend(response: response.future, abort: () { aborts++; });
      });
  }
  late final NativeClientTokenProvider provider;
  int now;
  int aborts = 0;
  final requests = <backend.ClientTokenRequest>[];
  final responses = <Completer<http.Response>>[];
  final encodedInputs = <NativeClientToken>[];
  final errors = <Object>[];
  final _sendWaiters = <(int, Completer<void>)>[];
  Future<void> sent(int count) {
    if (requests.length >= count) return Future.value();
    final waiter = Completer<void>();
    _sendWaiters.add((count, waiter));
    return waiter.future.timeout(const Duration(seconds: 5));
  }
}
