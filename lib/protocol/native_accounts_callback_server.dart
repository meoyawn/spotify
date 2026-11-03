import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'native_desktop_accounts.dart';
import 'native_oauth_exchange.dart';

/// Desktop loopback owner 0x10040a970/0x10040abec/0x10040ae9c. Dart's HTTP
/// server owns framing. A transparent socket observer retains the request
/// target before Uri normalization can change authorization-code bytes.
class NativeAccountsCallbackServer {
  NativeAccountsCallbackServer._(this._socket, this._server, this._targets);
  static const ports = [4381, 4382, 4383, 4384, 4385, 4386, 4387, 4388,
    4389, 4390, 8080, 8081, 8082, 8443];
  final ServerSocket _socket;
  final HttpServer _server;
  final Map<int, _RequestTarget> _targets;
  StreamSubscription<HttpRequest>? _subscription;
  Completer<NativeOAuthTokenResponse>? _result;
  final _cancellation = CancellationToken();
  bool get _stopped => _cancellation.isCancelled;
  bool _grantStarted = false;

  String get redirectUri => 'http://127.0.0.1:${_socket.port}/login';

  static Future<NativeAccountsCallbackServer> open({CancellationToken? cancellationToken}) async {
    for (final port in ports) {
      cancellationToken?.throwIfCancelled();
      ServerSocket socket;
      try { socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, backlog: 1); }
      on SocketException { continue; }
      final targets = <int, _RequestTarget>{};
      try {
        cancellationToken?.throwIfCancelled();
        final observed = _ObservedServerSocket(socket, (peer, target) => targets[peer] = target);
        return NativeAccountsCallbackServer._(socket, HttpServer.listenOn(observed), targets);
      } catch (_) { await socket.close(); rethrow; }
    }
    throw const NativeAccountsRedirectFailure(5);
  }

  Future<NativeOAuthTokenResponse> authenticate({required NativeDesktopAccountsLogin login,
    required Future<void> Function(String url) openBrowser, CancellationToken? cancellationToken}) async {
    final token = MergedCancellationToken([_cancellation, ?cancellationToken]);
    token.throwIfCancelled();
    if (_stopped || _result != null) throw StateError('Accounts callback server is not available');
    final result = Completer<NativeOAuthTokenResponse>();
    _result = result;
    // Observe errors before the external browser can deliver a callback.
    final outcome = result.future;
    unawaited(outcome.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    final attempt = login.begin(redirectUri: redirectUri);
    _subscription = _server.listen((request) => unawaited(_receive(request, attempt, token)),
      onError: (Object error, StackTrace stack) => _fail(error, stack));
    try {
      await openBrowser(attempt.authorizationUrl).asCancellable(token, onCancel: () { unawaited(close()); });
      token.throwIfCancelled();
      return await outcome.asCancellable(token, onCancel: () { unawaited(close()); });
    } finally { await close(); }
  }

  Future<void> _receive(HttpRequest request, NativeAccountsLoginAttempt attempt, CancellationToken token) async {
    try {
      final info = request.connectionInfo;
      final target = info == null ? null : _targets.remove(info.remotePort);
      if (target == null || _stopped) {
        await _redirect(request, false);
        return;
      }
      // Native CEF parses the URL then requires /login. The browser callback
      // profile uses an ASCII origin-form target; unsupported targets cannot
      // reach the token sender through a normalized alternative spelling.
      final question = target.value.indexOf('?');
      final path = question < 0 ? target.value : target.value.substring(0, question);
      if (path != '/login' || !const {'GET', 'OPTIONS'}.contains(target.method)) {
        await _redirect(request, false);
        _fail(const NativeAccountsRedirectFailure(3), StackTrace.current);
        return;
      }
      if (target.method == 'OPTIONS') {
        if (request.headers.value('Access-Control-Request-Method') != 'GET' ||
            request.headers.value('Access-Control-Request-Private-Network') != 'true') {
          await _redirect(request, false);
          _fail(const NativeAccountsRedirectFailure(3), StackTrace.current);
          return;
        }
        final response = request.response;
        response.statusCode = 200;
        response.headers.contentType = ContentType('text', 'plain');
        response.headers.set('Access-Control-Allow-Origin', 'https://accounts.spotify.com');
        response.headers.set('Access-Control-Allow-Methods', 'GET');
        response.headers.set('Access-Control-Allow-Credentials', 'true');
        response.headers.set('Access-Control-Allow-Private-Network', 'true');
        response.contentLength = 0;
        response.persistentConnection = false;
        await response.close();
        return;
      }
      if (_grantStarted) { await _redirect(request, false); return; }
      _grantStarted = true;
      final callbackUrl = 'http://127.0.0.1:${_socket.port}${target.value}';
      // 0x100408d74 passes its complete URL to raw helper0x101f54e88;
      // only literal ampersand-delimited error members match in this input.
      if (callbackUrl.split('&').any((member) => member.split('=').first == 'error')) {
        await _redirect(request, false);
        _fail(const NativeAccountsRedirectFailure(7), StackTrace.current);
        return;
      }
      try {
        token.throwIfCancelled();
        final grant = await attempt.complete(callbackUrl, cancellationToken: token);
        token.throwIfCancelled();
        await _redirect(request, true);
        if (!_stopped && !(_result?.isCompleted ?? true)) _result!.complete(grant);
      } catch (error, stack) {
        await _redirect(request, false);
        _fail(error, stack);
      }
    } catch (error, stack) {
      try { await request.response.close(); } catch (_) {}
      _fail(error, stack);
    }
  }

  Future<void> _redirect(HttpRequest request, bool success) async {
    // Original0x10040c12c / completion0x10040d264: 302, text/plain,
    // zero-length body and an explicit standard CEF connection close.
    final response = request.response;
    response.statusCode = 302;
    response.headers.contentType = ContentType('text', 'plain');
    response.headers.set('Location', 'https://open.spotify.com/desktop/auth/${success ? 'success' : 'error'}');
    response.contentLength = 0;
    response.persistentConnection = false;
    await response.close();
  }

  void _fail(Object error, StackTrace stack) {
    final result = _result;
    if (result != null && !result.isCompleted) result.completeError(error, stack);
  }

  Future<void> close() async {
    if (_stopped) return;
    _cancellation.cancel(const NativeAccountsRedirectFailure(6));
    _fail(const NativeAccountsRedirectFailure(6), StackTrace.current);
    await _subscription?.cancel();
    await _server.close(force: true);
    await _socket.close();
    _targets.clear();
  }
}

