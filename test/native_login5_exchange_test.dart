import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/challenges/code.pb.dart' as code;
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/challenges/hashcash.pb.dart' as hashcash;
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/login5.pb.dart' as proto;
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';
import 'package:spotify_flutter/protocol/native_login5_exchange.dart';
import 'package:spotify_flutter/protocol/native_login5_request.dart';
import 'package:spotify_flutter/protocol/native_login5_response.dart';

Future<void> _microtasks() => Future<void>.delayed(Duration.zero);

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-login5-exchange.json').readAsStringSync()) as Map<String, dynamic>;

  test('Owned HTTP processing matches original callback/parser results, retry state and independent model clock reads', () async {
    for (final item in fixture['httpCallbacks'] as List<dynamic>) {
      final row = item as Map<String, dynamic>, expected = row['native'] as Map<String, dynamic>;
      final outcome = expected['outcome'] as Map<String, dynamic>;
      final h = _Harness();
      h.sends.single.events.add(http.Response.bytes(hex.decode(row['bodyHex'] as String), row['status'] as int));
      await _microtasks();
      expect(h.counter.currentCount, expected['retryCountAfter'], reason: row['name'] as String);
      expect(h.clockReads, expected['modelClockReads'], reason: row['name'] as String);
      if (outcome['kind'] == 'challenges') {
        expect(h.contexts.single.responseAtMicroseconds, outcome['responseAtMicroseconds']);
        expect(h.contexts.single.savedResponseAttempts, outcome['savedResponseAttempts']);
        h.run.cancel();
        h.deliver();
        await h.run.result;
        continue;
      }
      h.deliver();
      final result = await h.run.result;
      if (outcome['kind'] == 'failure') {
        expect((result as NativeLogin5Failure).code, outcome['code'], reason: row['name'] as String);
      } else if (outcome['kind'] == 'signup') {
        expect(result, isA<NativeLogin5SignupRequired>(), reason: row['name'] as String);
      } else {
        final ok = result as NativeLogin5Success;
        expect({'kind': 'ok', 'username': ok.username, 'accessToken': ok.accessToken,
          'storedCredentialHex': hex.encode(ok.storedCredential), 'expiresAtMicroseconds': ok.expiresAtMicroseconds,
          'tokenType': ok.tokenType}, outcome, reason: row['name'] as String);
      }
    }
  });

  test('Scoped cancel replaces queued success before native-style delivery, without a second observer', () async {
    final h = _Harness();
    expect(hex.encode(h.plans.single.request.body), (fixture['initialRequest'] as Map<String, dynamic>)['hex']);
    final success = (fixture['httpCallbacks'] as List<dynamic>).cast<Map<String, dynamic>>().singleWhere((row) => row['name'] == 'success reads model clock twice');
    h.sends.single.events.add(http.Response.bytes(hex.decode(success['bodyHex'] as String), 200));
    await _microtasks();
    h.run.cancel();
    h.deliver();
    final result = await h.run.result as NativeLogin5Failure;
    final expected = (fixture['sequences'] as List<dynamic>).cast<Map<String, dynamic>>().singleWhere((row) => row['name'] == 'success then cancel before queued delivery');
    expect(result.code, (expected['delivered'] as Map<String, dynamic>)['code']);
    expect(h.sends.single.events.hasListener, false);
    h.run.cancel();
    expect(h.deliveries, isEmpty);
  });

  for (final skippedSms in [false, true]) {
    test('Given executor ${skippedSms ? 'SMS skip' : 'hashcash answer'} continues with independently encoded body and reset retry count', () async {
      final h = _Harness();
      final bodies = fixture['continuationBodies'] as Map<String, dynamic>;
      final challenge = skippedSms ? proto.Challenge(code: code.CodeChallenge(method: code.CodeChallenge_Method.UNKNOWN, codeLength: 6))
        : proto.Challenge(hashcash: hashcash.HashcashChallenge(prefix: [1, 2], length: 0));
      h.sends.single.events.add(http.Response.bytes(proto.LoginResponse(challenges: proto.Challenges(challenges: [challenge]),
        loginContext: hex.decode(bodies['loginContextHex'] as String)).writeToBuffer(), 200));
      await _microtasks();
      final solutions = proto.ChallengeSolutions(solutions: skippedSms ? [] : [nativeLogin5HashcashAnswer(
        suffix: hex.decode(bodies['hashcashSuffixHex'] as String), elapsedNanoseconds: bodies['elapsedNanoseconds'] as int)]);
      h.tasks.single.events.add(solutions);
      await _microtasks();
      expect(h.plans.length, 2);
      expect(hex.encode(h.plans.last.request.body), bodies[skippedSms ? 'skippedSms' : 'hashcash']);
      expect(h.plans.last.request.headers['X-Retry-Count'], '0');
      h.sends.last.events.add(http.Response.bytes(hex.decode('1002'), 200));
      await _microtasks();
      h.deliver();
      expect((await h.run.result as NativeLogin5Failure).code, 103);
    });
  }

  test('Phone fallback reuses original challenge snapshot and increments its attempt rather than extending expiry', () async {
    final h = _Harness(credential: const NativeLogin5PhoneNumber(number: '', isoCountryCode: '', countryCallingCode: ''));
    h.sends.single.events.add(http.Response.bytes(proto.LoginResponse(challenges: proto.Challenges(), loginContext: [1, 0]).writeToBuffer(), 200));
    await _microtasks();
    h.tasks.single.events.add(proto.ChallengeSolutions());
    await _microtasks();
    h.sends.last.events.add(http.Response.bytes(hex.decode('1001'), 200));
    await _microtasks();
    final expected = fixture['phoneFallbackContext'] as Map<String, dynamic>;
    expect(h.contexts.last.responseAtMicroseconds, expected['responseAtMicroseconds']);
    expect(h.contexts.last.savedResponseAttempts, expected['savedResponseAttempts']);
    expect(h.clockReads, [100, 200]);
    h.run.cancel();
    h.deliver();
    expect((await h.run.result as NativeLogin5Failure).code, 1);
  });

  test('Cancel expires HTTP and challenge continuations; late futures cause no new send or counter commit', () async {
    for (final pendingChallenge in [false, true]) {
      final h = _Harness();
      if (pendingChallenge) {
        h.sends.single.events.add(http.Response.bytes(proto.LoginResponse(challenges: proto.Challenges()).writeToBuffer(), 200));
        await _microtasks();
      }
      final clocks = List<int>.of(h.clockReads);
      h.run.cancel();
      h.deliver();
      expect((await h.run.result as NativeLogin5Failure).code, 1);
      if (pendingChallenge) {
        expect(h.tasks.single.events.hasListener, false);
        h.tasks.single.completion.complete(proto.ChallengeSolutions());
      } else {
        expect(h.sends.single.events.hasListener, false);
        h.sends.single.completion.complete(http.Response('', 503));
      }
      await _microtasks();
      expect(h.plans.length, 1);
      expect(h.clockReads, clocks);
      expect(h.counter.currentCount, 0);
      expect(h.deliveries, isEmpty);
    }
  });

  test('Transport category identity controls abort suppression and arbitrary Dart exceptions stay unclassified', () async {
    for (final item in fixture['transportCallbacks'] as List<dynamic>) {
      final row = item as Map<String, dynamic>, expected = row['native'] as Map<String, dynamic>;
      final h = _Harness();
      h.sends.single.events.addError(row['httpCategory'] == true ? NativeLogin5HttpFailure(row['code'] as int)
        : NativeLogin5OtherTransportFailure(row['code'] as int));
      await _microtasks();
      expect(h.counter.currentCount, expected['retryCountAfter']);
      final outcome = expected['outcome'] as Map<String, dynamic>;
      if (outcome['kind'] == 'ignored') {
        expect(h.deliveries, isEmpty);
        h.run.cancel();
      }
      h.deliver();
      expect((await h.run.result as NativeLogin5Failure).code, outcome['kind'] == 'ignored' ? 1 : outcome['code']);
    }
    final h = _Harness(), error = StateError('unclassified sender failure');
    final observed = expectLater(h.run.result, throwsA(same(error)));
    h.sends.single.events.addError(error);
    await _microtasks();
    h.deliver();
    await observed;
    expect(h.counter.currentCount, 0);
  });
}

