import 'dart:async';
import 'dart:math' as math;

import 'package:cancellation_token/cancellation_token.dart';

typedef NativeTokenCancel = void Function();
typedef NativeTokenScheduler = NativeTokenCancel Function(Duration delay, void Function() callback);
typedef NativeTokenExecutor = void Function(void Function() callback);

class NativeAccessToken {
  const NativeAccessToken({required this.accessToken, required this.tokenType,
    required this.expiresAtMicroseconds});
  final String accessToken;
  final String tokenType;
  final int expiresAtMicroseconds;
}

sealed class NativeTokenRefreshResult {
  const NativeTokenRefreshResult();
}

class NativeTokenRefreshSuccess extends NativeTokenRefreshResult {
  const NativeTokenRefreshSuccess(this.token);
  final NativeAccessToken token;
}

class NativeTokenRefreshFailure extends NativeTokenRefreshResult {
  const NativeTokenRefreshFailure(this.code);
  /// The refresh-operation domain from native_oauth_refresh.dart.
  final int code;
}

/// The native refresh operation's start/stop ownership boundary. Implementations
/// deliver at most one result asynchronously per start. Cancellation detaches
/// that observation; stop must also abort owned work and prevent later commits.
/// A Future that merely ignores its result does not satisfy this interface.
abstract interface class NativeTokenRefreshOperation {
  NativeTokenCancel start(void Function(NativeTokenRefreshResult result) callback);
  void stop();
}

sealed class NativeTokenResult {
  const NativeTokenResult();
}

class NativeTokenSuccess extends NativeTokenResult {
  const NativeTokenSuccess(this.token);
  final NativeAccessToken token;
}

class NativeTokenFailure extends NativeTokenResult {
  const NativeTokenFailure(this.code);
  /// The provider domain from 0x10163df40, not the refresh-operation domain.
  final int code;
}

/// Cache, subscriber, and background-refresh ownership from 0x10163dc5c and
/// 0x10163f4c8. The operation factory must supply a real cancelable owner;
/// this component never creates a transport, accesses an account, or reads a store.
class NativeTokenProvider {
  NativeTokenProvider({required NativeTokenRefreshOperation Function() operationFactory,
    required this.nowMicroseconds, required this.nowNanoseconds,
    NativeAccessToken? initialToken, NativeTokenScheduler? schedule,
    NativeTokenExecutor? execute}) : _cached = initialToken,
      _schedule = schedule ?? _timer, _execute = execute ?? scheduleMicrotask {
    _operation = operationFactory();
    // The native refresh wrapper starts during construction, even with a seed.
    _requestRefresh();
  }

  final int Function() nowMicroseconds;
  final int Function() nowNanoseconds;
  final NativeTokenScheduler _schedule;
  final NativeTokenExecutor _execute;
  late final NativeTokenRefreshOperation _operation;
  NativeAccessToken? _cached;
  bool _invalidated = false;
  bool _refreshRequested = false;
  bool _running = false;
  bool _closed = false;
  bool _cooldown = false;
  int _lastFailureNanoseconds = 0;
  int _failureCount = 0;
  NativeTokenCancel? _refreshTimer;
  NativeTokenCancel? _observation;
  NativeTokenCancel? _waiterTimer;
  final List<_Subscriber> _subscribers = [];
  final _invalidations = StreamController<void>.broadcast(sync: true);
  final _authenticationFailures = StreamController<int>.broadcast(sync: true);

  Stream<void> get invalidations => _invalidations.stream;
  /// Native refresh errors 2/8 publish provider error 6 through this signal.
  Stream<int> get authenticationFailures => _authenticationFailures.stream;

  NativeAccessToken? peek() {
    if (_closed) return null;
    final now = nowMicroseconds();
    final token = _cached;
    return token != null && !_invalidated && now < token.expiresAtMicroseconds ? token : null;
  }

  /// Cancellation suppresses only this callback; it does not abort shared refresh.
  /// After close, native get returns an inert handle without invoking a callback.
  NativeTokenCancel request(void Function(NativeTokenResult result) callback, {bool forceRefresh = false}) {
    if (_closed) return () {};
    final token = forceRefresh ? null : peek();
    if (token != null) {
      final subscriber = _Subscriber(callback, 0);
      _deliver(subscriber, NativeTokenSuccess(token));
      return subscriber.cancel;
    }
    if (!_refreshRequested) {
      _refreshRequested = true;
      _requestRefresh();
    }
    final subscriber = _Subscriber(callback, _signed64(nowNanoseconds() + 30000000000));
    _subscribers.add(subscriber);
    if (_subscribers.length == 1) _scheduleWaiterCheck(30000);
    return subscriber.cancel;
  }

