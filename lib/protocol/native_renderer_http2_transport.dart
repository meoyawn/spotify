import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';
import 'package:http2/transport.dart' as h2;

import '../diagnostics/http_status_log.dart';
import '../async/cancellation.dart';
import 'native_cef_http2_pool.dart';
import 'native_cef_response.dart';
import 'native_http2_priority.dart';
import 'native_renderer_http_request.dart';
import 'request_builder.dart';

/// Original renderer method/target/fields/body over standard Dart H2. Decoded
/// order and same-session reuse are backed by original H2 captures; TLS/HPACK,
/// preflights and protocol-selection parity remain separate. No redirects.
class NativeRendererHttp2Transport {
  NativeRendererHttp2Transport({required this.profile, required this.clientToken,
    this.admitRemoteRequest, SecurityContext? securityContext, NativeCefHttp2Pool? pool})
      : _securityContext = securityContext, _sharedPool = pool;
  final NativeRendererSearchProfile profile;
  final FutureOr<String> Function() clientToken;
  final bool Function(RequestEnvelope request)? admitRemoteRequest;
  final SecurityContext? _securityContext;
  final NativeCefHttp2Pool? _sharedPool;
  NativeCefHttp2Pool? _ownedPool;
  NativeCefHttp2Pool get _pool => _sharedPool ?? (_ownedPool ??= NativeCefHttp2Pool(securityContext: _securityContext));
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  bool _closed = false;

  Future<http.Response> send(RequestEnvelope envelope) async =>
    http.Response.fromStream(await sendStream(envelope));

  Future<http.StreamedResponse> sendStream(RequestEnvelope envelope) =>
    HttpStatusLog.observe(method: envelope.method, url: envelope.url, transport: 'h2-renderer',
      send: () => _sendStream(envelope));

  Future<http.StreamedResponse> sendPrepared(NativeRendererHttpRequestPlan plan,
      {int? nativeTimeoutMilliseconds, CancellationToken? cancellationToken}) =>
    HttpStatusLog.observe(method: plan.method, url: plan.url, transport: 'h2-renderer',
      send: () {
        final token = MergedCancellationToken([_token, ?cancellationToken]);
        token.throwIfCancelled();
        return _sendPrepared(plan, nativeTimeoutMilliseconds, token).asCancellable(token);
      });

  Future<http.StreamedResponse> _sendStream(RequestEnvelope envelope) async {
    if (_closed) throw StateError('Renderer Search H2 transport is closed');
    final token = MergedCancellationToken([_token, ?envelope.cancellationToken]);
    final client = await CancellableFuture.sync(clientToken, token);
    token.throwIfCancelled();
    final plan = profile.prepareSearch(envelope, clientToken: client);
    return _sendPrepared(plan, envelope.nativeTimeoutMilliseconds, token).asCancellable(token);
  }

  Future<http.StreamedResponse> _sendPrepared(NativeRendererHttpRequestPlan plan,
      int? nativeTimeoutMilliseconds, CancellationToken token) async {
    token.throwIfCancelled();
    final parsed = Uri.parse(plan.url);
    final loopback = const {'localhost', '127.0.0.1'}.contains(parsed.host);
    if (!loopback && !(admitRemoteRequest?.call(RequestEnvelope(method: plan.method,
        url: plan.url, headers: plan.headers, body: plan.body, authorize: false, responseType: 'bytes')) ?? false)) {
      throw StateError('Renderer Search endpoint is not admitted. No request was sent.');
    }
    final timeout = Duration(milliseconds: nativeTimeoutMilliseconds ?? 30000);
    NativeCefHttp2Lease? lease;
    h2.ClientTransportStream? activeStream;
    StreamSubscription<h2.StreamMessage>? subscription;
    StreamController<List<int>>? responseBody;
    final response = Completer<http.StreamedResponse>();
    response.future.ignore();
    var headersDelivered = false;
    var released = false;
    late final void Function() abort;
    late final CancellationRegistration cancellation;
    void release() {
      if (released) return;
      released = true;
      cancellation.dispose();
      lease?.release();
    }
    abort = () {
      if (released) return;
      final error = http.RequestAbortedException();
      activeStream?.terminate();
      unawaited(subscription?.cancel());
      if (headersDelivered) { responseBody?.addError(error); unawaited(responseBody?.close()); }
      else if (!response.isCompleted) { response.completeError(error); }
      release();
    };
    cancellation = CancellationRegistration(token, onCancel: (_) => abort());
    try {
      token.throwIfCancelled();
      lease = await _pool.acquire(parsed, timeout);
      if (_closed || released || token.isCancelled) {
        lease.release();
        throw http.RequestAbortedException();
      }
      final connection = lease.connection;
      // The shared plan owns original POST/OPTIONS field ordering for H2/H3.
      final stream = lease.makeRequest([
        h2.Header.ascii(':method', plan.method), h2.Header.ascii(':authority', plan.authority),
        h2.Header.ascii(':scheme', 'https'), h2.Header.ascii(':path', plan.rawTarget),
        for (final header in plan.headers.entries)
          h2.Header.ascii(header.key, header.value),
      ], endStream: plan.body.isEmpty,
        priorityBand: NativeHttp2PriorityDependencies.rendererPriorityBand);
      activeStream = stream;
      if (plan.body.isNotEmpty) stream.sendData(plan.body, endStream: true);
      final body = StreamController<List<int>>(
        onPause: () => subscription?.pause(), onResume: () => subscription?.resume(),
        onCancel: () async { stream.terminate(); await subscription?.cancel(); release(); });
      responseBody = body;
      final responseHeaders = <String, String>{};
      subscription = stream.incomingMessages.listen((message) {
        if (message is h2.HeadersStreamMessage) {
          int? status;
          for (final header in message.headers) {
            final name = latin1.decode(header.name), value = latin1.decode(header.value);
            if (name == ':status') { status = int.tryParse(value); }
            else { responseHeaders.update(name, (old) => '$old,$value', ifAbsent: () => value); }
          }
          if (status != null && status >= 200 && !response.isCompleted) {
            headersDelivered = true;
            response.complete(decodeNativeCefResponse(http.StreamedResponse(body.stream, status,
              headers: responseHeaders, contentLength: int.tryParse(responseHeaders['content-length'] ?? ''),
              isRedirect: const {301, 302, 303, 307, 308}.contains(status), persistentConnection: true)));
          }
        } else if (message is h2.DataStreamMessage) { body.add(message.bytes); }
      }, onError: (Object error, StackTrace stack) {
        if (!response.isCompleted) { response.completeError(error, stack); }
        else { body.addError(error, stack); }
        if (!connection.isOpen) lease?.markFailed();
        unawaited(body.close()); release();
      }, onDone: () {
        if (!response.isCompleted) response.completeError(const HttpException('H2 stream ended before response status'));
        unawaited(body.close()); release();
      });
      return await response.future.timeout(timeout, onTimeout: () {
        stream.terminate(); release();
        throw TimeoutException('Renderer Search response header deadline', timeout);
      });
    } catch (_) { activeStream?.terminate(); release(); rethrow; }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _token.cancel(http.RequestAbortedException());
    _ownedPool?.close(); _ownedPool = null;
  }
}
