import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../../async/cancellation.dart';

/// Standard URLSession WebSocket transport. Its owner supplies the complete
/// URL/headers and admits remote destinations; this class adds no Spotify
/// fields, messages, authentication, timers, retries or redirects of its own.
class FoundationWebSocket {
  FoundationWebSocket._(this._id);
  static const _channel = MethodChannel('spotify_flutter/foundation_web_socket');
  static final _sockets = <int, FoundationWebSocket>{};
  static int _sequence = 0;
  static bool _listening = false;
  final int _id;
  final _messages = StreamController<Object>();
  bool _closed = false;
  CancellationRegistration? _cancellation;

  /// Messages buffer until the single owning session attaches its listener.
  Stream<Object> get messages => _messages.stream;

  static Future<FoundationWebSocket> open({required String rawUrl,
      required Map<String, String> headers, bool Function(Uri url)? admitRemoteUrl,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final url = Uri.tryParse(rawUrl);
    final local = url != null && const {'localhost', '127.0.0.1', '::1'}.contains(url.host);
    if (url == null || url.userInfo.isNotEmpty || url.hasFragment ||
        !(url.scheme == 'wss' || local && url.scheme == 'ws') ||
        (!local && !(admitRemoteUrl?.call(url) ?? false))) {
      throw StateError('Foundation WebSocket destination has not been admitted');
    }
    if (headers.entries.any((entry) =>
        !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(entry.key) ||
        entry.value.contains(RegExp(r'[\x00\r\n]')))) {
      throw const FormatException('Invalid WebSocket application header');
    }
    if (!_listening) {
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'event') return;
        final event = (call.arguments as Map).cast<String, Object?>();
        final socket = _sockets[event['id']];
        if (socket == null || socket._closed) return;
        switch (event['type']) {
          case 'text': socket._messages.add(event['data'] as String);
          case 'binary': socket._messages.add(event['data'] as Uint8List);
          case 'error':
            socket._messages.addError(PlatformException(code: 'foundation_web_socket',
              message: event['message'] as String?, details: event['code']));
            socket._finish();
          case 'closed': socket._finish();
        }
      });
      _listening = true;
    }
    final socket = FoundationWebSocket._(++_sequence);
    _sockets[socket._id] = socket;
    socket._cancellation = CancellationRegistration(cancellationToken,
      onCancel: (_) { unawaited(socket.close()); });
    try {
      await _channel.invokeMethod<void>('open', {'id': socket._id,
        'url': rawUrl, 'headers': [for (final entry in headers.entries) [entry.key, entry.value]]})
        .asCancellable(cancellationToken);
      return socket;
    } catch (_) {
      socket._finish();
      rethrow;
    }
  }

  Future<void> sendText(String value) => _send('text', value);
  Future<void> sendBinary(Uint8List value) => _send('binary', value);
  Future<void> _send(String type, Object data) {
    if (_closed) throw StateError('Foundation WebSocket is closed');
    return _channel.invokeMethod<void>('send', {'id': _id, 'type': type, 'data': data});
  }

  Future<void> ping() {
    if (_closed) throw StateError('Foundation WebSocket is closed');
    return _channel.invokeMethod<void>('ping', {'id': _id});
  }

  Future<void> close() async {
    if (_closed) return;
    _finish();
    await _channel.invokeMethod<void>('close', {'id': _id});
  }

  void _finish() {
    _cancellation?.dispose(); _cancellation = null;
    if (_closed) return;
    _closed = true;
    _sockets.remove(_id);
    unawaited(_messages.close());
  }
}
