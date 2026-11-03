import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:http/http.dart' as http;

import '../async/cancellation.dart';
import '../diagnostics/http_status_log.dart';
import 'native_cef_context.dart';
import 'native_cef_http_request.dart';
import 'native_cef_request.dart';
import 'native_cef_response.dart';
import 'native_http_defaults.dart';
import 'request_builder.dart';

/// Dart HTTP/1.1 execution of the independently captured native CEF fields.
/// A remote origin requires explicit admission from its owning session/route.
/// Response content codings use the shared native CEF decoding policy.
class NativeCefHttpTransport {
  NativeCefHttpTransport({required this.defaults, required this.options,
    required this.adapterUserAgent, required this.context,
    SecurityContext? securityContext, NativeCefHttpConnectionPool? pool,
    this.admitRemoteRequest}) : _securityContext = securityContext, _pool = pool;

  final NativeHttpDefaults defaults;
  final NativeCefOptions options;
  final String adapterUserAgent;
  final NativeCefContext context;
  final bool Function(RequestEnvelope request)? admitRemoteRequest;
  final SecurityContext? _securityContext;
  final NativeCefHttpConnectionPool? _pool;
  final _clients = <HttpClient>{};
  final _pooledClients = <HttpClient, _PooledCefClient>{};
  bool _closed = false;
  final _cancellation = CancellationToken();

  Future<http.Response> send(RequestEnvelope envelope) async =>
    http.Response.fromStream(await sendStream(envelope));

  Future<http.StreamedResponse> sendStream(RequestEnvelope envelope) =>
    HttpStatusLog.observe(method: envelope.method, url: envelope.url, transport: 'http/1.1',
      send: () => _sendStream(envelope));

  Future<http.StreamedResponse> _sendStream(RequestEnvelope envelope) async {
    final token = envelope.cancellationToken == null ? _cancellation
      : _cancellation.merge(envelope.cancellationToken!);
    token.throwIfCancelled();
    final plan = defaults.prepareCefNetwork(envelope, options: options,
      adapterUserAgent: adapterUserAgent, context: context);
    final parsed = Uri.parse(plan.url);
    final loopback = const {'localhost', '127.0.0.1'}.contains(parsed.host);
    if (parsed.scheme != 'https' || parsed.userInfo.isNotEmpty || parsed.hasFragment ||
        (!loopback && !(admitRemoteRequest?.call(envelope) ?? false))) {
      throw StateError('Remote native CEF HTTP transport is unverified. No request was sent.');
    }
    // Reuse standard Dart TLS, response parsing and body framing. Its header
    // map is unordered, so the socket boundary writes the verified ordered
    // CEF header block before TLS encrypts it. The body passes through intact.
    final pooled = _pool != null && plan.method == 'GET' && plan.body.isEmpty ? _pool._acquire(plan) : null;
    final client = pooled?.client ?? (HttpClient(context: _securityContext)
      ..autoUncompress = false
      ..userAgent = null
      ..findProxy = ((_) => 'DIRECT'));
    if (pooled != null) _pooledClients[client] = pooled;
    else client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (_closed || proxyHost != null) throw StateError('Native CEF HTTP route changed');
      final task = await SecureSocket.startConnect(uri.host, uri.port,
        context: _securityContext, supportedProtocols: const ['http/1.1']);
      if (token.isCancelled) { task.cancel(); token.throwIfCancelled(); }
      final cleanup = CancellationRegistration(token, onCancel: (_) => task.cancel());
      return ConnectionTask.fromSocket(task.socket.then((socket) {
        if (token.isCancelled) { socket.destroy(); token.throwIfCancelled(); }
        return _CefHeaderSocket(socket, plan);
      }).whenComplete(cleanup.dispose), task.cancel);
    };
    _clients.add(client);
    CancellationRegistration? cleanup;
    void release({bool reusable = false}) {
      if (!_clients.remove(client)) return;
      cleanup?.dispose();
      _pooledClients.remove(client);
      if (pooled != null) _pool!._release(pooled, reusable: reusable);
      else client.close(force: true);
    }
    cleanup = CancellationRegistration(token, onCancel: (_) => release());
    try {
      token.throwIfCancelled();
      final request = await client.openUrl(plan.method, parsed.removeFragment()).asCancellable(token);
      token.throwIfCancelled();
      request.followRedirects = false;
      request.headers.clear();
      for (final header in plan.headers) {
        request.headers.set(header.key, header.value, preserveHeaderCase: true);
      }
      if (plan.body.isNotEmpty) request.add(plan.body);
      final response = await request.close().asCancellable(token);
      token.throwIfCancelled();
      final headers = <String, String>{};
      response.headers.forEach((name, values) => headers[name] = values.join(','));
      Stream<List<int>> body() async* {
        var complete = false;
        try {
          await for (final chunk in response) { token.throwIfCancelled(); yield chunk; }
          token.throwIfCancelled(); complete = true;
        }
        finally { release(reusable: complete && response.persistentConnection); }
      }
      return decodeNativeCefResponse(http.StreamedResponse(body(), response.statusCode,
        contentLength: response.contentLength < 0 ? null : response.contentLength,
        headers: headers, reasonPhrase: response.reasonPhrase,
        persistentConnection: response.persistentConnection,
        isRedirect: response.isRedirect));
    } catch (_) { release(); token.throwIfCancelled(); rethrow; }
  }

  void close() {
    _closed = true;
    _cancellation.cancel(http.RequestAbortedException());
    for (final client in _clients.toList()) {
      final pooled = _pooledClients.remove(client);
      if (pooled != null) _pool!._release(pooled, reusable: false);
      else client.close(force: true);
    }
    _clients.clear();
  }
}

