import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/generated/keyexchange.pb.dart' as exchange;
import 'package:spotify_flutter/playback/spotify_ap.dart';
import 'package:spotify_flutter/playback/spotify_ap_handshake.dart';
import 'package:spotify_flutter/playback/spotify_ap_session.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/spotify-ap-handshake.json').readAsStringSync()) as Map<String, dynamic>;
  exchange.ClientHello hello() => exchange.ClientHello.fromBuffer(hex.decode(fixture['clientHelloProtoHex'] as String));
  test('Session rejects the actual invalid signature while a byte write is blocked, then closes ownership without Login or keys', () async {
    var cancelled = 0, closed = 0, builds = 0;
    final incoming = StreamController<Uint8List>(sync: true, onCancel: () { cancelled++; });
    final firstWrite = Completer<void>(), blockedWrite = Completer<void>();
    final writes = <Uint8List>[], packets = <SpotifyApPacket>[], errors = <Object>[];
    final eventDone = Completer<void>();
    final session = SpotifyApSession(clientHello: hello(), buildAuthentication: (_) {
      builds++; throw StateError('Unverified challenge reached the authentication builder');
    },
      incoming: incoming.stream, admitAuthenticationPacket: (_) => false,
      sendBytes: (bytes) { writes.add(bytes); firstWrite.complete(); return blockedWrite.future; },
      closeTransport: () async { closed++; });
    session.packets.listen(packets.add, onError: (Object error) { errors.add(error); }, onDone: eventDone.complete);
    expect(() => session.requestAudioKey(fileId: Uint8List(20), trackGid: Uint8List(16)), throwsStateError);
    expect(builds, 0);
    final started = session.start();
    session.start(); // Starting again must not enqueue another hello.
    final rejected = expectLater(started, throwsA(isA<SpotifyApHandshakeException>()
      .having((error) => error.failure, 'failure', SpotifyApHandshakeFailure.signature)
      .having((error) => error.message, 'RSA rejection', 'Pinned server signature verification failed')));
    await firstWrite.future;
    final server = exchange.APResponseMessage.fromBuffer(hex.decode(fixture['invalidSignatureServerFrameHex'] as String).sublist(4));
    server.challenge.loginCryptoChallenge.diffieHellman.serverSignatureKey = 0;
    final body = server.writeToBuffer();
    final invalid = Uint8List(body.length + 4)..setRange(4, body.length + 4, body);
    ByteData.sublistView(invalid).setUint32(0, invalid.length, Endian.big);
    incoming.add(Uint8List.sublistView(invalid, 0, 3));
    incoming.add(Uint8List.sublistView(invalid, 3));
    await rejected;
    await session.done;
    await eventDone.future;
    expect(session.state, SpotifyApSessionState.closed);
    expect(session.welcome, isNull);
    expect(writes, hasLength(1));
    expect(builds, 0);
    expect(packets, isEmpty);
    expect(errors.single, same(session.failure));
    expect(closed, 1);
    expect(cancelled, 1);
    expect(() => session.sendPacket(SpotifyApPacket(0x0c, Uint8List(42))), throwsStateError);
    blockedWrite.complete();
    incoming.add(invalid);
    await Future<void>.delayed(Duration.zero);
    await session.close();
    expect(writes, hasLength(1));
    expect(builds, 0);
    expect(closed, 1);
    await incoming.close();
  });

  for (final mode in ['stream error', 'write error', 'truncated EOF', 'explicit close']) {
    test('Session retires authentication and transport after $mode', () async {
      final cancellation = Completer<void>();
      final incoming = StreamController<Uint8List>(sync: true, onCancel: () {
        if (mode == 'explicit close') return cancellation.future;
      });
      final firstWrite = Completer<void>();
      final marker = StateError('synthetic $mode');
      var closed = 0, builds = 0;
      final session = SpotifyApSession(clientHello: hello(), buildAuthentication: (_) {
        builds++; throw StateError('Unverified challenge reached the authentication builder');
      },
        incoming: incoming.stream, admitAuthenticationPacket: (_) => false,
        sendBytes: (_) {
          firstWrite.complete();
          return mode == 'write error' ? Future<void>.error(marker) : Future<void>.value();
        }, closeTransport: () async { closed++; cancellation.complete(); });
      session.packets.listen((_) {}, onError: (Object _) {});
      final started = session.start();
      final rejected = expectLater(started, throwsA(mode == 'truncated EOF'
        ? isA<SpotifyApHandshakeException>().having((error) => error.failure, 'failure', SpotifyApHandshakeFailure.truncated)
        : mode == 'explicit close' ? isA<StateError>() : same(marker)));
      await firstWrite.future;
      switch (mode) {
        case 'stream error': incoming.addError(marker);
        case 'truncated EOF': incoming.add(Uint8List.fromList([0, 0, 0])); await incoming.close();
        case 'explicit close': await session.close().timeout(const Duration(seconds: 1));
      }
      await rejected;
      await session.done;
      expect(session.state, SpotifyApSessionState.closed);
      expect(session.welcome, isNull);
      expect(builds, 0);
      expect(closed, 1);
      if (mode == 'stream error' || mode == 'write error') { expect(session.failure, same(marker)); }
      expect(() => session.requestAudioKey(fileId: Uint8List(20), trackGid: Uint8List(16)), throwsStateError);
      await session.close();
      expect(closed, 1);
      await incoming.close();
    });
  }
}
