import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_foundation_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-foundation-request.json')
    .readAsStringSync()) as Map;
  for (final scenario in fixture['cases'] as List) {
    test('Original Foundation application boundary: ${scenario['name']}', () {
      final request = RequestEnvelope(method: scenario['method'] as String,
        url: scenario['url'] as String, headers: {
          for (final pair in scenario['headers'] as List) pair[0] as String: pair[1] as String,
        }, body: base64Decode(scenario['bodyBase64'] as String));
      final plan = const NativeHttpDefaults(userAgent: '').prepareFoundation(request,
        options: NativeFoundationOptions(timeoutMilliseconds: scenario['timeoutMilliseconds'] as int,
          trafficClass: scenario['trafficClass'] as int, cachePolicyOverride: scenario['cachePolicyOverride'] as int));
      final expected = scenario['result'] as Map;
      expect({
        'method': plan.method, 'urlInput': plan.urlInput,
        'headers': plan.headers.map((entry) => [entry.key, entry.value]).toList(),
        'bodyBase64': plan.body == null ? null : base64Encode(plan.body!),
        'cachePolicy': plan.cachePolicy, 'timeoutSeconds': plan.timeoutSeconds,
        'networkServiceType': plan.networkServiceType,
      }, expected);
    });
  }
}
