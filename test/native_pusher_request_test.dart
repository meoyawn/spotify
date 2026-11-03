import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_pusher_request.dart';

void main() {
  test('native push outgoing URL and headers match original request-field execution', () {
    final fixture = jsonDecode(File('reverse-engineering/evidence/native-pusher-request-fields.json').readAsStringSync()) as Map;
    for (final row in fixture['cases'] as List) {
      final sample = row as Map;
      final input = sample['input'] as Map;
      final os = (input['osVersion'] as List).cast<int>();
      final plan = NativePusherRequestPlan(hostname: input['hostname'] as String,
        accessToken: input['accessToken'] as String, clientVersion: input['clientVersion'] as String,
        osMajor: os[0], osMinor: os[1], osPatch: os[2]);
      expect(plan.urlString, sample['urlStringPassedToNSURL']);
      expect(plan.headers.entries.map((entry) => [entry.key, entry.value]).toList(),
        sample['addedRequestHeaders']);
    }
  });
}
