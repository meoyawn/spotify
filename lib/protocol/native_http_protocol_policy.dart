import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';

import '../transport/quiche/client.dart' show Http3ConnectionException, Http3ConnectionFailure;
import 'request_builder.dart';

enum NativeHttpProtocol { http2, http3 }

/// Session-owned alternative-service state. Original default captures advertise
/// same-origin h3 before using it across multiple native request families.
/// Connection jobs race before application dispatch. Public Chromium151 Mac
/// defaults supply the wait rule; original captures prove H2 can win while
/// QUIC finishes for later reuse. Failed connection alternatives use the public
/// default cooldown and require a fresh advertisement after expiry. DNS HTTPS
/// records, network migration, feature overrides and persisted state are separate.
final class NativeHttpProtocolPolicy {
  NativeHttpProtocolPolicy({required this.nowMicroseconds, this.monotonicMicroseconds});
  final int Function() nowMicroseconds;
  final int Function()? monotonicMicroseconds;
  // Late fallback also gives already-live policy objects a monotonic clock on
  // hot reload, without retiring their existing advertisement/session state.
  late final _clock = Stopwatch()..start();
  int get _ticks => monotonicMicroseconds?.call() ?? _clock.elapsedMicroseconds;
  final _http3Until = <String, int>{};
  final _quicWorked = <Object>{};
  late final _brokenUntil = <Object, Map<String, int>>{};
  late final _brokenHistory = <Object, Map<String, int>>{};
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  int _generation = 0;

  Future<NativeHttpProtocol> selectReady(RequestEnvelope request, {
      required bool http3FieldsVerified, required Object connectionContext,
      required bool Function() http2Available, required bool Function() http3Available,
      required int? Function() smoothedRttMicroseconds,
      required Future<void> Function() prepareHttp2,
      required Future<void> Function() prepareHttp3, CancellationToken? cancellationToken}) async {
    final token = MergedCancellationToken([_token, if (request.cancellationToken != null) request.cancellationToken!,
      if (cancellationToken != null) cancellationToken]);
    token.throwIfCancelled();
    if (select(request, http3FieldsVerified: http3FieldsVerified,
        connectionContext: connectionContext) == NativeHttpProtocol.http2) {
      return NativeHttpProtocol.http2;
    }
    if (http3Available()) {
      _quicWorked.add(connectionContext);
      _confirm(connectionContext, _origin(request.url));
      return NativeHttpProtocol.http3;
    }
    final generation = _generation, origin = _origin(request.url);
    final decision = CancellableCompleter<NativeHttpProtocol>(token);
    Timer? mainTimer;
    var mainStarted = false, mainSucceeded = false, mainFailed = false, alternativeFailed = false;
    var brokenReported = false;
    Object? alternativeError;
    Object? mainError;
    StackTrace? mainStack;
    void reportBroken() {
      if (brokenReported || generation != _generation || !mainSucceeded ||
          !_canMarkBroken(alternativeError)) return;
      brokenReported = true;
      _markBroken(connectionContext, origin);
    }
    void startMain() {
      if (mainStarted || decision.isCompleted) return;
      mainStarted = true;
      Future<void>.sync(prepareHttp2).then((_) {
        mainSucceeded = true;
        if (alternativeFailed) reportBroken();
        if (!decision.isCompleted) decision.complete(NativeHttpProtocol.http2);
      }, onError: (Object error, StackTrace stack) {
        mainFailed = true; mainError = error; mainStack = stack;
        if (alternativeFailed && !decision.isCompleted) decision.completeError(error, stack);
      });
    }
    // macOS defaults: no extra feature delay, no delay with an available H2
    // session, and no remembered network/QUIC history on a new context. When
    // history exists, use1.5*SRTT (or300ms without stats), capped at3s.
    var waitMicros = 0;
    if (!http2Available() && _quicWorked.contains(connectionContext) &&
        !_wasRecentlyBroken(connectionContext, origin)) {
      final rtt = smoothedRttMicroseconds();
      waitMicros = rtt == null || rtt <= 0 ? 300000 : rtt * 3 ~/ 2;
      if (waitMicros > 3000000) waitMicros = 3000000;
    }
    Future<void>.sync(prepareHttp3).then((_) {
      if (generation == _generation) {
        _quicWorked.add(connectionContext);
        _confirm(connectionContext, origin);
      }
      if (!decision.isCompleted) decision.complete(NativeHttpProtocol.http3);
    }, onError: (Object error, StackTrace stack) {
      alternativeFailed = true;
      alternativeError = error;
      reportBroken();
      if (mainFailed) {
        if (!decision.isCompleted) decision.completeError(mainError ?? error, mainStack ?? stack);
      } else {
        mainTimer?.cancel();
        startMain();
      }
    });
    if (waitMicros == 0) { startMain(); }
    else { mainTimer = Timer(Duration(microseconds: waitMicros), startMain); }
    try { return await decision.future; }
    finally { mainTimer?.cancel(); }
  }

