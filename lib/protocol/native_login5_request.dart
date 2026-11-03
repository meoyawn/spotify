import 'native_http_defaults.dart';
import 'native_login5_credentials.dart';
import 'request_builder.dart';
import 'package:cancellation_token/cancellation_token.dart';
/// Shared owner counter at 0x1018ccf5c/0x1018ccfe8/0x1018cd03c.
/// The owner must supply its real monotonic clock in nanoseconds.
class NativeLogin5RetryCounter {
  NativeLogin5RetryCounter({required int Function() monotonicNowNanoseconds}) : _now = monotonicNowNanoseconds;
  final int Function() _now;
  int _count = 0, _timestamp = 0;

  int get currentCount {
    final now = _now();
    if (_count != 0 && now - _timestamp > 900000000) {
      _count = 0;
      _timestamp = now;
    }
    return _count;
  }

  void reset() {
    final now = _now();
    _count = 0;
    _timestamp = now;
  }

  void recordFailure() {
    final now = _now();
    _count = (_count + 1) & 0xffffffff;
    _timestamp = now;
  }
}

enum NativeLogin5Version { v3, v4 }

/// Explicit native category "http" failure, classified by the sender owner.
/// Arbitrary Dart cancellation must not be relabeled as native code 10.
class NativeLogin5HttpFailure implements Exception {
  const NativeLogin5HttpFailure(this.code);
  final int code;
}

class NativeLogin5RequestPlan {
  const NativeLogin5RequestPlan._(this.request);
  final RequestEnvelope request;

  /// Separate native setter 0x101c203a8(30000). Its backend interpretation is
  /// unestablished; it is not folded into the known 0x101c20378 timeout.
  int get option101c203a8 => 30000;
}

/// Application requests from 0x1018c02cc/0x1018c9b40 and send starts
/// 0x1018bc39c/0x1018c20bc. It has no sender, resending policy, or decoder.
class NativeLogin5RequestPlanner {
  NativeLogin5RequestPlanner({required this.counter, Map<String, String> inheritedHeaders = const {}})
    : _templateHeaders = Map.unmodifiable(nativeHeaderOverrides(inheritedHeaders, const {
        'Content-Type': 'application/x-protobuf', 'Cache-Control': 'no-cache, no-store, max-age=0'}));
  final NativeLogin5RetryCounter counter;
  final Map<String, String> _templateHeaders;

  NativeLogin5RequestPlan credentialsV3(NativeLogin5Credentials builder, NativeLogin5Credential credential) =>
    plan(version: NativeLogin5Version.v3, body: builder.encode(credential));

  /// A v4 body is supplied explicitly; no unverified v4 credential constructor
  /// or response schema is inferred from the matching HTTP template.
  NativeLogin5RequestPlan plan({required NativeLogin5Version version, required List<int> body,
      CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    final headers = nativeHeaderOverrides(_templateHeaders, {'X-Retry-Count': counter.currentCount.toString()});
    return NativeLogin5RequestPlan._(RequestEnvelope(method: 'POST',
      url: 'https://login5.spotify.com/${version.name}/login', headers: headers, body: body,
      authorize: false, responseType: 'bytes', nativeTimeoutMilliseconds: 30000,
      cancellationToken: cancellationToken));
  }

  /// Call after the standard parser reports success/failure, before backend
  /// dispatch. A parsed backend error/challenge still resets the counter.
  void recordHttpResponse({required int statusCode, required bool parsedNonemptyBody}) {
    if (statusCode == 200 && parsedNonemptyBody) {
      counter.reset();
    } else {
      counter.recordFailure();
    }
  }

  void recordTransportFailure(Object failure) {
    if (failure is NativeLogin5HttpFailure && failure.code == 10) return;
    counter.recordFailure();
  }
}
