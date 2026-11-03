import 'dart:convert' show jsonDecode;
import 'dart:io' show File;

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/native_playplay_request.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('Original music PlayPlay owner matches Dart method/raw URL/headers/opaque body', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-playplay-requests.json')
      .readAsStringSync()) as Map<String, dynamic>;
    final injected = fixture['injectedTemplate'] as Map<String, dynamic>;
    final template = RequestEnvelope(method: injected['method'] as String,
      url: injected['url'] as String, headers: (injected['headers'] as Map).cast<String, String>(),
      body: hex.decode(injected['bodyHex'] as String), authorize: false,
      includeCredentials: false, responseType: 'bytes');
    for (final value in fixture['cases'] as List) {
      final input = value as Map<String, dynamic>;
      final original = input['original'] as Map<String, dynamic>;
      final plan = NativePlayPlayRequestPlan.musicKey(template: template,
        fileId20: hex.decode(input['fileIdHex'] as String),
        serializedBody: hex.decode(input['opaqueBodyHex'] as String));
      final outgoing = plan.request;
      final reason = input['name'] as String;
      expect(outgoing.method, original['method'], reason: reason);
      expect(outgoing.url, original['rawUrl'], reason: reason);
      expect(outgoing.headers, original['headers'], reason: reason);
      expect(outgoing.body, hex.decode(original['bodyHex'] as String), reason: reason);
      expect(plan.nativeOption101c20240, (original['options'] as Map)['value101c20240'], reason: reason);
    }
  });
}
