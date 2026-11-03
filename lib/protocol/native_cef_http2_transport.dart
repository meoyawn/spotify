import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';
import 'package:http2/transport.dart' as h2;

import '../diagnostics/http_status_log.dart';
import '../async/cancellation.dart';
import 'native_cef_context.dart';
import 'native_cef_http_request.dart';
import 'native_cef_http2_pool.dart';
import 'native_cef_request.dart';
import 'native_cef_response.dart';
import 'native_http_defaults.dart';
import 'native_http2_priority.dart';
import 'request_builder.dart';

/// Decoded H2 fields verified against the shipped native-context CEF captures.
/// The standard Dart http2 package owns HPACK/frames/flow control. Remote
/// routes require explicit admission. The session can supply a shared pool;
/// TLS/H2 packet fingerprint matching remains outside this primitive.
class NativeCefHttp2Transport {
  NativeCefHttp2Transport({required this.defaults, required this.options,
    required this.adapterUserAgent, required this.context,
    SecurityContext? securityContext, NativeCefHttp2Pool? pool,
    this.admitRemoteRequest}) : _securityContext = securityContext, _sharedPool = pool;

  final NativeHttpDefaults defaults;
  final NativeCefOptions options;
  final String adapterUserAgent;
  final NativeCefContext context;
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
    HttpStatusLog.observe(method: envelope.method, url: envelope.url, transport: 'h2',
      send: () {
        final token = MergedCancellationToken([_token,
          if (envelope.cancellationToken != null) envelope.cancellationToken!]);
        token.throwIfCancelled();
        return _sendStream(envelope, token).asCancellable(token);
      });

  Future<http.StreamedResponse> _sendStream(RequestEnvelope envelope, CancellationToken token) async {
    if (_closed) throw StateError('Native CEF H2 transport is closed');
    final plan = defaults.prepareCefNetwork(envelope, options: options,
      adapterUserAgent: adapterUserAgent, context: context);
    final parsed = Uri.parse(plan.url);
    final loopback = const {'127.0.0.1', 'localhost'}.contains(parsed.host);
    if (parsed.scheme != 'https' || parsed.userInfo.isNotEmpty || parsed.hasFragment ||
        (!loopback && !(admitRemoteRequest?.call(envelope) ?? false))) {
      throw StateError('Remote native CEF H2 transport is unverified. No request was sent.');
    }
    final timeout = Duration(milliseconds: envelope.nativeTimeoutMilliseconds ?? 30000);
    NativeCefHttp2Lease? lease;
    h2.ClientTransportStream? activeStream;
    StreamSubscription<h2.StreamMessage>? subscription;
    StreamController<List<int>>? body;
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
      if (headersDelivered) { body?.addError(error); unawaited(body?.close()); }
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
      final authority = plan.headers.firstWhere((entry) => entry.key == 'Host').value;
      final headers = <h2.Header>[
        h2.Header.ascii(':method', plan.method),
        h2.Header.ascii(':authority', authority),
        h2.Header.ascii(':scheme', 'https'),
        h2.Header.ascii(':path', plan.rawTarget),
        for (final header in plan.headers)
          if (!const {'host', 'connection', 'proxy-connection', 'transfer-encoding'}.contains(header.key.toLowerCase()))
            h2.Header.ascii(header.key, header.value),
        if (!plan.headers.any((entry) => entry.key.toLowerCase() == 'priority'))
          h2.Header.ascii('priority', 'u=4, i'),
      ];
      final stream = lease.makeRequest(headers, endStream: plan.body.isEmpty,
        priorityBand: NativeHttp2PriorityDependencies.nativePriorityBand);
      activeStream = stream;
      if (plan.body.isNotEmpty) stream.sendData(plan.body, endStream: true);
      final responseBody = StreamController<List<int>>(
        onPause: () => subscription?.pause(), onResume: () => subscription?.resume(),
        onCancel: () async { stream.terminate(); await subscription?.cancel(); release(); });
      body = responseBody;
      final responseHeaders = <String, String>{};
      subscription = stream.incomingMessages.listen((message) {
        if (message is h2.HeadersStreamMessage) {
          int? status;
          for (final header in message.headers) {
            final name = latin1.decode(header.name), value = latin1.decode(header.value);
            if (name == ':status') {
              status = int.tryParse(value);
            } else {
              responseHeaders.update(name, (previous) => '$previous,$value', ifAbsent: () => value);
            }
          }
          if (status != null && status >= 200 && !response.isCompleted) {
            headersDelivered = true;
            response.complete(decodeNativeCefResponse(http.StreamedResponse(responseBody.stream, status,
              headers: responseHeaders, contentLength: int.tryParse(responseHeaders['content-length'] ?? ''),
              isRedirect: const {301, 302, 303, 307, 308}.contains(status), persistentConnection: true)));
          }
        } else if (message is h2.DataStreamMessage) {
          responseBody.add(message.bytes);
        }
      }, onError: (Object error, StackTrace stack) {
        if (!response.isCompleted) { response.completeError(error, stack); }
        else { responseBody.addError(error, stack); }
        if (!connection.isOpen) lease?.markFailed();
        unawaited(responseBody.close());
        release();
      }, onDone: () {
        if (!response.isCompleted) {
          response.completeError(const HttpException('H2 stream ended before response status'));
        }
        unawaited(responseBody.close());
        release();
      });
      return await response.future.timeout(timeout, onTimeout: () {
        stream.terminate();
        release();
        throw TimeoutException('Native CEF H2 response header deadline', timeout);
      });
    } catch (_) { activeStream?.terminate(); release(); rethrow; }
  }

  void close() {
    _closed = true;
    _token.cancel(http.RequestAbortedException());
    _ownedPool?.close(); _ownedPool = null;
  }
}
