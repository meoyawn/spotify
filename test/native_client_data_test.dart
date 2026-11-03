import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_client_data.dart';

void main() {
  group('Original native MacOS client-data mapping', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-client-data.json').readAsStringSync()) as Map<String, dynamic>;
    for (final scenario in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () {
        final providers = scenario['providers'] as Map<String, dynamic>;
        final facts = MacOSPlatformFacts(
          systemVersionString: providers['systemVersionString'] as String,
          majorVersion: providers['majorVersion'] as int,
          minorVersion: providers['minorVersion'] as int,
          patchVersion: providers['patchVersion'] as int,
          hardwareModel: providers['hardwareModel'] as String,
          cpuType: providers['cpuType'] as int,
          cpuSubtype: providers['cpuSubtype'] as int,
        );
        final identity = providers['identity'] as Map<String, dynamic>;
        final request = NativeClientDataFactory(facts: facts,
          clientId: identity['clientId'] as String, deviceId: identity['deviceId'] as String,
          clientVersion: identity['clientVersion'] as String,
          developerApiKey: identity['developerApiKey'] as String?).create(currentToken: identity['currentToken'] as String?);
        expect(request.writeToBuffer().map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(), scenario['canonicalWireHex']);
      });
    }
  });
}
