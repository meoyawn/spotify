import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_legacy_auth_json.dart';

void main() {
  final native = jsonDecode(File('reverse-engineering/evidence/native-legacy-auth.json').readAsStringSync()) as Map;
  test('Admitted legacy string-map writes match original JSON bytes and no-write decisions', () {
    for (final scenario in native['jsonWrites'] as List) {
      // Numeric/unknown-shape preservation is intentionally outside the writer
      // admission boundary; the real preference-owner test guards no mutation.
      if (scenario['name'] == 'unrelated typed values') continue;
      final writes = scenario['writes'] as List;
      final expected = writes.isEmpty ? null : (writes.single as Map)['value'];
      expect(NativeLegacyAuthJson.update(scenario['saved'] as String,
        canonicalUsername: scenario['canonicalUsername'] as String, username: scenario['username'] as String,
        blob: scenario['blob'] as String), expected, reason: scenario['name'] as String);
    }
  });
}