  NativeHttpProtocol select(RequestEnvelope request, {required bool http3FieldsVerified,
      Object? connectionContext}) {
    _expireBrokenAlternatives();
    if (!http3FieldsVerified) return NativeHttpProtocol.http2;
    final origin = _origin(request.url);
    if (connectionContext != null && (_brokenUntil[connectionContext]?.containsKey(origin) ?? false)) {
      return NativeHttpProtocol.http2;
    }
    final until = _http3Until[origin];
    if (until == null) return NativeHttpProtocol.http2;
    if (nowMicroseconds() >= until) {
      _http3Until.remove(origin);
      return NativeHttpProtocol.http2;
    }
    return NativeHttpProtocol.http3;
  }

  void observeResponse(String url, Map<String, String> headers) {
    _expireBrokenAlternatives();
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) return;
    final origin = _origin(url);
    final value = headers.entries.where((entry) => entry.key.toLowerCase() == 'alt-svc')
      .map((entry) => entry.value).firstOrNull;
    if (value == null) return;
    if (value.trim() == 'clear') { _http3Until.remove(origin); return; }
    // The observed authority is always ":443". Do not infer admission of
    // another host, port or the separately advertised h3-29 draft protocol.
    for (final alternative in value.split(',')) {
      final match = RegExp(r'^\s*h3=":([0-9]+)"((?:\s*;[^,]*)?)\s*$').firstMatch(alternative);
      if (match == null || int.tryParse(match[1]!) != uri.port) continue;
      final parameters = match[2]!.split(';').map((part) => part.trim()).where((part) => part.isNotEmpty);
      var seconds = 86400;
      for (final parameter in parameters) {
        if (parameter.startsWith('ma=')) {
          seconds = int.tryParse(parameter.substring(3)) ?? -1;
        }
      }
      if (seconds <= 0) { _http3Until.remove(origin); return; }
      final now = nowMicroseconds();
      final until = now + seconds * Duration.microsecondsPerSecond;
      if (until > now) _http3Until[origin] = until;
      return;
    }
  }

  // Only typed connection-job failures enter this state. HTTP statuses never
  // do. Same-host name errors, disconnected sockets and explicit client close
  // are distinct; TLS certificate/client-auth routing is not inferred from a
  // generic TLS failure. Local configuration/programming errors stay untyped.
  static bool _canMarkBroken(Object? error) => error is Http3ConnectionException &&
    const {Http3ConnectionFailure.timeout, Http3ConnectionFailure.nameResolutionFailed,
      Http3ConnectionFailure.socket, Http3ConnectionFailure.transport}.contains(error.failure);

  bool _wasRecentlyBroken(Object context, String origin) {
    final history = _brokenHistory[context];
    final count = history?.remove(origin);
    if (count == null) return false;
    history![origin] = count;
    return true;
  }

  void _markBroken(Object context, String origin) {
    _expireBrokenAlternatives();
    final history = _brokenHistory[context] ??= {};
    final priorCount = history.remove(origin) ?? 0;
    history[origin] = priorCount + 1;
    // Pinned HttpServerProperties bounds its recently-broken LRU at200.
    while (history.length > 200) { history.remove(history.keys.first); }
    final shift = priorCount > 18 ? 18 : priorCount;
    final seconds = 300 * (1 << shift);
    final delay = (seconds > 172800 ? 172800 : seconds) * Duration.microsecondsPerSecond;
    // An already-broken entry increments history but retains its first expiry.
    (_brokenUntil[context] ??= {}).putIfAbsent(origin, () => _ticks + delay);
  }

  void _confirm(Object context, String origin) {
    _expireBrokenAlternatives();
    if (_brokenUntil[context]?.containsKey(origin) ?? false) return;
    _brokenUntil[context]?.remove(origin);
    _brokenHistory[context]?.remove(origin);
  }

  void _expireBrokenAlternatives() {
    final now = _ticks;
    for (final broken in _brokenUntil.values) {
      final expired = broken.entries.where((entry) => now >= entry.value).map((entry) => entry.key).toList();
      for (final origin in expired) {
        broken.remove(origin);
        // HttpServerProperties' expiry delegate removes the failed Alt-Svc
        // mapping. A later actual response can advertise it afresh.
        _http3Until.remove(origin);
      }
    }
  }

  void clear() {
    _generation++;
    _cancellation?.cancel(); _cancellation = null;
    _quicWorked.clear(); _brokenUntil.clear(); _brokenHistory.clear(); _http3Until.clear();
  }
  static String _origin(String url) => Uri.parse(url).origin;
}
