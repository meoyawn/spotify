import 'dart:typed_data';

import 'spotify_ap.dart';

/// The current AP connection has no legacy stream channels or Hermes jobs.
/// Native dispatcher 0x1018f8f5c admits and stores these packets in that state.
/// The initial key and login-complete rendezvous follows guard0x1018f9814.
/// XML entitlement processing and reconnection belong to separate owners.
final class NativeApPacketPolicy {
  Uint8List _country = Uint8List.fromList([0x5a, 0x5a]).asUnmodifiableView();
  Uint8List _product = Uint8List(0).asUnmodifiableView();
  Uint8List? _opaque;
  Uint8List? _initialKey;
  bool _loginComplete = false;

  Uint8List get countryCode => _country;
  Uint8List get productInfo => _product;
  Uint8List? get opaqueState => _opaque;
  Uint8List? get initialKey => _initialKey;
  bool get isAuthenticationReady => _loginComplete && _initialKey != null;
  void loginCompleted() { _loginComplete = true; }

  /// Called synchronously for both pre-login and ready-session packets. A valid
  /// invalidation retires this connection; an upper owner decides reconnection.
  bool admit(SpotifyApPacket packet) {
    final data = packet.payload;
    switch (packet.command) {
      case 2 || 3 || 4 || 0x0d || 0x0e || 0x1f || 0x21 || 0x22 || 0x25 ||
          0x26 || 0x42 || 0x4b || 0x5f || 0x6d || 0xae || 0xb5:
        return true;
      case 0x10:
        if (data.length != 20) return false;
        _initialKey ??= Uint8List.fromList(data.sublist(4)).asUnmodifiableView();
        return true;
      case 0x1b:
        if (data.length < 2) return false;
        _country = Uint8List.fromList(data.sublist(0, 2)).asUnmodifiableView();
        return true;
      case 0x41:
        if (data.isEmpty || data.first >= data.length) return false;
        const passwordChanged = <int>[112, 97, 115, 115, 119, 111, 114, 100,
          45, 99, 104, 97, 110, 103, 101, 100];
        var changed = data.first == passwordChanged.length;
        if (changed) {
          for (var i = 0; i < passwordChanged.length; i++) {
            if (data[i + 1] != passwordChanged[i]) { changed = false; break; }
          }
        }
        throw NativeApSessionInvalidated(data, passwordChanged: changed);
      case 0x4a:
        return data.length == 4;
      case 0x50:
        _product = Uint8List.fromList(data).asUnmodifiableView();
        return true;
      case 0x76:
        return data.length >= 2;
      case 0xa4:
        _opaque = Uint8List.fromList(data).asUnmodifiableView();
        return true;
      case 0xb2 || 0xb3 || 0xb4 || 0xb6:
        // With no outstanding job, the native owner validates the eight-byte
        // request-id framing, logs the missing job and admits the packet.
        return data.length >= 10 && data[0] == 0 && data[1] == 8;
      default:
        // This includes data/error packets for closed legacy channels and
        // opcode 0x75, whose original dispatcher returns failure in this state.
        return false;
    }
  }
}

final class NativeApSessionInvalidated implements Exception {
  NativeApSessionInvalidated(List<int> payload, {required this.passwordChanged})
    : payload = Uint8List.fromList(payload).asUnmodifiableView();
  final Uint8List payload;
  final bool passwordChanged;
  int? get nativeErrorCode => passwordChanged ? 0x12 : null;
  @override
  String toString() => passwordChanged ? 'AP session password changed' : 'AP session invalidated';
}