/// Standard HttpClient owns persistent HTTP/1.1 connections and response
/// framing. An exclusive client lease keeps the exact current header plan
/// attached to its socket; concurrent requests use separate leases.
class NativeCefHttpConnectionPool {
  NativeCefHttpConnectionPool({SecurityContext? securityContext}) : _securityContext = securityContext;
  final SecurityContext? _securityContext;
  final _clients = <_PooledCefClient>{};
  final _idle = <_PooledCefClient>[];
  bool _closed = false;
  int openedConnections = 0, reusedClients = 0;

  _PooledCefClient _acquire(NativeCefHttpRequestPlan plan) {
    if (_closed) throw StateError('Native CEF HTTP pool is closed');
    if (plan.method != 'GET' || plan.body.isNotEmpty) {
      throw ArgumentError('The captured pooled media route requires a bodyless GET');
    }
    final uri = Uri.parse(plan.url);
    final origin = '${uri.host}:${uri.port}';
    final index = _idle.lastIndexWhere((entry) => entry.origin == origin);
    final _PooledCefClient entry;
    if (index >= 0) { entry = _idle.removeAt(index); reusedClients++; }
    else {
      entry = _PooledCefClient(origin, _securityContext, () => openedConnections++);
      _clients.add(entry);
    }
    entry.begin(plan);
    return entry;
  }

  void _release(_PooledCefClient entry, {required bool reusable}) {
    if (!_clients.contains(entry) || !entry.leased) return;
    entry.leased = false;
    if (_closed || !reusable) { _clients.remove(entry); entry.close(); return; }
    _idle.add(entry);
    // An app storage bound, not a claimed original socket-pool setting.
    while (_idle.length > 8) {
      final oldest = _idle.removeAt(0);
      _clients.remove(oldest); oldest.close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final entry in _clients) { entry.close(); }
    _clients.clear(); _idle.clear();
  }
}

class _PooledCefClient {
  _PooledCefClient(this.origin, SecurityContext? securityContext, void Function() onConnect) {
    client = HttpClient(context: securityContext)
      ..autoUncompress = false
      ..userAgent = null
      ..maxConnectionsPerHost = 1
      ..findProxy = ((_) => 'DIRECT');
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (_closed || proxyHost != null) throw StateError('Native CEF HTTP route changed');
      final task = await SecureSocket.startConnect(uri.host, uri.port,
        context: securityContext, supportedProtocols: const ['http/1.1']);
      if (_closed) { task.cancel(); _token.throwIfCancelled(); }
      final cleanup = CancellationRegistration(_token, onCancel: (_) => task.cancel());
      return ConnectionTask.fromSocket(task.socket.then((socket) {
        if (_closed) { socket.destroy(); throw StateError('Native CEF HTTP client is closed'); }
        final wrapped = _CefHeaderSocket(socket, _plan);
        // This exclusive client has one connection per host. A replacement
        // supersedes old wrappers, including ones with a pending done Future.
        _sockets..clear()..add(wrapped); onConnect();
        unawaited(socket.done.then<void>((_) { _sockets.remove(wrapped); },
          onError: (Object _) { _sockets.remove(wrapped); }));
        return wrapped;
      }).whenComplete(cleanup.dispose), task.cancel);
    };
  }
  final String origin;
  late final HttpClient client;
  late NativeCefHttpRequestPlan _plan;
  final _sockets = <_CefHeaderSocket>{};
  bool leased = false, _closed = false;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();

  void begin(NativeCefHttpRequestPlan plan) {
    if (_closed || leased) throw StateError('Native CEF HTTP client is already owned');
    // Captured Chromium151 retains used sockets with a300s default. Apply it
    // at acquisition so existing clients also receive it after hot reload.
    client.idleTimeout = const Duration(seconds: 300);
    leased = true; _plan = plan;
    for (final socket in _sockets) { socket.beginRequest(plan); }
  }

  void close() { _closed = true; _token.cancel(); client.close(force: true); _sockets.clear(); }
}

