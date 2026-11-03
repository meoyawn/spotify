import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';

import 'package:spotify_flutter/playback/native_playplay_body.dart';

void main() {
  test('outgoing PlayPlay body matches unchanged original producer and serializer', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-playplay-body.json').readAsStringSync()) as Map;
    final captured = jsonDecode(File('reverse-engineering/evidence/native-playplay-actual-upload.json').readAsStringSync()) as Map;
    for (final entry in [...fixture['cases'] as List, ...captured['cases'] as List]) {
      final input = entry as Map;
      final body = NativePlayPlayLicenseBody(cacheId: utf8.encode(input['cacheId'] as String),
        timestampSeconds: input['timestampSeconds'] as int,
        nativeInteractivity: input['nativeInteractivity'] as int).encode();
      expect(hex.encode(body), input['bodyHex'], reason: input['name'] as String);
    }
  });
}
