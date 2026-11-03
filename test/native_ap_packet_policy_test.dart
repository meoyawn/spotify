import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/native_ap_packet_policy.dart';
import 'package:spotify_flutter/playback/spotify_ap.dart';

void main() {
  test('AP packet admission and raw state match the original dispatcher with no channel or Hermes jobs', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-ap-packet-policy.json').readAsStringSync()) as Map<String, dynamic>;
    for (final row in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final policy = NativeApPacketPolicy();
      if (row['previousKeyHex'] case final String previous?) {
        policy.admit(SpotifyApPacket(0x10, [0, 0, 0, 0, ...hex.decode(previous)]));
      }
      final original = row['original'] as Map<String, dynamic>;
      final packet = SpotifyApPacket(row['command'] as int, hex.decode(row['payloadHex'] as String));
      bool admitted;
      NativeApSessionInvalidated? invalidation;
      try { admitted = policy.admit(packet); }
      on NativeApSessionInvalidated catch (error) { admitted = true; invalidation = error; }
      expect(admitted, original['admitted'], reason: row['name'] as String);
      expect(hex.encode(policy.countryCode), original['countryHex'], reason: row['name'] as String);
      expect(hex.encode(policy.productInfo), original['productHex'], reason: row['name'] as String);
      expect(policy.opaqueState == null ? null : hex.encode(policy.opaqueState!), original['opaqueHex'], reason: row['name'] as String);
      expect(policy.initialKey == null ? null : hex.encode(policy.initialKey!), original['initialKeyHex'], reason: row['name'] as String);
      final flags = original['flags'] as int;
      expect(invalidation != null, flags != 0, reason: row['name'] as String);
      if (invalidation != null) {
        expect(invalidation.passwordChanged, (flags & 0x1000) != 0, reason: row['name'] as String);
        expect(invalidation.payload, packet.payload);
      }
    }
    for (final row in (fixture['completionCases'] as List).cast<Map<String, dynamic>>()) {
      final policy = NativeApPacketPolicy();
      if (row['loginComplete'] == true) policy.loginCompleted();
      if (row['hasKey'] == true) policy.admit(SpotifyApPacket(0x10, List.filled(20, 0)));
      expect(policy.isAuthenticationReady, row['originalPublishCount'] == 1, reason: row.toString());
    }
  });
}
