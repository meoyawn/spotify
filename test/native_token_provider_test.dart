import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_token_provider.dart';

const _seed = NativeAccessToken(accessToken: 'seed', tokenType: 'Bearer', expiresAtMicroseconds: 9000000000);
const _replacement = NativeAccessToken(accessToken: 'replacement', tokenType: 'DPoP', expiresAtMicroseconds: 3600000000);

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-token-provider.json').readAsStringSync()) as Map;

  test('Cache-only admission follows the original native instruction cases', () {
    for (final scenario in fixture['cacheCases'] as List) {
      final harness = _Harness(initialToken: scenario['present'] as bool ? NativeAccessToken(
        accessToken: '', tokenType: '', expiresAtMicroseconds: scenario['expiryMicroseconds'] as int) : null);
      harness.clock.wallMicroseconds = scenario['nowMicroseconds'] as int;
      if (scenario['invalidated'] as bool) harness.provider.invalidate();
      if (scenario['stopped'] as bool) harness.provider.close();
      expect(harness.provider.peek() != null, scenario['returnsToken'], reason: scenario['name'] as String);
      expect(harness.operation.starts, 0, reason: 'peek does not run the queued refresh');
      harness.provider.close();
    }
  });

  test('Construction refreshes a seed while normal and forced callers use the native sharing rule', () {
    final harness = _Harness(initialToken: _seed);
    final cached = <NativeTokenResult>[];
    final forced = <NativeTokenResult>[];
    harness.provider.request(cached.add);
    harness.provider.request(forced.add, forceRefresh: true);
    harness.provider.request(forced.add, forceRefresh: true);
    expect(cached, isEmpty);
    expect(forced, isEmpty);
    harness.clock.flush();
    expect((cached.single as NativeTokenSuccess).token, same(_seed));
    expect(harness.operation.starts, 0);
    harness.clock.runDue();
    expect(harness.operation.starts, 1);
    harness.operation.complete(const NativeTokenRefreshSuccess(_replacement));
    harness.clock.flush();
    expect(forced, hasLength(2));
    expect(forced.cast<NativeTokenSuccess>().map((result) => result.token.accessToken),
      ['replacement', 'replacement']);
    expect(harness.provider.peek(), same(_replacement));
    harness.provider.close();
  });

  test('Canceling one subscriber leaves shared refresh and other callbacks intact', () {
    final cachedHarness = _Harness(initialToken: _seed);
    final cancelCached = cachedHarness.provider.request((_) => fail('Canceled cached callback was invoked'));
    cancelCached();
    final cached = <NativeTokenResult>[];
    cachedHarness.provider.request(cached.add);
    cachedHarness.provider.close();
    cachedHarness.clock.flush();
    expect((cached.single as NativeTokenSuccess).token, same(_seed),
      reason: 'a separately retained cache-hit delivery does not belong to the pending queue');

    final harness = _Harness();
    final delivered = <NativeTokenResult>[];
    final cancel = harness.provider.request((_) => fail('Canceled subscriber was invoked'));
    harness.provider.request(delivered.add);
    harness.clock.runDue();
    cancel();
    cancel();
    expect(harness.operation.cancels, 0);
    harness.operation.complete(const NativeTokenRefreshSuccess(_replacement));
    harness.clock.flush();
    expect(delivered.single, isA<NativeTokenSuccess>());
    expect(harness.operation.starts, 1);
    harness.provider.close();
  });

  test('Success schedules from the native expiry vectors and resets accumulated failure count', () {
    for (final scenario in fixture['successDelayCases'] as List) {
      final harness = _Harness();
      harness.clock.runDue();
      harness.operation.complete(const NativeTokenRefreshFailure(1));
      harness.clock.flush();
      harness.clock.advanceMilliseconds(5000);
      harness.clock.wallMicroseconds = 123456789;
      harness.operation.complete(NativeTokenRefreshSuccess(NativeAccessToken(
        accessToken: 'fixture', tokenType: '', expiresAtMicroseconds:
          harness.clock.wallMicroseconds + (scenario['remainingMicroseconds'] as int))));
      harness.clock.flush();
      expect(harness.clock.nextDelayMilliseconds, scenario['delayMilliseconds']);
      harness.clock.advanceMilliseconds(scenario['delayMilliseconds'] as int);
      harness.operation.complete(const NativeTokenRefreshFailure(1));
      harness.clock.flush();
      expect(harness.clock.nextDelayMilliseconds, 5000);
      harness.provider.close();
    }
  });

  test('Transient refresh retries retain the original deterministic delay sequence', () {
    final harness = _Harness();
    harness.clock.runDue();
    final delays = fixture['retryDelaysMilliseconds'] as List;
    for (final delay in delays) {
      harness.operation.complete(const NativeTokenRefreshFailure(1));
      harness.clock.flush();
      expect(harness.clock.nextDelayMilliseconds, delay);
      harness.clock.advanceMilliseconds(delay as int);
    }
    expect(harness.operation.starts, delays.length + 1);
    harness.provider.close();
  });

  test('Refresh errors use the provider domain and permanent errors require a new request', () {
    for (final (refreshCode, providerCode) in [(1, 5), (2, 6), (4, 12), (5, 5), (6, 13), (7, 11), (8, 6)]) {
      final harness = _Harness(initialToken: _seed);
      final signals = <int>[];
      final subscription = harness.provider.authenticationFailures.listen(signals.add);
      final responses = <NativeTokenResult>[];
      harness.provider.request(responses.add, forceRefresh: true);
      harness.clock.runDue();
      harness.operation.complete(NativeTokenRefreshFailure(refreshCode));
      harness.clock.flush();
      expect((responses.single as NativeTokenFailure).code, providerCode);
      expect(harness.provider.peek(), same(_seed), reason: 'failure preserves a valid seed');
      final permanent = refreshCode == 2 || refreshCode == 8;
      expect(signals, permanent ? [6] : isEmpty);
      expect(harness.clock.nextDelayMilliseconds, permanent ? null : 5000);
      if (permanent) {
        harness.provider.request(responses.add, forceRefresh: true);
        harness.clock.runDue();
        expect(harness.operation.starts, 2);
      }
      subscription.cancel();
      harness.provider.close();
    }
  });

  test('An explicit refresh obeys the original strict cooldown gate and preserves scheduled retry', () {
    for (final scenario in fixture['cooldownCases'] as List) {
      final harness = _Harness();
      harness.clock.runDue();
      harness.operation.complete(const NativeTokenRefreshFailure(1));
      harness.clock.flush();
      // Inspect a delayed executor: time advances before its already queued work runs.
      harness.clock.nanoseconds += scenario['elapsedNanoseconds'] as int;
      if (scenario['active'] as bool) harness.clock.runDue();
      if (scenario['stopped'] as bool) harness.provider.close();
      final schedules = harness.clock.schedules;
      harness.provider.invalidate();
      harness.clock.flush();
      expect(harness.clock.schedules > schedules, scenario['scheduled']);
      harness.provider.close();
    }
  });

  test('Each waiting request gets thirty seconds and timeout does not abort the shared operation', () {
    final harness = _Harness();
    final early = <NativeTokenResult>[];
    final later = <NativeTokenResult>[];
    harness.provider.request(early.add);
    harness.clock.runDue();
    harness.clock.advanceMilliseconds(1000);
    harness.provider.request(later.add);
    harness.clock.advanceMilliseconds(28999);
    expect(early, isEmpty);
    harness.clock.advanceMilliseconds(1);
    expect((early.single as NativeTokenFailure).code, 5);
    expect(later, isEmpty);
    expect(harness.operation.cancels, 0);
    harness.operation.complete(const NativeTokenRefreshSuccess(_replacement));
    harness.clock.flush();
    expect(later.single, isA<NativeTokenSuccess>());
    expect(early, hasLength(1));
    harness.provider.close();
  });

  test('Invalidation hides cached data until a successful replacement and emits its own signal', () {
    final harness = _Harness(initialToken: _seed);
    var invalidations = 0;
    final subscription = harness.provider.invalidations.listen((_) { invalidations++; });
    harness.provider.invalidate();
    expect(harness.provider.peek(), isNull);
    harness.clock.flush();
    expect(invalidations, 1);
    harness.clock.runDue();
    harness.operation.complete(const NativeTokenRefreshFailure(2));
    harness.clock.flush();
    expect(harness.provider.peek(), isNull);
    final waiting = <NativeTokenResult>[];
    harness.provider.request(waiting.add);
    harness.clock.runDue();
    harness.operation.complete(const NativeTokenRefreshSuccess(_replacement));
    harness.clock.flush();
    expect(harness.provider.peek(), same(_replacement));
    expect(waiting.single, isA<NativeTokenSuccess>());
    subscription.cancel();
    harness.provider.close();
  });

  test('Close detaches observation, stops the owner, and completes pending subscribers with provider one', () {
    final harness = _Harness();
    final results = <NativeTokenResult>[];
    harness.provider.request(results.add);
    final cancel = harness.provider.request((_) => fail('Canceled close callback was invoked'));
    cancel();
    harness.clock.runDue();
    harness.provider.close();
    harness.provider.close();
    expect(harness.operation.events, ['start', 'cancel', 'stop']);
    harness.clock.flush();
    expect((results.single as NativeTokenFailure).code, 1);
    expect(harness.provider.peek(), isNull);
    harness.provider.request((_) => fail('Closed provider invoked a new request'));
    harness.clock.advanceMilliseconds(1000000);
    expect(harness.operation.starts, 1);

    final beforeStart = _Harness(initialToken: _seed);
    beforeStart.provider.close();
    beforeStart.clock.runDue();
    expect(beforeStart.operation.events, ['stop']);
  });
}

