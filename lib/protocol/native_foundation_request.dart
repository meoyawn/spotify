import 'dart:typed_data';

import 'request_builder.dart';

/// Inputs consumed by Spotify's Foundation adapter at 0x1017e03c4.
/// These are native request options, independent of renderer credentials and
/// response decoding. The owner supplies the established per-request values.
class NativeFoundationOptions {
  const NativeFoundationOptions({required this.timeoutMilliseconds,
    required this.trafficClass, this.cachePolicyOverride = 0});
  final int timeoutMilliseconds;
  final int trafficClass;
  final int cachePolicyOverride;
}

/// Pure Dart port of Spotify's application-level Foundation conversion.
/// Values describe calls into the standard API, before NSURL/CFNetwork URL,
/// header, cache and transport processing. This plan never opens a connection.
class NativeFoundationRequestPlan {
  NativeFoundationRequestPlan._({required this.urlInput, required this.method,
    required this.headers, required this.body, required this.cachePolicy,
    required this.timeoutSeconds, required this.networkServiceType});

  factory NativeFoundationRequestPlan.fromRequest(RequestEnvelope request,
      {required NativeFoundationOptions options}) {
    final override = options.cachePolicyOverride & 0xff;
    final int policy;
    if (override >= 1 && override <= 4) {
      policy = const [1, 5, 2, 3][override - 1];
    } else {
      String? cacheControl;
      var hasRange = false;
      for (final entry in request.headers.entries) {
        if (_asciiLower(entry.key) == 'cache-control') cacheControl ??= entry.value;
        if (_asciiLower(entry.key) == 'range') hasRange = true;
      }
      policy = cacheControl != null && _onlyIfCached(cacheControl) ? 3 : hasRange ? 1 : 0;
    }
    return NativeFoundationRequestPlan._(
      urlInput: _cstring(request.url), method: request.method,
      headers: List.unmodifiable(request.headers.entries.map(
        (entry) => MapEntry(_cstring(entry.key), _cstring(entry.value)))),
      body: request.body.isEmpty ? null : request.body,
      cachePolicy: policy,
      timeoutSeconds: (request.nativeTimeoutMilliseconds ?? options.timeoutMilliseconds) / 1000.0,
      networkServiceType: (options.trafficClass & 0xffffffff) == 0 ? 3 : null,
    );
  }

  final String urlInput;
  final String method;
  final List<MapEntry<String, String>> headers;
  final Uint8List? body;

  /// Standard NSURLRequestCachePolicy value selected by the original adapter.
  final int cachePolicy;
  final double timeoutSeconds;

  /// Null preserves the standard API's default. Native class zero sets the
  /// standard background network service type (3).
  final int? networkServiceType;
}

String _cstring(String value) {
  final zero = value.indexOf('\u0000');
  return zero < 0 ? value : value.substring(0, zero);
}

String _asciiLower(String value) => String.fromCharCodes(value.codeUnits.map(
  (code) => code >= 65 && code <= 90 ? code + 32 : code));

bool _onlyIfCached(String value) {
  // Original tokenizer 0x101c50260 trims SP, CR and LF. TAB is retained.
  bool whitespace(int code) => code == 0x20 || code == 0x0a || code == 0x0d;
  for (final token in value.split(',')) {
    var start = 0, end = token.length;
    while (start < end && whitespace(token.codeUnitAt(start))) { start++; }
    while (end > start && whitespace(token.codeUnitAt(end - 1))) { end--; }
    if (_asciiLower(token.substring(start, end)) == 'only-if-cached') return true;
  }
  return false;
}
