import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/generated/pending_event_entity.pb.dart';
import 'package:spotify_flutter/protocol/native_pending_event_codec.dart';
import 'package:spotify_flutter/protocol/native_protobuf.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16)]);

void main() {
  final fixture = jsonDecode(File('reverse-engineering/evidence/native-pending-event-framing.json').readAsStringSync()) as Map;

  test('Pending-event fields, wire defaults and restoration match native owner vectors', () {
    for (final scenario in fixture['ownerCases'] as List) {
      final input = scenario['input'] as Map;
      final codec = NativePendingEventCodec(random: _FixedIv(scenario['ivHex'] as String));
      final message = codec.encrypt(eventName: input['eventName'] as String,
        payload: _hex(input['payloadHex'] as String), username: input['username'] as String?);
      final presence = (message.hasEventName() ? 1 : 0) | (message.hasPayload() ? 2 : 0) |
        (message.hasUsername() ? 4 : 0);
      expect(presence, scenario['nativeHasBits'], reason: scenario['name'] as String);
      expect(nativeProto3Bytes(message), _hex(scenario['wireHex'] as String), reason: scenario['name'] as String);

      final originalMessage = PendingEventEntity.fromBuffer(_hex(scenario['wireHex'] as String));
      final decoded = codec.decrypt(originalMessage);
      final expected = scenario['decode'] as Map;
      expect(decoded, isNotNull, reason: scenario['name'] as String);
      expect(decoded!.eventName, expected['eventName']);
      expect(decoded.payload, _hex(expected['payloadHex'] as String));
      expect(decoded.username, expected['username']);
    }
  });

  test('Pending-event admission follows original raw-frame owner rejection', () {
    final codec = NativePendingEventCodec();
    for (final scenario in fixture['ownerDecodeCases'] as List) {
      final expected = scenario['decode'] as Map;
      final decoded = codec.decrypt(PendingEventEntity(eventName: 'synthetic-event',
        payload: _hex(scenario['frameHex'] as String), username: 'synthetic-user'));
      expect(decoded != null, expected['accepted'], reason: scenario['name'] as String);
      if (decoded != null) {
        expect(decoded.eventName, expected['eventName']);
        expect(decoded.payload, _hex(expected['payloadHex'] as String));
        expect(decoded.username, expected['username']);
      }
    }
  });
}

class _FixedIv implements Random {
  _FixedIv(String hex) : bytes = _hex(hex);
  final Uint8List bytes;
  int offset = 0;
  @override
  int nextInt(int max) => bytes[offset++] % max;
  @override
  bool nextBool() => throw UnsupportedError('Fixture supplies IV bytes');
  @override
  double nextDouble() => throw UnsupportedError('Fixture supplies IV bytes');
}
