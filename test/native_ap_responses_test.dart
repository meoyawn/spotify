import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/generated/keyexchange.pb.dart' as exchange;
import 'package:spotify_flutter/playback/native_ap_responses.dart';
import 'package:spotify_flutter/playback/spotify_ap_handshake.dart';

void main() {
  final inbound = jsonDecode(File('reverse-engineering/fixtures/native-ap-inbound.json').readAsStringSync()) as Map<String, dynamic>;
  final schemas = jsonDecode(File('reverse-engineering/fixtures/native-ap-schemas.json').readAsStringSync()) as Map<String, dynamic>;
  Uint8List bytes(String value) => Uint8List.fromList(hex.decode(value));
  final cases = (inbound['cases'] as List).cast<Map<String, dynamic>>();

  test('Native inbound projection preserves original parser numeric presence, ordering and opaque input', () {
    for (final row in cases) {
      final wire = bytes(row['inputHex'] as String);
      final expected = row['numericFields'] as Map<String, dynamic>;
      switch (row['message']) {
        case 'APWelcome':
          final value = NativeApWelcome.decode(wire);
          expect([value.accountTypeLoggedIn, value.credentialsTypeLoggedIn, value.reusableAuthCredentialsType],
            [expected['20'], expected['25'], expected['30']], reason: row['name'] as String);
          expect(value.canonicalUsername, 'synthetic-user');
          expect(value.reusableAuthCredentials, [0, 255, ...utf8.encode('credential')]);
          expect(value.lfsSecret, isNull);
          expect(value.wireBytes, wire);
        case 'APLoginFailed':
          final value = NativeApLoginFailure.decode(wire);
          expect(value.errorCode, expected['10'], reason: row['name'] as String);
          expect([value.retryDelay, value.expiry, value.errorDescription], [5, 9, 'synthetic denial']);
          expect(value.wireBytes, wire);
        case 'APResponseMessage':
          final value = NativeApResponse.decode(wire);
          expect(value.loginFailure!.errorCode, expected['10'], reason: row['name'] as String);
          expect(value.wireBytes, wire);
      }
    }
  });

  test('Native fixed-byte response constraints match the original accepted/rejected schema fixture', () {
    for (final row in (schemas['nativeParserReferenceCases'] as List).cast<Map<String, dynamic>>()) {
      final wire = bytes(row['inputHex'] as String);
      Object decode() => switch (row['referenceType']) {
        'APWelcome' => NativeApWelcome.decode(wire),
        'APLoginFailed' => NativeApLoginFailure.decode(wire),
        'APResponseMessage' => NativeApResponse.decode(wire),
        _ => throw StateError('Unexpected scoped fixture type'),
      };
      if (row['accepted'] == true) {
        expect(decode, returnsNormally);
      } else {
        expect(decode, throwsFormatException, reason: '${row['referenceType']}: original parser rejected');
      }
    }
  });

  test('Actual handshake retains a foreign native denial instead of rejecting its required enum presence', () {
    final helloFixture = jsonDecode(File('reverse-engineering/fixtures/spotify-ap-handshake.json').readAsStringSync()) as Map;
    final owner = SpotifyApHandshake(clientHello: exchange.ClientHello.fromBuffer(bytes(helloFixture['clientHelloProtoHex'] as String)));
    final row = cases.singleWhere((row) => row['name'] == 'handshake_failure_numeric_255');
    final body = bytes(row['inputHex'] as String);
    final frame = Uint8List(body.length + 4)..setRange(4, body.length + 4, body);
    ByteData.sublistView(frame).setUint32(0, frame.length, Endian.big);
    expect(() => owner.addResponse(frame), throwsA(isA<SpotifyApHandshakeException>()
      .having((error) => error.failure, 'failure', SpotifyApHandshakeFailure.serverRejected)
      .having((error) => error.untrustedLoginFailure!.errorCode, 'raw denial', 255)));
    expect(() => owner.addResponse(frame), throwsStateError);
  });
}
