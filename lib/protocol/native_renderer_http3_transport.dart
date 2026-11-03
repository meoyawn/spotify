import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../diagnostics/http_status_log.dart';
import '../transport/quiche/client.dart';
import 'native_cef_response.dart';
import 'native_renderer_http_request.dart';
import 'request_builder.dart';

/// Original renderer Pathfinder fields and body carried over standard quiche
/// HTTP/3. Original captures establish decoded HTTP fields, not Chromium TLS,
/// QUIC or QPACK bytes. NetLog transaction/header-block joins additionally
/// establish the shared request plan's encoder-input field ordering.
class NativeRendererHttp3Transport {
  NativeRendererHttp3Transport({required this.profile, required this.clientToken,
    required this.client, this.admitRemoteRequest});

  final NativeRendererSearchProfile profile;
  final FutureOr<String> Function() clientToken;
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

  Future<http.StreamedResponse> sendPrepared(NativeRendererHttpRequestPlan plan,
      {int? nativeTimeoutMilliseconds, CancellationToken? cancellationToken}) =>
    HttpStatusLog.observe(method: plan.method, url: plan.url, transport: 'h3',
      send: () => _dispatch(() => plan, nativeTimeoutMilliseconds, cancellationToken));

  Future<http.StreamedResponse> _sendStream(RequestEnvelope envelope,
      {CancellationToken? cancellationToken}) =>
    _dispatch(() async => profile.prepareSearch(envelope, clientToken: await clientToken()),
      envelope.nativeTimeoutMilliseconds, MergedCancellationToken([
        if (envelope.cancellationToken != null) envelope.cancellationToken!,
        if (cancellationToken != null) cancellationToken]));

  Future<http.StreamedResponse> _dispatch(FutureOr<NativeRendererHttpRequestPlan> Function() prepare,
      int? nativeTimeoutMilliseconds, CancellationToken? cancellationToken) async {
    if (_closed) throw StateError('Renderer H3 transport is closed');
    final token = MergedCancellationToken([_token, if (cancellationToken != null) cancellationToken]);
    final plan = await CancellableFuture.sync(prepare, token);
    token.throwIfCancelled();
      final uri = Uri.parse(plan.url);
      if (uri.host != 'localhost' && !(admitRemoteRequest?.call(RequestEnvelope(method: plan.method,
          url: plan.url, headers: plan.headers, body: plan.body, authorize: false, responseType: 'bytes')) ?? false)) {
        throw StateError('Renderer endpoint is not admitted. No request was sent.');
      }
      final response = await client.sendEnvelopeStream(RequestEnvelope(method: plan.method,
        url: plan.url, headers: plan.headers, body: plan.body, authorize: false,
        responseType: 'bytes', nativeTimeoutMilliseconds: nativeTimeoutMilliseconds,
        cancellationToken: token));
      return decodeNativeCefResponse(http.StreamedResponse(response.stream, response.statusCode,
        headers: response.headers, contentLength: response.contentLength,
        request: response.request, reasonPhrase: response.reasonPhrase,
        isRedirect: response.isRedirect, persistentConnection: response.persistentConnection));
  }

  /// Abort this adapter's requests while retaining its caller's shared client.
  void close() {
    if (_closed) return;
    _closed = true;
    _token.cancel(http.RequestAbortedException());
  }
}
