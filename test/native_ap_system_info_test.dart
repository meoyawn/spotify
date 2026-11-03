import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_ap_system_info.dart';

NativeApSystemFacts _facts(Map<String, dynamic> input) {
  final version = (input['version'] as List).cast<int>();
  return NativeApSystemFacts(majorVersion: version[0], minorVersion: version[1],
    patchVersion: version[2], cpuType: input['cpuType'] as int,
    cpuSubtype: input['cpuSubtype'] as int,
    gestaltSucceeded: input['gestaltFailureAt'] == null);
}

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-ap-system-info.json').readAsStringSync()) as Map<String, dynamic>;

  test('AP identity wire matches original platform wrappers and serializer for signed facts, failure, separate snapshots and zero presence', () {
    for (final scenario in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final identity = NativeApSystemInfo.fromFacts(_facts(scenario['facts'] as Map<String, dynamic>),
        descriptionFacts: _facts(scenario['descriptionFacts'] as Map<String, dynamic>));
      final message = identity.toMessage(deviceId: scenario['deviceId'] as String);
      expect(hex.encode(message.writeToBuffer()), (scenario['original'] as Map<String, dynamic>)['wireHex'],
        reason: scenario['name'] as String);
    }
  });
}
