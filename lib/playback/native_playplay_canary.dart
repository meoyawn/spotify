import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/request_builder.dart';
import 'native_playplay_body.dart';
import 'native_playplay_request.dart';

/// Original100488160 identity and100488d98 body. The supplied properties belong
/// to the authenticated product-state owner; no property is rewritten here.
final class NativePlayPlayCanaryRequest {
  NativePlayPlayCanaryRequest({required RequestEnvelope template,
    required Map<String, String> productState, required int timestampSeconds}) {
    final key = productState['strider-key'] ?? '';
    final keyBytes = utf8.encode(key);
    final signed = '${productState['ads'] ?? '1'}${productState['type'] ?? ''}'
      '${keyBytes.length == 11 ? productState['player-license'] ?? '' : ''}'
      '${productState['feature-set-id-masked'] ?? ''}';
    final expected = crypto.sha1.convert(utf8.encode(signed)).toString();
    final valid = key == expected.substring(0, min(keyBytes.length, 40));
    // Original100487b48 returns0 on every ordinary return in this pinned
    // desktop build, including its diagnostic detection branch. No detector
    // result or account permission is synthesized from the Flutter process.
    final prefix = valid ? 'ok' : 'mod';
    final identity = crypto.sha1.convert(utf8.encode('$prefix$timestampSeconds')).bytes;
    request = NativePlayPlayRequestPlan.musicKey(template: template, fileId20: identity,
      serializedBody: NativePlayPlayLicenseBody(cacheId: const [],
        timestampSeconds: timestampSeconds, nativeInteractivity: 2).encode()).request;
  }

  late final RequestEnvelope request;
}

/// Authenticated-scope AppIntegrity owner: an audio-start event checks cadence;
/// an eligible check posts one delayed request. HTTP replies adjust the next
/// event's eligibility, without starting an independent polling/retry loop.
final class NativePlayPlayCanary {
  NativePlayPlayCanary({required this.template, required this.productState,
    required this.monotonicNanoseconds, required this.timestampSeconds,
    required this.isReady, required this.send});

  final RequestEnvelope template;
  final Map<String, String> Function() productState;
  final int Function() monotonicNanoseconds, timestampSeconds;
  final bool Function() isReady;
  final Future<http.Response> Function(RequestEnvelope) send;
  CancellationToken? _pendingStart, _cancellation;
  CancellationToken get _token => _cancellation ??= MergedCancellationToken([?template.cancellationToken]);
  int? _lastAttemptNs;
  bool get _closed => _token.isCancelled;
  int requests = 0;
  int? lastStatus;

  void onAudioStarted() {
    if (_closed || !isReady() || _pendingStart != null) return;
    final last = _lastAttemptNs;
    if (last != null && monotonicNanoseconds() - last <= 1799999999999) return;
    final pending = _pendingStart = CancellationToken();
    final token = MergedCancellationToken([_token, pending]);
    Future<void> begin() async {
      try {
        await CancellableFuture.delayed<void>(const Duration(milliseconds: 250), token);
        if (identical(_pendingStart, pending)) _pendingStart = null;
        token.throwIfCancelled();
        if (isReady()) await _request(token);
      } catch (error) {
        if (!token.isCancelled) rethrow;
      } finally { if (identical(_pendingStart, pending)) _pendingStart = null; }
    }
    unawaited(begin());
  }

  Future<void> _request(CancellationToken token) async {
    token.throwIfCancelled();
    _lastAttemptNs = monotonicNanoseconds();
    try {
      final plan = NativePlayPlayCanaryRequest(template: template,
        productState: productState(), timestampSeconds: timestampSeconds());
      requests++;
      final response = await send(plan.request.withCancellation(token)).asCancellable(token);
      if (_closed) return;
      lastStatus = response.statusCode;
      if (response.statusCode >= 500) {
        _lastAttemptNs = null;
      } else if (response.statusCode >= 400) {
        _lastAttemptNs = monotonicNanoseconds() - 1500000000000;
      }
    } catch (_) {
      if (!token.isCancelled) _lastAttemptNs = null;
    }
  }

  void close() {
    _token.cancel();
    _pendingStart?.cancel();
    _pendingStart = null;
  }
}
