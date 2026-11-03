import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http2/transport.dart' as h2;
import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';
import '../async/shared_task.dart';
import '../diagnostics/http_status_log.dart';
import 'native_cef_response.dart';
import 'native_image_request.dart';

export 'native_image_request.dart' show NativeImagePriority;

/// Original renderer artwork fields over the standard Dart H2 primitive.
/// Only captured public artwork routes are admitted. No cookies, credentials,
/// redirects, local media or original Spotify profile are involved.
class NativeImageClient {
  NativeImageClient({required this.acceptLanguage,
    this.priority = NativeImagePriority.normal, SecurityContext? securityContext,
    this.onResponse})
    : _securityContext = securityContext;
  final String acceptLanguage;
  final NativeImagePriority priority;
  final Future<void> Function(String url, Uint8List bytes, Map<String, String> headers)? onResponse;
  final SecurityContext? _securityContext;
  final _authorities = <String, SharedTask<_ImageConnection>>{};
  final _imageConnections = <_ImageConnection>{};
  Map<String, _ImageHttp1Client>? _http1Clients;
  Map<String, _ImageHttp1Client> get _http1Owners => _http1Clients ??= {};
  bool _closed = false;
  final _cancellation = CancellationToken();
  static const _timeout = Duration(seconds: 30);

  Future<Uint8List> load(String rawUrl, {CancellationToken? cancellationToken}) async {
    final token = MergedCancellationToken([_cancellation, ?cancellationToken]);
    token.throwIfCancelled();
    final response = await http.Response.fromStream(await _send(rawUrl, token));
    token.throwIfCancelled();
    if (response.statusCode != 200) {
      throw HttpException('Artwork server returned HTTP ${response.statusCode}', uri: Uri.parse(rawUrl));
    }
    try { await onResponse?.call(rawUrl, response.bodyBytes, response.headers); }
    on FileSystemException { /* Cache IO failure does not retire an image. */ }
    return response.bodyBytes;
  }

  Future<http.StreamedResponse> _send(String rawUrl, CancellationToken token) async {
    token.throwIfCancelled();
    if (_closed) throw StateError('Artwork client is closed');
    final plan = NativeImageRequestPlan.fromUrl(rawUrl, acceptLanguage: acceptLanguage, priority: priority);
    return HttpStatusLog.observe(method: 'GET', url: plan.url, transport: plan.protocol,
      send: () => _sendPlanned(plan, token));
  }

  Future<http.StreamedResponse> _sendPlanned(NativeImageRequestPlan plan, CancellationToken token) async {
    token.throwIfCancelled();
    if (plan.protocol == 'http/1.1') return _sendHttp1(plan, token);
    final (connection, stream) = await _openStream(plan, token);
    var released = false;
    CancellationRegistration? cleanup;
    final response = Completer<http.StreamedResponse>();
    late final StreamSubscription<h2.StreamMessage> subscription;
    void release() {
      if (released) return;
      released = true;
      cleanup?.dispose();
      connection.release();
    }
    final body = StreamController<List<int>>(
      onPause: () => subscription.pause(), onResume: () => subscription.resume(),
      onCancel: () async { stream.terminate(); await subscription.cancel(); release(); });
    void fail(Object error, [StackTrace? stack]) {
      if (released) return;
      if (!response.isCompleted) response.completeError(error, stack);
      else if (!body.isClosed) body.addError(error, stack);
      stream.terminate();
      unawaited(subscription.cancel());
      unawaited(body.close());
      release();
    }
    final responseHeaders = <String, String>{};
    subscription = stream.incomingMessages.listen((message) {
      if (released) return;
      if (message is h2.HeadersStreamMessage) {
        int? status;
        for (final header in message.headers) {
          final name = latin1.decode(header.name), value = latin1.decode(header.value);
          if (name == ':status') { status = int.tryParse(value); }
          else { responseHeaders.update(name, (old) => '$old,$value', ifAbsent: () => value); }
        }
        if (status != null && status >= 200 && !response.isCompleted) {
          response.complete(decodeNativeCefResponse(http.StreamedResponse(body.stream, status,
            headers: responseHeaders, contentLength: int.tryParse(responseHeaders['content-length'] ?? ''),
            isRedirect: const {301, 302, 303, 307, 308}.contains(status), persistentConnection: true)));
        }
      } else if (message is h2.DataStreamMessage) { body.add(message.bytes); }
    }, onError: fail, onDone: () {
      if (released) return;
      if (!response.isCompleted) response.completeError(const HttpException('Artwork H2 stream ended before response status'));
      unawaited(body.close()); release();
    });
    cleanup = CancellationRegistration(token, onCancel: fail);
    try {
      token.throwIfCancelled();
      return await response.future.asCancellable(token).timeout(_timeout, onTimeout: () {
        final error = TimeoutException('Artwork response header deadline', _timeout);
        fail(error);
        throw error;
      });
    } catch (error, stack) { fail(error, stack); rethrow; }
  }