  void invalidate() {
    // The inspected native method does not gate this signal on stopped state.
    _invalidated = true;
    _refreshRequested = true;
    _requestRefresh();
    _execute(() { if (!_invalidations.isClosed) _invalidations.add(null); });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _refreshTimer?.call();
    _refreshTimer = null;
    _observation?.call();
    _observation = null;
    _operation.stop();
    _completeSubscribers(const NativeTokenFailure(1));
    // Signals remain subscribable, matching the retained native signal owners.
  }

  void _requestRefresh() {
    if (_cooldown && _signed64(nowNanoseconds() - _lastFailureNanoseconds) > 120000000000) {
      _cooldown = false;
    }
    if (_running || _closed || _cooldown) return;
    _scheduleRefresh(0);
  }

  void _scheduleRefresh(int milliseconds) {
    _refreshTimer?.call();
    _refreshTimer = _schedule(Duration(milliseconds: milliseconds), () {
      _refreshTimer = null;
      _cooldown = false;
      if (_closed || _running) return;
      _running = true;
      _observation = _operation.start(_received);
    });
  }

  void _received(NativeTokenRefreshResult result) {
    _running = false;
    _observation = null;
    final permanent = result is NativeTokenRefreshFailure && (result.code == 2 || result.code == 8);
    if (result is NativeTokenRefreshSuccess) {
      _cooldown = false;
    } else if (!permanent) {
      _cooldown = true;
      _lastFailureNanoseconds = nowNanoseconds();
    }
    if (_closed) return;
    final int delay;
    if (permanent) {
      delay = 0;
    } else if (result is NativeTokenRefreshSuccess) {
      _failureCount = 0;
      final remaining = _signed64(result.token.expiresAtMicroseconds - nowMicroseconds()) ~/ 1000;
      delay = math.max(remaining, 360000) - 300000;
    } else {
      _failureCount = (_failureCount + 1) & 0xffffffff;
      delay = _failureCount == 0 ? 0 : _failureCount >= 10 ? 60000 :
        (math.pow(math.pow(12, 1 / 9), _failureCount - 1) * 5000).truncate();
    }
    _execute(() => _publish(result));
    if (!permanent) _scheduleRefresh(delay);
  }

  void _publish(NativeTokenRefreshResult result) {
    _refreshRequested = false;
    if (result is NativeTokenRefreshSuccess) {
      _cached = result.token;
      _invalidated = false;
      _completeSubscribers(NativeTokenSuccess(result.token));
    } else if (result is NativeTokenRefreshFailure) {
      final code = switch (result.code) { 2 || 8 => 6, 4 => 12, 6 => 13, 7 => 11, _ => 5 };
      if (result.code == 2 || result.code == 8) {
        _execute(() => _authenticationFailures.add(6));
      }
      _completeSubscribers(NativeTokenFailure(code));
    }
  }

  void _completeSubscribers(NativeTokenResult result) {
    _waiterTimer?.call();
    _waiterTimer = null;
    final pending = List<_Subscriber>.of(_subscribers);
    _subscribers.clear();
    for (final subscriber in pending) {
      _deliver(subscriber, result);
    }
  }

  void _deliver(_Subscriber subscriber, NativeTokenResult result) {
    _execute(() {
      if (subscriber.cancelled || subscriber.delivered) return;
      subscriber.delivered = true;
      subscriber.callback(result);
    });
  }

  void _scheduleWaiterCheck(int milliseconds) {
    _waiterTimer = _schedule(Duration(milliseconds: milliseconds), () {
      _waiterTimer = null;
      final now = nowNanoseconds();
      while (_subscribers.isNotEmpty) {
        final remaining = _signed64(_subscribers.first.deadlineNanoseconds - now);
        if (remaining > 0) {
          _scheduleWaiterCheck((remaining + 999999) ~/ 1000000);
          return;
        }
        _deliver(_subscribers.removeAt(0), const NativeTokenFailure(5));
      }
    });
  }
}

class _Subscriber {
  _Subscriber(this.callback, this.deadlineNanoseconds);
  final void Function(NativeTokenResult result) callback;
  final int deadlineNanoseconds;
  final cancellationToken = CancellationToken();
  bool delivered = false;
  bool get cancelled => cancellationToken.isCancelled;
  void cancel() { cancellationToken.cancel(); }
}

int _signed64(int value) => value.toSigned(64);

NativeTokenCancel _timer(Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}
