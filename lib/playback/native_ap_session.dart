import 'dart:async';
import 'dart:typed_data';

import '../protocol/native_ap_authentication.dart';
import '../protocol/native_ap_hello.dart';
import '../protocol/native_legacy_auth_codec.dart';
import 'spotify_ap_session.dart';
import 'native_ap_packet_policy.dart';
import 'native_ap_keepalive.dart';
import 'spotify_ap.dart';

/// Composes the recovered native hello and authentication policy with the real
/// AP session. The caller owns endpoint selection, connected transport and the
/// explicit AP credential; no Login5 credential conversion is inferred here.
SpotifyApSession createNativeSpotifyApSession({required NativeApHelloProfile helloProfile,
    required NativeApAuthenticationProfile authenticationProfile,
    required NativeLegacyCredential credential, required Stream<Uint8List> incoming,
    required Future<void> Function(Uint8List) sendBytes,
    required Future<void> Function() closeTransport, NativeApPacketPolicy? packetPolicy}) {
  final hello = createNativeApHello(helloProfile);
  final policy = packetPolicy ?? NativeApPacketPolicy();
  final keepalive = NativeApKeepalive(), clock = Stopwatch()..start();
  Timer? timer;
  var retired = false;
  late final SpotifyApSession session;
  void poll() {
    if (retired) return;
    timer?.cancel();
    final decision = keepalive.poll(clock.elapsedMilliseconds);
    if (decision.errorCode case final code?) {
      unawaited(session.close(NativeApKeepaliveTimeout(code)));
      return;
    }
    if (decision.packet case final packet?) {
      unawaited(session.sendPacket(packet)
        .catchError((Object error) async { await session.close(error); }));
    }
    timer = Timer(Duration(milliseconds: decision.delayMilliseconds!), poll);
  }
  bool admit(SpotifyApPacket packet) {
    keepalive.received(clock.elapsedMilliseconds);
    return policy.admit(packet);
  }
  try {
    session = SpotifyApSession(clientHello: hello.hello, incoming: incoming,
      sendBytes: sendBytes, admitAuthenticationPacket: admit,
      admitReadyPacket: admit,
      onStarted: () { keepalive.start(clock.elapsedMilliseconds); poll(); },
      onWelcome: () { keepalive.welcomed(clock.elapsedMilliseconds); poll(); },
      onLoginComplete: () {
        policy.loginCompleted();
        keepalive.authenticated();
        poll();
      },
      isAuthenticationReady: () => policy.isAuthenticationReady,
      requestNativeInitialKey: true,
      buildAuthentication: (verified) async {
        try {
          final builder = NativeApAuthentication(profile: authenticationProfile,
            credential: credential, nonceKey: hello.nonceKey);
          return await builder.build(challenge: verified.serverResponse.challenge,
            clientHelloFrame: verified.clientHelloFrame,
            serverResponseFrame: verified.serverResponseFrame,
            dhHmac: verified.keys.challenge);
        } finally { hello.close(); }
      }, closeTransport: () async {
        retired = true;
        timer?.cancel();
        clock.stop();
        hello.close();
        await closeTransport();
      });
    return session;
  } catch (_) {
    timer?.cancel();
    clock.stop();
    hello.close();
    rethrow;
  }
}
