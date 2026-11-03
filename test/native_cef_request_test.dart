import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-cef-request.json').readAsStringSync()) as Map;
  test('CEF application request fields match original adapter captures', () {
    for (final input in fixture['cases'] as List) {
      final scenario = input as Map;
      final request = RequestEnvelope(method: scenario['method'] as String,
        url: scenario['url'] as String, headers: {
          for (final pair in scenario['headers'] as List) pair[0] as String: pair[1] as String,
        }, body: base64Decode(scenario['bodyBase64'] as String));
      // Fixture headers are the native input map at the adapter boundary.
      // An empty constructor default leaves that already supplied map intact.
      final plan = const NativeHttpDefaults(userAgent: '').prepareCef(request,
        options: NativeCefOptions(adapterOption80: scenario['adapterOption80'] as int),
        adapterUserAgent: scenario['adapterUserAgent'] as String);
      expect({
        'flags': plan.flags, 'method': plan.method, 'urlInput': plan.urlInput,
        'headers': plan.headers.map((entry) => [entry.key, entry.value]).toList(),
        'bodyElementsBase64': plan.body == null ? <String>[] : [base64Encode(plan.body!)],
      }, scenario['result'], reason: scenario['name'] as String);
    }
  });
}
