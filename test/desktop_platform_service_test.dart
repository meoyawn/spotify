import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/desktop_platform_service.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';
import 'package:spotify_flutter/protocol/generated/es_desktop_platform_info.pb.dart';
import 'package:spotify_flutter/protocol/native_client_data.dart';

DesktopPlatformSettings _settings(Map<String, dynamic> input) => DesktopPlatformSettings(
  locale: input['locale'] as String, isDeveloperMode: input['isDeveloperMode'] as bool);

DesktopPlatformService _service(Map<String, dynamic> input,
    {DesktopPlatformSettings Function()? settings}) {
  final event = input['eventContext'] as Map<String, dynamic>;
  final version = (input['gestaltVersion'] as List).cast<int>();
  return DesktopPlatformService(
    facts: MacOSPlatformFacts(systemVersionString: input['systemVersionString'] as String,
      majorVersion: input['majorVersion'] as int, minorVersion: input['minorVersion'] as int,
      patchVersion: input['patchVersion'] as int, hardwareModel: input['hardwareModel'] as String,
      cpuType: input['cpuType'] as int, cpuSubtype: input['cpuSubtype'] as int),
    gestaltVersion: input['gestaltFailureAt'] == null
      ? MacOSGestaltVersion(version[0], version[1], version[2])
      : const MacOSGestaltVersion(0, 0, 0),
    eventContext: DesktopEventContext(platformType: event['platformType'] as String,
      clientId: event['clientId'] as String, installationId: event['installationId'] as String,
      deviceId: event['deviceId'] as String?, deviceManufacturer: event['deviceManufacturer'] as String?,
      deviceModel: event['deviceModel'] as String?, osVersion: event['osVersion'] as String?,
      clientVersionString: event['clientVersionString'] as String,
      clientVersionInt: event['clientVersionInt'] as int),
    settings: settings ?? () => _settings(input), loadConnectModal: input['loadConnectModal'] as bool,
  );
}

Future<List<int>> _request(EsperantoDispatcher dispatcher) => dispatcher.callSingle(
  EsperantoCall(DesktopPlatformService.id, 'GetPlatformInfo', GetPlatformInfoRequest().writeToBuffer()));

String _hex(List<int> bytes) => bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-platform.json').readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('local platform response preserves native bytes and rereads configuration', () async {
    var current = cases.first['providers'] as Map<String, dynamic>;
    final dispatcher = EsperantoDispatcher();
    _service(current, settings: () => _settings(current)).register(dispatcher);
    for (final scenario in cases.take(2)) {
      current = scenario['providers'] as Map<String, dynamic>;
      expect(_hex(await _request(dispatcher)), scenario['canonicalWireHex'], reason: scenario['name'] as String);
    }
  });

  for (final scenario in cases.skip(2)) {
    test(scenario['name'] as String, () async {
      final dispatcher = EsperantoDispatcher();
      _service(scenario['providers'] as Map<String, dynamic>).register(dispatcher);
      expect(_hex(await _request(dispatcher)), scenario['canonicalWireHex']);
    });
  }

  test('local service preserves all original locale direction decisions', () async {
    var current = _settings(cases.first['providers'] as Map<String, dynamic>);
    final dispatcher = EsperantoDispatcher();
    _service(cases.first['providers'] as Map<String, dynamic>, settings: () => current).register(dispatcher);
    for (final scenario in (fixture['localeScenarios'] as List).cast<Map<String, dynamic>>()) {
      current = DesktopPlatformSettings(locale: scenario['locale'] as String, isDeveloperMode: false);
      final response = PlatformInfoResponse.fromBuffer(await _request(dispatcher));
      expect(response.localizationIsRtl, scenario['isRtl'], reason: 'locale ${scenario['locale']}');
    }
  });
}
