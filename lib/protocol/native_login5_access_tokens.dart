import 'dart:async';

import 'native_login5_exchange.dart';
import 'native_login5_response.dart';
import 'native_token_provider.dart';

/// Session-owned Login5 token acquisition. The native Login5 cache gate
/// (1018e7d7c) requires a nonempty token with expiry strictly after wall time;
/// Accounts' seeded/background-refresh provider is a separate owner.
///
/// The caller supplies the verified credential, request/exchange and persistence
/// boundaries. This cache adds no HTTP request, retry or credential conversion.
class NativeLogin5AccessTokens {
  NativeLogin5AccessTokens({required this.start, required this.nowMicroseconds,
    required this.onSuccess});
  final NativeLogin5V3Run Function() start;
  final int Function() nowMicroseconds;
  final FutureOr<void> Function(NativeLogin5Success value) onSuccess;
  NativeAccessToken? _cached;
  Future<NativeAccessToken>? _pending;
  NativeLogin5V3Run? _run;
  bool _closed = false;

  NativeAccessToken? peek() {
    final token = _cached;
    return !_closed && token != null && token.accessToken.isNotEmpty &&
      token.expiresAtMicroseconds > nowMicroseconds() ? token : null;
  }

  Future<NativeAccessToken> acquire() {
    if (_closed) return Future.error(StateError('Native Spotify token owner is closed'));
    final cached = peek();
    if (cached != null) return Future.value(cached);
    final pending = _pending;
    if (pending != null) return pending;
    late final Future<NativeAccessToken> job;
    job = _acquire().whenComplete(() {
      if (identical(_pending, job)) _pending = null;
    });
    _pending = job;
    return job;
  }

  Future<NativeAccessToken> _acquire() async {
    final run = _run = start();
    try {
      final result = await run.result;
      if (_closed || !identical(_run, run)) throw StateError('Native Spotify session changed');
      if (result is! NativeLogin5Success) throw result;
      final token = NativeAccessToken(accessToken: result.accessToken,
        tokenType: result.tokenType, expiresAtMicroseconds: result.expiresAtMicroseconds);
      await onSuccess(result);
      if (_closed || !identical(_run, run)) throw StateError('Native Spotify session changed');
      _cached = token;
      return token;
    } finally {
      if (identical(_run, run)) _run = null;
    }
  }

  void invalidate() { _cached = null; }
  void close() {
    if (_closed) return;
    _closed = true;
    _cached = null;
    final run = _run;
    _run = null;
    run?.cancel();
  }
}