  Future<http.StreamedResponse> _sendHttp1(NativeImageRequestPlan plan, CancellationToken token) async {
    token.throwIfCancelled();
    final owner = _http1Owners.putIfAbsent(plan.authority,
      () => _ImageHttp1Client(_securityContext, _timeout));
    owner.readers++;
    HttpClientRequest? opened;
    CancellationRegistration? cleanup;
    var released = false;
    void release({bool abandonedSetup = false}) {
      if (released) return;
      released = true;
      cleanup?.dispose();
      owner.retireWhenIdle |= abandonedSetup;
      owner.readers--;
      if (owner.readers == 0 && owner.retireWhenIdle) {
        if (identical(_http1Owners[plan.authority], owner)) _http1Owners.remove(plan.authority);
        owner.close();
      }
    }
    cleanup = CancellationRegistration(token, onCancel: (error) {
      opened?.abort(error);
      release(abandonedSetup: opened == null);
    });
    try {
    token.throwIfCancelled();
    final pending = owner.client.getUrl(Uri.parse(plan.url)).then((request) {
      if (released) {
        request.abort(token.exception);
        token.throwIfCancelled();
        throw StateError('Artwork request setup was retired');
      }
      return opened = request;
    });
    final request = await pending.asCancellable(token).timeout(_timeout);
    token.throwIfCancelled();
    request.followRedirects = false;
    request.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    for (final header in plan.headers.entries) {
      request.headers.set(header.key, header.value, preserveHeaderCase: true);
    }
    final response = await request.close().timeout(_timeout).asCancellable(token);
    token.throwIfCancelled();
    final headers = <String, String>{};
    response.headers.forEach((name, values) => headers[name] = values.join(','));
    Stream<List<int>> body() async* {
      try {
        await for (final chunk in response) { token.throwIfCancelled(); yield chunk; }
        token.throwIfCancelled();
      } finally { release(); }
    }
    return decodeNativeCefResponse(http.StreamedResponse(body(), response.statusCode,
      headers: headers, contentLength: response.contentLength < 0 ? null : response.contentLength,
      isRedirect: response.isRedirect, persistentConnection: response.persistentConnection));
    } catch (error) {
      opened?.abort(error);
      release(abandonedSetup: opened == null);
      token.throwIfCancelled();
      rethrow;
    }
  }

