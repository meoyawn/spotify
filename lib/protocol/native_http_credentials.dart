import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';

import 'native_client_token_provider.dart';
import 'native_http_defaults.dart';
import 'native_token_provider.dart';
import 'request_builder.dart';

/// Application credential decorators from 0x101a439ac and 0x101a4e0fc,
/// with response continuations 0x101a4f3f0 then 0x101a452ac.
/// Providers remain session-owned. Construction and bypassed requests never
/// acquire credentials; transport, redirects and retries belong to the sender.
class NativeHttpCredentials {
  const NativeHttpCredentials({required this.accessTokens, required this.clientTokens,
    this.loadAccessToken, this.invalidateAccessToken});
  final NativeTokenProvider accessTokens;
  final NativeClientTokenProvider clientTokens;
  /// The concrete session supplies its selected provider here and to the
  /// renderer's AccessTokenClient equivalent. Provider selection precedes HTTP.
  final Future<NativeAccessToken> Function({CancellationToken? cancellationToken})? loadAccessToken;
  /// Must invalidate the same session-selected provider used by loadAccessToken.
  final void Function()? invalidateAccessToken;

  /// True advances the original success continuation. False withholds both
  /// callbacks; the HTTP owner must retain cancellation, without replaying the
  /// request or inventing a response/postprocessing timeout.
  bool handleResponse({required String url, required int statusCode,
      required Map<String, String> headers}) {
    if (!handleClientTokenResponse(url: url, statusCode: statusCode, headers: headers)) return false;
    if (statusCode == 401) (invalidateAccessToken ?? accessTokens.invalidate)();
    return true;
  }

  /// PREAUTH installs only this response decorator. URL is the full resolved
  /// response URL from CEF/ Foundation, passed to the original host parser.
  bool handleClientTokenResponse({required String url, required int statusCode,
      required Map<String, String> headers}) {
    if (!clientTokens.isEnabled) return true;
    final token = clientTokens.peek();
    if (token != null) {
      final host = _nativeHost(url);
      if (!token.domains.any((domain) => host == domain || host.endsWith('.$domain'))) return true;
    }
    final value = nativeHeaderInsertions(headers, const {})['client-token-error'];
    if (value == null) return true;
    if (statusCode == 401 && value == 'EXPIRED_CLIENTTOKEN') {
      clientTokens.invalidate();
      return true;
    }
    final failure = switch ((statusCode, value)) {
      (401, 'MISSING_CLIENTTOKEN') => 103,
      (400, 'INVALID_CLIENTTOKEN') => 102,
      (403, 'UNSUPPORTED_CLIENT') => 104,
      _ => null,
    };
    if (failure != null) {
      // The explicit setter latches the error without clearing a usable cache.
      // Acquisition failure104 has a separate invalidation path in the owner.
      clientTokens.setFailure(NativeClientTokenFailure(failure));
      throw const NativeClientTokenFailure(1);
    }
    return false;
  }

  Future<RequestEnvelope> prepare(RequestEnvelope request) async =>
    withClientToken(await withAccessToken(request));

  Future<RequestEnvelope> withAccessToken(RequestEnvelope request) async {
    request.cancellationToken?.throwIfCancelled();
    final headers = nativeHeaderInsertions(request.headers, const {});
    if (headers.containsKey('Authorization') || _cacheOnly(headers) ||
        !_accessTokenHost(_nativeHost(request.url))) return request;
    final alternate = loadAccessToken;
    var token = alternate == null ? accessTokens.peek()
      : await alternate(cancellationToken: request.cancellationToken);
    if (token == null) {
      final result = Completer<NativeTokenResult>();
      final cancel = accessTokens.request(result.complete);
      final NativeTokenResult outcome;
      try { outcome = await result.future.asCancellable(request.cancellationToken); }
      finally { cancel(); }
      if (outcome is NativeTokenFailure) throw outcome;
      token = (outcome as NativeTokenSuccess).token;
    }
    return _headers(request, nativeHeaderInsertions(headers,
      {'Authorization': '${token.tokenType} ${token.accessToken}'}));
  }

  Future<RequestEnvelope> withClientToken(RequestEnvelope request) async {
    request.cancellationToken?.throwIfCancelled();
    final headers = nativeHeaderInsertions(request.headers, const {});
    if (headers.containsKey('client-token') || _cacheOnly(headers) ||
        !clientTokens.isEnabled) return request;
    var token = clientTokens.peek();
    if (token == null) {
      final result = Completer<NativeClientTokenResult>();
      final cancel = clientTokens.acquire(result.complete);
      final NativeClientTokenResult outcome;
      try { outcome = await result.future.asCancellable(request.cancellationToken); }
      finally { cancel(); }
      if (outcome is NativeClientTokenFailure) throw outcome;
      token = (outcome as NativeClientTokenSuccess).token;
    }
    final host = _nativeHost(request.url);
    if (!token.domains.any((domain) => host == domain || host.endsWith('.$domain'))) return request;
    return _headers(request, nativeHeaderInsertions(headers, {'client-token': token.token}));
  }
}

RequestEnvelope _headers(RequestEnvelope request, Map<String, String> headers) =>
  RequestEnvelope(method: request.method, url: request.url, headers: headers,
    body: request.body, authorize: request.authorize,
    includeCredentials: request.includeCredentials, responseType: request.responseType,
    nativeTimeoutMilliseconds: request.nativeTimeoutMilliseconds, cancellationToken: request.cancellationToken);

bool _accessTokenHost(String host) => host.endsWith('.spotify.com') ||
  host.endsWith('.spotify.net') || host == 'extended-metadata-cdn-fa.spotifycdn.com' ||
  host == 'traffic.megaphone.fm';

bool _cacheOnly(Map<String, String> headers) {
  final value = headers['Cache-Control'];
  if (value == null) return false;
  bool trim(int code) => code == 32 || code == 10 || code == 13;
  for (final token in value.split(',')) {
    var start = 0, end = token.length;
    while (start < end && trim(token.codeUnitAt(start))) { start++; }
    while (end > start && trim(token.codeUnitAt(end - 1))) { end--; }
    if (_asciiLower(token.substring(start, end)) == 'only-if-cached') return true;
  }
  return false;
}

/// 0x101c51cc0 retains host case and splits only '/' and ':'. It is not a
/// WHATWG/Uri parser. Keep its credential decision separate from transport URL
/// validation so normalization cannot expand the original credential scope.
String _nativeHost(String url) {
  final zero = url.indexOf('\u0000');
  if (zero >= 0) url = url.substring(0, zero);
  final prefix = _asciiLower(url);
  final int start;
  if (prefix.startsWith('https://')) { start = 8; }
  else if (prefix.startsWith('http://')) { start = 7; }
  else { return ''; }
  final slash = url.indexOf('/', start);
  final authority = url.substring(start, slash < 0 ? url.length : slash);
  final colon = authority.indexOf(':');
  if (colon < 0) return authority;
  // Native from_chars checks its error code, without requiring full port
  // consumption. A valid signed decimal prefix therefore retains the host.
  final port = RegExp(r'^-?[0-9]+').firstMatch(authority.substring(colon + 1))?.group(0);
  if (port == null) return '';
  final number = int.tryParse(port);
  if (number == null || number < -0x80000000 || number > 0x7fffffff) return '';
  return authority.substring(0, colon);
}

String _asciiLower(String value) => String.fromCharCodes(value.codeUnits.map(
  (code) => code >= 65 && code <= 90 ? code + 32 : code));
