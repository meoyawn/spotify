import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import 'native_renderer_http_request.dart';

/// Renderer-context preflight permissions. The original starts independent
/// OPTIONS for concurrent misses, then caches accepted response permissions.
/// This is separate from response-content caching and native CEF URLRequest.
final class NativeRendererCors {
  NativeRendererCors({required this.nowMicroseconds});
  final int Function() nowMicroseconds;
  final _permissions = <String, _CorsPermission>{};
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();

  Future<http.StreamedResponse> send(NativeRendererHttpRequestPlan request, {
      required NativeRendererSearchProfile profile,
      CancellationToken? cancellationToken,
      required Future<http.StreamedResponse> Function(NativeRendererHttpRequestPlan, CancellationToken) sendPrepared}) async {
    final token = MergedCancellationToken([_token, ?cancellationToken]);
    token.throwIfCancelled();
    final names = profile.preflightHeaderNames(request);
    final cached = _permissions[request.url];
    if (cached == null || !cached.allows(names, nowMicroseconds())) {
      _permissions.remove(request.url);
      final response = await sendPrepared(profile.preparePreflight(request), token);
      try {
        token.throwIfCancelled();
        final permission = _CorsPermission.fromResponse(response, nowMicroseconds());
        if (!permission.allows(names, nowMicroseconds(), checkExpiry: false)) {
          throw const RendererCorsException('Spotify did not permit the renderer request headers');
        }
        _permissions[request.url] = permission;
      } finally {
        // The original releases its preflight callback on accepted headers,
        // before the zero-limit SimpleURLLoader body completion callback.
        // Drain without retaining bytes or delaying the actual request.
        unawaited(response.stream.drain<void>().catchError((Object _) {}));
      }
    }
    token.throwIfCancelled();
    return sendPrepared(request, token);
  }

  void clear() { _cancellation?.cancel(); _cancellation = null; _permissions.clear(); }
}

final class _CorsPermission {
  _CorsPermission(this.headers, this.expiresAt);
  final Set<String> headers;
  final int expiresAt;

  factory _CorsPermission.fromResponse(http.StreamedResponse response, int now) {
    final fields = {for (final entry in response.headers.entries) entry.key.toLowerCase(): entry.value};
    if (response.statusCode < 200 || response.statusCode >= 300 ||
        !const {NativeRendererSearchProfile.origin, '*'}.contains(fields['access-control-allow-origin'])) {
      throw const RendererCorsException('Spotify did not permit the renderer origin');
    }
    // GET and POST are CORS-safelisted, but malformed allow-method/header lists still
    // fail the original public PreflightResult parser. Credentials are omitted
    // for this cross-origin same-origin-mode fetch; no cookies are sent.
    _tokens(fields['access-control-allow-methods'], lower: false);
    final headers = _tokens(fields['access-control-allow-headers'], lower: true);
    final rawAge = fields['access-control-max-age'];
    final parsedAge = rawAge != null && RegExp(r'^[+-]?[0-9]+$').hasMatch(rawAge)
      ? int.tryParse(rawAge) : null;
    var seconds = parsedAge ?? 5;
    if (seconds < 0) seconds = 0;
    if (seconds > 7200) seconds = 7200;
    return _CorsPermission(headers, now + seconds * Duration.microsecondsPerSecond);
  }

  bool allows(List<String> names, int now, {bool checkExpiry = true}) {
    if (checkExpiry && expiresAt <= now) return false;
    // Authorization never inherits wildcard permission in Chromium151's
    // non-wildcard-header check, including on a cached result.
    return names.every((name) => headers.contains(name) || name != 'authorization' && headers.contains('*'));
  }
}

Set<String> _tokens(String? field, {required bool lower}) {
  final result = <String>{};
  for (final raw in (field ?? '').split(',')) {
    final token = raw.trim();
    if (token.isEmpty) continue;
    if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(token)) {
      throw const RendererCorsException('Spotify returned invalid renderer permissions');
    }
    result.add(lower ? token.toLowerCase() : token);
  }
  return result;
}

final class RendererCorsException implements Exception {
  const RendererCorsException(this.message);
  final String message;
  @override String toString() => message;
}
