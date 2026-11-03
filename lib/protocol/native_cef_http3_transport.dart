import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../diagnostics/http_status_log.dart';
import '../transport/quiche/client.dart';
import 'native_cef_context.dart';
import 'native_cef_http_request.dart';
import 'native_cef_request.dart';
import 'native_cef_response.dart';
import 'native_http_defaults.dart';
import 'request_builder.dart';

/// Native application fields carried over standard quiche HTTP/3. Original
/// music-key/storage captures establish decoded fields, not Chromium-equivalent
/// TLS, QUIC, QPACK, packet ordering or connection-selection behavior.
class NativeCefHttp3Transport {
  NativeCefHttp3Transport({required this.defaults, required this.options,
    required this.adapterUserAgent, required this.context, required this.client,
    this.admitRemoteRequest});

  final NativeHttpDefaults defaults;
  final NativeCefOptions options;
  final String adapterUserAgent;
  final NativeCefContext context;
  final QuicheHttp3Client client;
  final bool Function(RequestEnvelope request)? admitRemoteRequest;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  bool _closed = false;

  Future<http.Response> send(RequestEnvelope envelope, {CancellationToken? cancellationToken}) async =>
    http.Response.fromStream(await sendStream(envelope, cancellationToken: cancellationToken));

  Future<http.StreamedResponse> sendStream(RequestEnvelope envelope,
      {CancellationToken? cancellationToken}) =>
    HttpStatusLog.observe(method: envelope.method, url: envelope.url, transport: 'h3',
      send: () => _sendStream(envelope, cancellationToken: cancellationToken));

  Future<http.StreamedResponse> _sendStream(RequestEnvelope envelope,
      {CancellationToken? cancellationToken}) async {
    if (_closed) throw StateError('Native CEF H3 transport is closed');
    final token = MergedCancellationToken([_token,
      if (envelope.cancellationToken != null) envelope.cancellationToken!,
      if (cancellationToken != null) cancellationToken]);
    token.throwIfCancelled();
    final plan = defaults.prepareCefNetwork(envelope, options: options,
      adapterUserAgent: adapterUserAgent, context: context);
    final uri = Uri.parse(plan.url);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasFragment ||
        (uri.host != 'localhost' && !(admitRemoteRequest?.call(envelope) ?? false))) {
      throw StateError('Remote native CEF H3 transport is unverified. No request was sent.');
    }
    var headers = <String, String>{};
    for (final entry in plan.headers) {
      final name = entry.key.toLowerCase();
      if (const {'host', 'connection', 'keep-alive', 'proxy-connection',
          'transfer-encoding', 'upgrade'}.contains(name)) continue;
      if (name == 'priority' && entry.value != 'u=4, i') {
        throw UnsupportedError('Native CEF H3 requires the captured priority field');
      }
      headers[name] = entry.value;
    }
    headers.putIfAbsent('priority', () => 'u=4, i');
    // Original H3 music/storage captures retain this decoded field sequence.
    // The general CEF field plan puts its fallback User-Agent first; that
    // ordering is not the captured native application's explicit app group.
    if (headers['app-platform'] == 'OSX_ARM64' && headers['spotify-app-version'] == '130601921' &&
        (headers['user-agent'] ?? '').startsWith('Spotify/130601921 OSX_ARM64/OS X ')) {
      final ordered = <String, String>{};
      final connectPut = plan.method == 'PUT' &&
        RegExp(r'^/connect-state/v1/devices/[A-Za-z0-9._~-]+$').hasMatch(plan.rawTarget);
      // The captured original native Connect H3 profile omits Content-Length;
      // stream completion frames the body. The generic HTTP/1 field plan's
      // fixed-length upload field must not leak into this captured H3 profile.
      if (connectPut) headers.remove('content-length');
      final metadataPost = plan.method == 'POST' &&
        plan.rawTarget == '/extended-metadata/v0/extended-metadata';
      final sequence = connectPut ? const ['accept-language', 'app-platform', 'authorization',
        'content-encoding', 'content-type', 'spotify-app-version', 'time-zone',
        'user-agent', 'x-spotify-connection-id', 'client-token'] :
        metadataPost ? const ['content-length', 'accept', 'accept-language',
          'app-platform', 'authorization', 'content-encoding', 'content-type',
          'spotify-app-version', 'time-zone', 'user-agent', 'client-feature-id', 'client-token'] :
        const ['content-length', 'pragma', 'cache-control', 'accept-language',
          'app-platform', 'authorization', 'spotify-app-version', 'time-zone', 'user-agent', 'client-token'];
      for (final name in sequence) {
        final value = headers.remove(name);
        if (value != null) ordered[name] = value;
      }
      headers = ordered..addAll(headers);
    }
    final response = await client.sendEnvelopeStream(RequestEnvelope(method: plan.method,
      url: plan.url, headers: headers, body: plan.body, authorize: false,
      responseType: 'bytes', nativeTimeoutMilliseconds: envelope.nativeTimeoutMilliseconds,
      cancellationToken: token));
    return decodeNativeCefResponse(http.StreamedResponse(response.stream, response.statusCode,
        headers: response.headers, contentLength: response.contentLength,
        request: response.request, reasonPhrase: response.reasonPhrase,
        isRedirect: response.isRedirect, persistentConnection: response.persistentConnection));
  }

  /// Abort only this adapter's requests. The injected shared pool belongs to
  /// its caller and remains available to other adapters.
  void close() {
    if (_closed) return;
    _closed = true;
    _token.cancel(http.RequestAbortedException());
  }
}
