import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';

import '../transport/foundation/web_socket.dart';
import 'native_pusher_message.dart';
import 'native_pusher_request.dart';

/// Dart owns the native push connection and its received server identity.
/// Foundation supplies standard WebSocket/TLS primitives. Message parsing
/// creates no command acknowledgement or connection identity.
class NativePusherConnection {
  NativePusherConnection._(this._socket) {
    _subscription = _socket.messages.listen(_receive, onError: _failed, onDone: () {
      if (!_closed) _failed(StateError('Spotify push connection closed'));
    });
  }

  static Future<NativePusherConnection> open({required NativePusherRequestPlan plan,
      required bool Function(Uri url) admitRemoteUrl, CancellationToken? cancellationToken}) async {
    final owner = NativePusherConnection._(await FoundationWebSocket.open(
      rawUrl: plan.urlString, headers: plan.headers, admitRemoteUrl: admitRemoteUrl,
      cancellationToken: cancellationToken));
    try {
      await owner._firstConnection.future.asCancellable(cancellationToken,
        onCancel: () { unawaited(owner.close()); });
      // Original Apple wrapper's standard send-ping interval is thirty seconds.
      owner._pingTimer = Timer.periodic(const Duration(seconds: 30), (_) => owner._ping());
      return owner;
    } catch (_) { await owner.close(); rethrow; }
  }

  final FoundationWebSocket _socket;
  late final StreamSubscription<Object> _subscription;
  final _firstConnection = Completer<void>();
  final _messages = StreamController<NativePusherMessage>.broadcast();
  final _connectionIds = StreamController<String>.broadcast();
  Timer? _pingTimer;
  String? _connectionId;
  bool _closed = false, _pingPending = false;
  String get connectionId => _connectionId ?? (throw StateError('Spotify has not supplied a connection ID'));
  bool get isClosed => _closed;
  Stream<NativePusherMessage> get messages => _messages.stream;
  Stream<String> get connectionIds => _connectionIds.stream;

  void _receive(Object value) {
    if (_closed) return;
    if (value is! String) { _failed(const FormatException('Native push expects text messages')); return; }
    try {
      final message = NativePusherMessage.fromText(value);
      final id = message.headers['Spotify-Connection-Id'];
      if (id != null && id.isNotEmpty) {
        _connectionId = id;
        _connectionIds.add(id);
        if (!_firstConnection.isCompleted) _firstConnection.complete();
      } else { _messages.add(message); }
    } catch (error, stack) { _failed(error, stack); }
  }

  void _ping() {
    if (_closed || _pingPending) return;
    _pingPending = true;
    unawaited(_socket.ping().then<void>((_) { _pingPending = false; },
      onError: (Object error, StackTrace stack) { _pingPending = false; _failed(error, stack); }));
  }

  void _failed(Object error, [StackTrace? stack]) {
    if (_closed) return;
    if (!_firstConnection.isCompleted) _firstConnection.completeError(error, stack);
    _messages.addError(error, stack);
    unawaited(close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel(); _pingTimer = null;
    _connectionId = null;
    if (!_firstConnection.isCompleted) {
      _firstConnection.completeError(StateError('Spotify push connection was closed'));
    }
    await _subscription.cancel();
    await _socket.close();
    await _connectionIds.close();
    await _messages.close();
  }
}