/// Writes exactly one verified header block per request; standard HttpClient
/// still owns body parsing, persistence and connection selection.
class _CefHeaderSocket extends StreamView<Uint8List> implements SecureSocket {
  _CefHeaderSocket(this._socket, this._plan) : super(_socket);
  final SecureSocket _socket;
  NativeCefHttpRequestPlan _plan;
  final _pendingHeader = BytesBuilder(copy: false);
  bool _headerSent = false;

  void beginRequest(NativeCefHttpRequestPlan plan) {
    _plan = plan; _headerSent = false; _pendingHeader.clear();
  }

  @override void add(List<int> data) {
    if (_headerSent) { _socket.add(data); return; }
    _pendingHeader.add(data);
    final bytes = _pendingHeader.takeBytes();
    var end = -1;
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) {
        end = i + 4; break;
      }
    }
    if (end < 0) {
      if (bytes.length > 65536) throw const HttpException('HTTP header exceeds the native request profile');
      _pendingHeader.add(bytes); return;
    }
    final generated = latin1.decode(bytes.sublist(0, end - 4)).split('\r\n');
    final expected = <String, String>{for (final entry in _plan.headers)
      entry.key.toLowerCase(): entry.value};
    final actual = <String, String>{};
    for (final line in generated.skip(1)) {
      final colon = line.indexOf(':');
      if (colon < 1) throw const HttpException('Invalid generated HTTP header');
      actual[line.substring(0, colon).toLowerCase()] = line.substring(colon + 1).trim();
    }
    if (!generated.first.startsWith('${_plan.method} ') ||
        actual.length != expected.length || expected.entries.any((entry) => actual[entry.key] != entry.value)) {
      throw const HttpException('Standard HTTP framing changed native request fields');
    }
    final header = '${_plan.method} ${_plan.rawTarget} HTTP/1.1\r\n'
      '${_plan.headers.map((entry) => '${entry.key}: ${entry.value}\r\n').join()}\r\n';
    _headerSent = true;
    _socket.add(latin1.encode(header));
    if (end < bytes.length) _socket.add(bytes.sublist(end));
  }

  @override Future<void> addStream(Stream<List<int>> stream) async {
    await for (final bytes in stream) { add(bytes); }
  }
  @override Encoding get encoding => _socket.encoding;
  @override set encoding(Encoding value) => _socket.encoding = value;
  @override void write(Object? value) => add(encoding.encode('$value'));
  @override void writeAll(Iterable values, [String separator = '']) => write(values.join(separator));
  @override void writeln([Object? value = '']) => write('$value\n');
  @override void writeCharCode(int code) => write(String.fromCharCode(code));
  @override void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);
  @override Future<void> flush() => _socket.flush();
  @override Future close() => _socket.close();
  @override Future get done => _socket.done;
  @override void destroy() => _socket.destroy();
  @override bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);
  @override Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);
  @override void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  @override int get port => _socket.port;
  @override int get remotePort => _socket.remotePort;
  @override InternetAddress get address => _socket.address;
  @override InternetAddress get remoteAddress => _socket.remoteAddress;
  @override X509Certificate? get peerCertificate => _socket.peerCertificate;
  @override String? get selectedProtocol => _socket.selectedProtocol;
  @override void renegotiate({bool useSessionCache = true, bool requestClientCertificate = false,
      bool requireClientCertificate = false}) => _socket.renegotiate(useSessionCache: useSessionCache,
    requestClientCertificate: requestClientCertificate, requireClientCertificate: requireClientCertificate);
  // Socket also declares a private detach operation. This direct TLS route
  // never upgrades/detaches its socket or creates a proxy tunnel.
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