  Future<(_ImageConnection, h2.ClientTransportStream)> _openStream(NativeImageRequestPlan plan, CancellationToken token) async {
    final deadline = DateTime.now().add(_timeout);
    while (true) {
      token.throwIfCancelled();
      if (_closed) throw StateError('Artwork client is closed');
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) throw TimeoutException('Artwork H2 stream capacity deadline', _timeout);
      // Publish the dial future synchronously: simultaneous image loads share
      // the same handshake, including while initial peer SETTINGS is pending.
      if (_authorities[plan.authority]?.token.isCancelled == true) _authorities.remove(plan.authority);
      final pending = _authorities.putIfAbsent(plan.authority,
        () => SharedTask((dial) => _connect(plan.url, _cancellation.merge(dial)),
          onAbandoned: (connection) => connection.close()));
      final _ImageConnection connection;
      try { connection = await pending.wait(token); }
      catch (_) {
        if (identical(_authorities[plan.authority], pending)) _authorities.remove(plan.authority);
        rethrow;
      }
      if (_closed) throw StateError('Artwork client is closed');
      token.throwIfCancelled();
      if (!connection.closed && connection.transport.isOpen) {
        // No await between the package capacity check and creation of the
        // stream. The standard engine owns SETTINGS/HPACK/flow control.
        final stream = connection.transport.makeRequest([
          h2.Header.ascii(':method', 'GET'), h2.Header.ascii(':authority', plan.authority),
          h2.Header.ascii(':scheme', 'https'), h2.Header.ascii(':path', plan.rawTarget),
          for (final header in plan.headers.entries) h2.Header.ascii(header.key, header.value),
        ], endStream: true);
        connection.active++;
        return (connection, stream);
      }
      final capacity = connection.transport.peerMaxConcurrentStreams;
      if (!connection.closed && capacity != null && connection.active >= capacity) {
        // Exhausted capacity (including zero) waits for a stream to finish or
        // updated peer SETTINGS; no speculative second connection is dialed.
        await connection.changed.future.timeout(deadline.difference(DateTime.now())).asCancellable(token);
        continue;
      }
      // A dead/GOAWAY connection cannot accept another stream. Existing
      // response streams retain their connection until their own completion.
      if (identical(_authorities[plan.authority], pending)) _authorities.remove(plan.authority);
      connection.retire();
    }
  }

  Future<_ImageConnection> _connect(String rawUrl, CancellationToken token) async {
    token.throwIfCancelled();
    final parsed = Uri.parse(rawUrl);
    final task = await SecureSocket.startConnect(parsed.host, parsed.port,
      context: _securityContext, supportedProtocols: const ['h2']);
    if (token.isCancelled) { task.cancel(); token.throwIfCancelled(); }
    SecureSocket? opened;
    final cleanup = CancellationRegistration(token, onCancel: (_) { task.cancel(); opened?.destroy(); });
    try {
    final socket = opened = await task.socket.timeout(_timeout, onTimeout: () {
      task.cancel(); throw TimeoutException('Artwork TLS connection deadline', _timeout);
    });
    token.throwIfCancelled();
    if (_closed || socket.selectedProtocol != 'h2') {
      socket.destroy();
      throw StateError(_closed ? 'Artwork client is closed' :
        'Artwork route did not negotiate the originally observed H2 protocol');
    }
    late final _ImageConnection connection;
    final ended = Completer<void>();
    final incoming = socket.transform(StreamTransformer<Uint8List, List<int>>.fromHandlers(
      handleDone: (sink) {
        connection.close();
        if (!ended.isCompleted) ended.complete();
        sink.close();
      },
      handleError: (Object error, StackTrace stack, sink) {
        connection.close();
        if (!ended.isCompleted) ended.complete();
        sink.addError(error, stack);
      }));
    final transport = h2.ClientTransportConnection.viaStreams(incoming, socket);
    connection = _ImageConnection(transport, socket, () => _imageConnections.remove(connection));
    _imageConnections.add(connection);
    try {
      await Future.any([transport.onInitialPeerSettingsReceived,
        ended.future.then<void>((_) => throw const HttpException('Artwork H2 peer closed before initial SETTINGS')),
      ]).timeout(_timeout).asCancellable(token);
      token.throwIfCancelled();
      if (_closed || connection.closed) throw StateError('Artwork connection closed');
      return connection;
    } catch (_) { connection.close(); rethrow; }
    } catch (_) { opened?.destroy(); token.throwIfCancelled(); rethrow; }
    finally { cleanup.dispose(); }
  }

  void close() {
    _closed = true;
    _cancellation.cancel();
    for (final owner in _http1Owners.values.toList()) { owner.close(); }
    _http1Owners.clear();
    _authorities.clear();
    for (final connection in _imageConnections.toList()) {
      connection.close();
    }
    _imageConnections.clear();
  }
}

/// H1 setup remains shared while another image needs this authority. Retiring
/// its final reader cancels the actual TCP/TLS task as well as the HTTP client.
class _ImageHttp1Client {
  _ImageHttp1Client(SecurityContext? context, Duration timeout) {
    client = HttpClient(context: context)
      ..userAgent = null ..autoUncompress = false ..connectionTimeout = timeout;
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      _cancellation.throwIfCancelled();
      final ConnectionTask<Socket> task = proxyHost == null
        ? await SecureSocket.startConnect(uri.host, uri.port,
          context: context, supportedProtocols: const ['http/1.1'])
        : await Socket.startConnect(proxyHost, proxyPort!);
      if (_cancellation.isCancelled) { task.cancel(); _cancellation.throwIfCancelled(); }
      final cleanup = CancellationRegistration(_cancellation, onCancel: (_) => task.cancel());
      return ConnectionTask.fromSocket(task.socket.then((socket) {
        if (_cancellation.isCancelled) { socket.destroy(); _cancellation.throwIfCancelled(); }
        return socket;
      }).whenComplete(cleanup.dispose), task.cancel);
    };
  }
  late final HttpClient client;
  final _cancellation = CancellationToken();
  int readers = 0;
  bool retireWhenIdle = false;
  void close() { _cancellation.cancel(); client.close(force: true); }
}

/// One exact-authority standard H2 connection. A request owns a stream slot
/// until its response ends/cancels, independently of other image streams.
class _ImageConnection {
  _ImageConnection(this.transport, this.socket, this.onClosed) {
    _frames = transport.onFrameReceived.listen((_) => _notify());
  }
  final h2.ClientTransportConnection transport;
  final SecureSocket socket;
  final void Function() onClosed;
  late final StreamSubscription<void> _frames;
  var changed = Completer<void>();
  var active = 0;
  var closed = false;
  var _retired = false;

  void _notify() {
    final previous = changed;
    changed = Completer<void>();
    previous.complete();
  }

  void release() {
    active--;
    _notify();
    if (_retired && active == 0) close();
  }

  void retire() {
    _retired = true;
    _notify();
    if (active == 0) close();
  }

  void close() {
    if (closed) return;
    closed = true;
    _notify();
    unawaited(_frames.cancel());
    unawaited(transport.terminate().catchError((Object _) => null));
    socket.destroy();
    onClosed();
  }
}
