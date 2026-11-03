import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/native_ap_keepalive.dart';

void main() {
  test('Normal AP keepalive packets, deadlines and uint32 wrap match original connected loop sequences', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-ap-keepalive.json').readAsStringSync()) as Map<String, dynamic>;
    for (final row in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final owner = NativeApKeepalive(), actual = <Map<String, Object?>>[];
      for (final event in (row['events'] as List).cast<List>()) {
        final time = event[1] as int;
        switch (event[0]) {
          case 'start': owner.start(time);
          case 'received': owner.received(time);
          case 'ready': owner.authenticated();
          case 'poll':
            final decision = owner.poll(time);
            actual.add({'packets': [if (decision.packet case final packet?)
                {'command': packet.command, 'payloadHex': hex.encode(packet.payload)}],
              'errorCode': decision.errorCode, 'delayMilliseconds': decision.delayMilliseconds});
        }
      }
      expect(actual, row['decisions'], reason: row['name'] as String);
    }
  });
}
