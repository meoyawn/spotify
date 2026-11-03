import 'spotify_ap.dart';

/// Original connected timer branch at 0x1018faca8 for normal mode, no legacy
/// channels and an empty output backlog. The connection owner supplies uint32
/// monotonic milliseconds and executes each returned packet/timer decision.
final class NativeApKeepalive {
  int? _connectedAt, _activityAt;
  bool _ready = false, _pongPending = false;

  void start(int now) {
    if (_connectedAt != null) throw StateError('AP keepalive already started');
    _connectedAt = _activityAt = now.toUnsigned(32);
  }

  void received(int now) {
    if (_connectedAt == null) throw StateError('AP keepalive has not started');
    _activityAt = now.toUnsigned(32);
    _pongPending = false;
  }

  void authenticated() { _ready = true; }

  /// Original Welcome owner1018fa62c resets both clocks before polling.
  void welcomed(int now) {
    if (_connectedAt == null) throw StateError('AP keepalive has not started');
    _connectedAt = _activityAt = now.toUnsigned(32);
    _pongPending = false;
  }

  NativeApKeepaliveDecision poll(int now) {
    final connected = _connectedAt, activity = _activityAt;
    if (connected == null || activity == null) throw StateError('AP keepalive has not started');
    final elapsedLogin = (now - connected).toUnsigned(32);
    if (!_ready && elapsedLogin >= 30000) return const NativeApKeepaliveDecision(errorCode: 0x29);
    final phaseDelay = _ready ? 3600000 : 30000 - elapsedLogin;
    final idle = (now - activity).toUnsigned(32);
    if (idle < 60000) {
      final untilPong = 60000 - idle;
      return NativeApKeepaliveDecision(delayMilliseconds: (phaseDelay < untilPong ? phaseDelay : untilPong) + 50);
    }
    if (_pongPending) return const NativeApKeepaliveDecision(errorCode: 0x2f);
    _pongPending = true;
    _activityAt = now.toUnsigned(32);
    return NativeApKeepaliveDecision(packet: SpotifyApPacket(0x49, const [0, 0, 0, 0]),
      delayMilliseconds: (phaseDelay < 60000 ? phaseDelay : 60000) + 50);
  }
}

final class NativeApKeepaliveDecision {
  const NativeApKeepaliveDecision({this.packet, this.delayMilliseconds, this.errorCode});
  final SpotifyApPacket? packet;
  final int? delayMilliseconds, errorCode;
}

final class NativeApKeepaliveTimeout implements Exception {
  const NativeApKeepaliveTimeout(this.nativeCode);
  final int nativeCode;
  @override
  String toString() => 'AP connection timeout (native code $nativeCode)';
}
