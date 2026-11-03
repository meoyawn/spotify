import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  final setters = jsonDecode(File('reverse-engineering/fixtures/native-header-overrides.json')
    .readAsStringSync()) as Map;
  Map<String, String> entries(List pairs) => {
    for (final pair in pairs) pair[0] as String: pair[1] as String,
  };
  for (final scenario in setters['cases'] as List) {
    test('Original native explicit header setter: ${scenario['name']}', () {
      final result = scenario.containsKey('insertions')
        ? nativeHeaderInsertions(entries(scenario['headers'] as List), entries(scenario['insertions'] as List))
        : nativeHeaderOverrides(entries(scenario['headers'] as List), entries(scenario['overrides'] as List));
      expect(result.entries.map((entry) => [entry.key, entry.value]).toList(),
        unorderedEquals(scenario['result'] as List));
    });
  }
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-user-agent-headers.json')
    .readAsStringSync()) as Map;
  for (final scenario in fixture['cases'] as List) {
    test('Original native header constructor: ${scenario['name']}', () {
      final request = RequestEnvelope(method: 'POST',
        url: 'https://fixture.invalid/token?opaque=%7E+%2f',
        headers: entries(scenario['headers'] as List), body: [0, 128, 255],
        authorize: false, includeCredentials: true, responseType: 'bytes');
      final prepared = NativeHttpDefaults(userAgent: scenario['userAgent'] as String).prepare(request);
      // Compare the observed header entries, not native unordered-map iteration
      // order. Effective transport serialization is a separate boundary.
      expect(prepared.headers, entries(scenario['result'] as List));
      expect(prepared.method, request.method);
      expect(prepared.url, request.url);
      expect(prepared.body, request.body);
      expect(prepared.authorize, request.authorize);
      expect(prepared.includeCredentials, request.includeCredentials);
      expect(prepared.responseType, request.responseType);
    });
  }
}
