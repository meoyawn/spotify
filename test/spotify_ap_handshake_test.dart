import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/generated/keyexchange.pb.dart' as proto;
import 'package:spotify_flutter/playback/spotify_ap_handshake.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/spotify-ap-handshake.json').readAsStringSync()) as Map<String, dynamic>;
  Uint8List bytes(String value) => Uint8List.fromList(hex.decode(value));
  proto.ClientHello hello() => proto.ClientHello.fromBuffer(bytes(fixture['clientHelloProtoHex'] as String));
  SpotifyApHandshake handshake() => SpotifyApHandshake(clientHello: hello());
  TypeMatcher<SpotifyApHandshakeException> failure(SpotifyApHandshakeFailure value) =>
    isA<SpotifyApHandshakeException>().having((error) => error.failure, 'failure', value);
  Uint8List frame(List<int> body, {int? advertisedSize}) {
    final result = Uint8List(4 + body.length)..setRange(4, 4 + body.length, body);
    ByteData.sublistView(result).setUint32(0, advertisedSize ?? result.length, Endian.big);
    return result;
  }

  test('AP transcript KDF and complete plaintext response match independent HMAC and protoc vectors', () {
    for (final row in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final keys = SpotifyApHandshakeKeys.derive(sharedSecret: bytes(row['sharedSecretHex'] as String),
        transcript: bytes(row['transcriptHex'] as String));
      expect(hex.encode(keys.challenge), row['challengeHex'], reason: row['name'] as String);
      expect(hex.encode(keys.sendKey), row['sendKeyHex'], reason: row['name'] as String);
      expect(hex.encode(keys.receiveKey), row['receiveKeyHex'], reason: row['name'] as String);
      expect(hex.encode(keys.clientResponseFrame), row['clientResponseFrameHex'], reason: row['name'] as String);
    }
  });

  test('AP owner retains explicit identity and applies the native advertised-key guard before pinned verification', () {
    final owner = handshake();
    final outgoing = owner.clientHelloFrame;
    final sent = proto.ClientHello.fromBuffer(outgoing.sublist(6));
    expect(sent.buildInfo.writeToBuffer(), hello().buildInfo.writeToBuffer());
    expect(sent.clientNonce, hello().clientNonce);
    expect(sent.loginCryptoHello.diffieHellman.gc, hasLength(96));
    expect(ByteData.sublistView(outgoing).getUint32(2, Endian.big), outgoing.length);
    for (final keyIndex in [0, 1, 32]) {
      // Keep the independent KDF transcript untouched. Only this synthetic
      // parser input changes its key index; every signature remains invalid.
      final server = proto.APResponseMessage.fromBuffer(bytes(fixture['invalidSignatureServerFrameHex'] as String).sublist(4));
      server.challenge.loginCryptoChallenge.diffieHellman.serverSignatureKey = keyIndex;
      final incoming = frame(server.writeToBuffer()), peer = keyIndex == 0 ? owner : handshake();
      expect(peer.addResponse(Uint8List.sublistView(incoming, 0, 3)), isNull);
      expect(() => peer.addResponse(Uint8List.sublistView(incoming, 3)), throwsA(
        failure(keyIndex == 1 ? SpotifyApHandshakeFailure.unsupportedChallenge : SpotifyApHandshakeFailure.signature)
          .having((error) => error.message, 'native rejection reason', keyIndex == 1
            ? 'Unadvertised AP server signature key' : 'Pinned server signature verification failed')));
      expect(() => peer.addResponse(incoming), throwsStateError);
    }
    expect(() => SpotifyApHandshake(clientHello: proto.ClientHello()), throwsArgumentError);
  });

  test('AP owner bounds untrusted framing and preserves rejection without deriving a successful session', () {
    for (final size in [0, 3, SpotifyApHandshake.maxPacketSize + 1]) {
      final owner = handshake();
      expect(() => owner.addResponse(frame([], advertisedSize: size)),
        throwsA(failure(SpotifyApHandshakeFailure.malformed)));
      expect(() => owner.addResponse(frame([])), throwsStateError);
    }
    final absent = handshake();
    expect(() => absent.addResponse(frame(proto.APResponseMessage().writeToBuffer())),
      throwsA(failure(SpotifyApHandshakeFailure.missingChallenge)));
    final incoming = bytes(fixture['invalidSignatureServerFrameHex'] as String);
    final missingSignature = proto.APResponseMessage.fromBuffer(incoming.sublist(4));
    missingSignature.challenge.loginCryptoChallenge.diffieHellman.clearGsSignature();
    final malformed = handshake();
    expect(() => malformed.addResponse(frame(missingSignature.writeToBuffer())),
      throwsA(failure(SpotifyApHandshakeFailure.malformed)));
    for (final cut in [3, incoming.length - 1]) {
      final truncated = handshake();
      expect(truncated.addResponse(Uint8List.sublistView(incoming, 0, cut)), isNull);
      expect(truncated.finishInput, throwsA(failure(SpotifyApHandshakeFailure.truncated)));
      expect(() => truncated.addResponse(frame([])), throwsStateError);
    }

    final denied = handshake();
    final response = proto.APResponseMessage(loginFailed: proto.APLoginFailed(
      errorCode: proto.ErrorCode.PremiumAccountRequired, errorDescription: 'synthetic server denial'));
    expect(() => denied.addResponse(frame(response.writeToBuffer())),
      throwsA(failure(SpotifyApHandshakeFailure.serverRejected).having(
        (error) => error.untrustedResponse!.loginFailed.errorCode,
        'original server denial', proto.ErrorCode.PremiumAccountRequired)));
    expect(() => denied.addResponse(frame([])), throwsStateError);
  });
}