class _Boundary<T> {
  _Boundary() {
    subscription = events.stream.listen(completion.complete, onError: completion.completeError);
  }
  final events = StreamController<T>();
  final completion = Completer<T>();
  late final StreamSubscription<T> subscription;
  void release() { unawaited(subscription.cancel()); unawaited(events.close()); }
}

class _Harness {
  _Harness({NativeLogin5Credential? credential}) {
    counter = NativeLogin5RetryCounter(monotonicNowNanoseconds: () => 1000);
    final exchange = NativeLogin5V3Exchange(planner: NativeLogin5RequestPlanner(counter: counter), executeDelivery: deliveries.add,
      nowMicroseconds: () { clockReads.add((clockReads.length + 1) * 100); return clockReads.last; },
      sendOwned: (plan) {
        plans.add(plan);
        final boundary = _Boundary<http.Response>();
        sends.add(boundary);
        return NativeLogin5OwnedSend(response: boundary.completion.future, cancel: boundary.release);
      }, executeChallenges: (continuation, context) {
        contexts.add(context);
        final boundary = _Boundary<proto.ChallengeSolutions>();
        tasks.add(boundary);
        return NativeLogin5OwnedChallenges(solutions: boundary.completion.future, release: boundary.release);
      });
    run = exchange.start(credentials: const NativeLogin5Credentials(clientId: 'synthetic-client', deviceId: 'synthetic-device'),
      credential: credential ?? NativeLogin5StoredCredential(username: 'synthetic-user', data: [0, 255]));
    addTearDown(() async {
      run.cancel();
      deliver();
      for (final boundary in [...sends, ...tasks]) { boundary.release(); }
      await _microtasks();
    });
  }
  late final NativeLogin5RetryCounter counter;
  late final NativeLogin5V3Run run;
  final plans = <NativeLogin5RequestPlan>[];
  final sends = <_Boundary<http.Response>>[];
  final tasks = <_Boundary<proto.ChallengeSolutions>>[];
  final contexts = <NativeLogin5ChallengeContext>[];
  final clockReads = <int>[];
  final deliveries = <void Function()>[];
  void deliver() { while (deliveries.isNotEmpty) { deliveries.removeAt(0)(); } }
}
