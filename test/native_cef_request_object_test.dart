import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-cef-request-object.json').readAsStringSync()) as Map;
  test('CEF request-object outgoing fields match the original adapter and shipped public API', () {
    for (final input in fixture['cases'] as List) {
      final scenario = input as Map;
      final request = RequestEnvelope(method: scenario['method'] as String, url: scenario['url'] as String,
        headers: {for (final pair in scenario['headers'] as List) pair[0] as String: pair[1] as String},
        body: base64Decode(scenario['bodyBase64'] as String));
      final result = const NativeHttpDefaults(userAgent: '').prepareCefObject(request,
        options: NativeCefOptions(adapterOption80: scenario['adapterOption80'] as int),
        adapterUserAgent: scenario['adapterUserAgent'] as String);
      expect({'method': result.method, 'url': result.url, 'flags': result.flags,
        'headers': result.headers.map((entry) => [entry.key, entry.value]).toList(),
        'bodyElementsBase64': result.body == null ? <String>[] : [base64Encode(result.body!)]},
        scenario['result'], reason: scenario['name'] as String);
    }
  });
}
