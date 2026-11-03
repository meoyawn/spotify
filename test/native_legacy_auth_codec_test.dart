import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_legacy_auth_codec.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16)]);

void _expectRestored(NativeLegacyCredential? restored, Map expected, String reason) {
  expect(restored != null, expected['accepted'], reason: reason);
  if (restored == null) return;
  expect(restored.username, expected['username'], reason: reason);
  expect(restored.authenticationType, expected['kind'], reason: reason);
  expect(restored.data, _hex(expected['credentialHex'] as String), reason: reason);
}

void main() {
  final fixture = jsonDecode(File('reverse-engineering/evidence/native-legacy-auth.json').readAsStringSync()) as Map;

  test('Legacy credential bytes and restoration match original full encoder and decoder', () {
    final codec = NativeLegacyAuthCodec();
    for (final scenario in fixture['encodeCases'] as List) {
      final input = scenario['input'] as Map, expected = scenario['encoded'] as Map;
      final encoded = codec.encode(username: input['username'] as String,
        data: _hex(input['credentialHex'] as String), deviceId: input['deviceId'] as String,
        authenticationType: input['kind'] as int);
      final name = scenario['name'] as String;
      expect(encoded.username, expected['username'], reason: name);
      expect(encoded.deviceId, expected['deviceId'], reason: name);
      expect(encoded.encodedBlob, _hex(expected['blobHex'] as String), reason: name);
      _expectRestored(codec.decode(NativeLegacyStoredCredentials(username: expected['username'] as String,
        encodedBlob: _hex(expected['blobHex'] as String), deviceId: expected['deviceId'] as String)),
        scenario['decoded'] as Map, name);
    }
  });

  test('Compact stream acceptance matches the native full restoration boundary', () {
    final codec = NativeLegacyAuthCodec();
    for (final scenario in fixture['parseCases'] as List) {
      _expectRestored(codec.decode(NativeLegacyStoredCredentials(username: 'x',
        encodedBlob: _hex(scenario['blobHex'] as String), deviceId: 'synthetic-device')),
        scenario['decoded'] as Map, scenario['name'] as String);
    }
  });

  test('Legacy restoration retains native padding, source-username and opaque Base64 byte boundaries', () {
    final codec = NativeLegacyAuthCodec();
    for (final scenario in fixture['decodeCases'] as List) {
      _expectRestored(codec.decode(NativeLegacyStoredCredentials(username: scenario['username'] as String,
        encodedBlob: _hex(scenario['blobHex'] as String), deviceId: scenario['deviceId'] as String)),
        scenario['decoded'] as Map, scenario['name'] as String);
    }
  });
}