class _RequestTarget {
  const _RequestTarget(this.method, this.value);
  final String method, value;
}

class _ObservedServerSocket extends StreamView<Socket> implements ServerSocket {
  _ObservedServerSocket(this._socket, void Function(int, _RequestTarget) record)
    : super(_socket.map((socket) => _ObservedSocket(socket, record)));
  final ServerSocket _socket;
  @override InternetAddress get address => _socket.address;
  @override int get port => _socket.port;
  @override Future<ServerSocket> close() => _socket.close();
}

class _ObservedSocket extends StreamView<Uint8List> implements Socket {
  _ObservedSocket(this._socket, void Function(int, _RequestTarget) record)
    : super(_observe(_socket, record));
  final Socket _socket;

  static Stream<Uint8List> _observe(Socket socket, void Function(int, _RequestTarget) record) async* {
    final firstLine = BytesBuilder(copy: false);
    var observed = false;
    await for (final chunk in socket) {
      if (!observed) {
        firstLine.add(chunk);
        final bytes = firstLine.takeBytes();
        var end = -1;
        for (var i = 0; i + 1 < bytes.length; i++) {
          if (bytes[i] == 13 && bytes[i + 1] == 10) { end = i; break; }
        }
        if (end < 0) {
          if (bytes.length > 16384) throw const HttpException('Accounts request line is too long');
          firstLine.add(bytes);
        } else {
          final line = latin1.decode(bytes.sublist(0, end));
          final first = line.indexOf(' '), last = line.lastIndexOf(' ');
          if (first <= 0 || last <= first || line.substring(last + 1) != 'HTTP/1.1') {
            throw const HttpException('Unsupported Accounts request line');
          }
          final target = line.substring(first + 1, last);
          if (!target.startsWith('/') || target.codeUnits.any((byte) => byte < 33 || byte > 126)) {
            throw const HttpException('Unsupported Accounts callback target');
          }
          record(socket.remotePort, _RequestTarget(line.substring(0, first), target));
          observed = true;
        }
      }
      yield chunk;
    }
  }

  @override Encoding get encoding => _socket.encoding;
  @override set encoding(Encoding value) => _socket.encoding = value;
  @override void add(List<int> data) => _socket.add(data);
  @override Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override void write(Object? value) => _socket.write(value);
  @override void writeAll(Iterable values, [String separator = '']) => _socket.writeAll(values, separator);
  @override void writeln([Object? value = '']) => _socket.writeln(value);
  @override void writeCharCode(int code) => _socket.writeCharCode(code);
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
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