class _Harness {
  _Harness({NativeAccessToken? initialToken}) {
    operation = _Operation(clock);
    provider = NativeTokenProvider(operationFactory: () => operation,
      nowMicroseconds: () => clock.wallMicroseconds, nowNanoseconds: () => clock.nanoseconds,
      initialToken: initialToken, schedule: clock.schedule, execute: clock.execute);
  }
  final clock = _Clockwork();
  late final _Operation operation;
  late final NativeTokenProvider provider;
}

class _Operation implements NativeTokenRefreshOperation {
  _Operation(this.clock);
  final _Clockwork clock;
  final events = <String>[];
  void Function(NativeTokenRefreshResult)? pending;
  int starts = 0;
  int cancels = 0;

  @override
  NativeTokenCancel start(void Function(NativeTokenRefreshResult) callback) {
    expect(pending, isNull, reason: 'only one native refresh observation may be active');
    events.add('start');
    starts++;
    pending = callback;
    return () { cancels++; events.add('cancel'); pending = null; };
  }

  void complete(NativeTokenRefreshResult result) {
    final callback = pending!;
    pending = null;
    clock.execute(() => callback(result));
  }

  @override
  void stop() { events.add('stop'); pending = null; }
}

class _Clockwork {
  int nanoseconds = 0;
  int wallMicroseconds = 0;
  int schedules = 0;
  final tasks = <_Task>[];
  final callbacks = <void Function()>[];
  void execute(void Function() callback) => callbacks.add(callback);

  NativeTokenCancel schedule(Duration delay, void Function() callback) {
    schedules++;
    final task = _Task(nanoseconds + delay.inMicroseconds * 1000, callback);
    tasks.add(task);
    return () { task.cancelled = true; };
  }

  int? get nextDelayMilliseconds {
    final deadlines = tasks.where((task) => !task.cancelled).map((task) => task.deadline).toList()..sort();
    return deadlines.isEmpty ? null : (deadlines.first - nanoseconds) ~/ 1000000;
  }

  void flush() {
    while (callbacks.isNotEmpty) { callbacks.removeAt(0)(); }
  }

  void runDue() {
    while (true) {
      tasks.removeWhere((task) => task.cancelled);
      tasks.sort((a, b) => a.deadline.compareTo(b.deadline));
      if (tasks.isEmpty || tasks.first.deadline > nanoseconds) break;
      tasks.removeAt(0).callback();
      flush();
    }
    flush();
  }

  void advanceMilliseconds(int milliseconds) {
    nanoseconds += milliseconds * 1000000;
    wallMicroseconds += milliseconds * 1000;
    runDue();
  }
}

class _Task {
  _Task(this.deadline, this.callback);
  final int deadline;
  final void Function() callback;
  bool cancelled = false;
}
