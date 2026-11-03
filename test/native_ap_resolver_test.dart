import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_ap_resolver.dart';
import 'package:spotify_flutter/protocol/native_ap_system_info.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-ap-resolver.json').readAsStringSync()) as Map<String, dynamic>;

  test('Resolver identity selection matches original platform, product and OS override branches', () {
    final profiles = jsonDecode(File('reverse-engineering/fixtures/native-ap-resolver-profile.json').readAsStringSync()) as Map<String, dynamic>;
    for (final row in (profiles['cases'] as List).cast<Map<String, dynamic>>()) {
      final facts = row['facts'] as Map<String, dynamic>;
      final version = (facts['version'] as List).cast<int>();
      final systemInfo = NativeApSystemInfo.fromFacts(NativeApSystemFacts(
        majorVersion: version[0], minorVersion: version[1], patchVersion: version[2],
        cpuType: facts['cpuType'] as int, cpuSubtype: facts['cpuSubtype'] as int,
        gestaltSucceeded: facts['gestaltFailureAt'] == null));
      final profile = NativeApResolverProfile.fromNativeIdentity(
        versionValue: row['versionValue'] as int, systemInfo: systemInfo,
        endpointTypes: const [0], platformOverride: row['platform'] as int?,
        productOverride: row['product'] as int?, osOverride: row['os'] as int?);
      final original = row['original'] as Map<String, dynamic>;
      expect([profile.versionValue, profile.byte4, profile.value8, profile.byte12],
        [original['versionValue'], original['byte4'], original['value8'], original['byte12']],
        reason: row['name'] as String);
    }
  });

  test('Resolver envelopes match original owner query bytes and UA while retaining the explicit caller template', () {
    final template = RequestEnvelope(method: 'PATCH', url: 'https://unused-template.test/',
      headers: const {'uSeR-aGeNt': 'replaced', 'Authorization': 'synthetic-inherited', 'X-Fixture': 'kept'},
      body: const [0, 255], authorize: false, includeCredentials: true,
      responseType: 'bytes', nativeTimeoutMilliseconds: 17000);
    for (final row in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final original = row['original'] as Map<String, dynamic>;
      var reads = 0;
      final resolver = NativeApResolver(template: template,
        profile: NativeApResolverProfile(versionValue: row['versionValue'] as int,
          byte4: row['byte4'] as int, value8: row['value8'] as int, byte12: row['byte12'] as int,
          endpointTypes: (row['endpointTypes'] as List).cast<int>(),
          urlOverride: row['urlOverride'] as String?, site: row['site'] as String?),
        nowMicroseconds: () => (row['nowMicroseconds'] as int) + 1000000 * reads++);
      final plan = resolver.plan(context: 0x1234);
      expect(plan.request.toJson(), {
        'method': 'PATCH', 'url': original['url'],
        'headers': {'uSeR-aGeNt': (original['headers'] as Map<String, dynamic>)['User-Agent'],
          'Authorization': 'synthetic-inherited', 'X-Fixture': 'kept'},
        'bodyBase64': 'AP8=', 'authorize': false, 'includeCredentials': true,
        'responseType': 'bytes', 'nativeTimeoutMilliseconds': 17000,
      }, reason: row['name'] as String);
      expect(reads, original['clockReads'], reason: row['name'] as String);
      expect(plan.option101c20240, original['option101c20240']);
      expect(plan.context, original['opaqueContext']);
    }
  });

  test('Resolver v2 response endpoints and failures match the original response callback', () {
    for (final row in (fixture['responseCases'] as List).cast<Map<String, dynamic>>()) {
      final original = row['original'] as Map<String, dynamic>;
      List<NativeApResolverEndpoint> decode() => decodeNativeApResolverResponse(
        status: row['status'] as int, body: utf8.encode(row['body'] as String));
      if (original.containsKey('errorCode')) {
        expect(decode, throwsA(isA<NativeApResolverFailure>().having((error) => error.code, 'code', original['errorCode'])),
          reason: row['name'] as String);
      } else if (original.containsKey('exceptionBoundary')) {
        expect(decode, throwsFormatException, reason: row['name'] as String);
      } else {
        expect(decode().map((endpoint) => {'type': endpoint.type, 'host': endpoint.host, 'port': endpoint.port}).toList(),
          original['endpoints'], reason: row['name'] as String);
      }
    }
  });
}
