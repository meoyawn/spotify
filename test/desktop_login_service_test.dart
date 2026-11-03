import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/protobuf.dart';
import 'package:spotify_flutter/protocol/desktop_login_service.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';

class _Access implements DesktopLoginAccess {
  _Access(Map scenario) : username = scenario['username'] as String,
    accounts = (scenario['accounts'] as List).cast<Map>().map((row) => DesktopStoredAccount(
      username: row['username'] as String, canonicalUsername: row['canonicalUsername'] as String)).toList(),
    target = scenario['initialSwitchTarget'] as String,
    saveSucceeds = scenario['saveSucceeds'] as bool;
  final String username;
  final List<DesktopStoredAccount> accounts;
  String target;
  final bool saveSucceeds;
  final events = <String>[];
  final removals = <String>[];
  @override
  bool saveCurrentCredentials() { events.add('saveCurrentCredentials'); return saveSucceeds; }
  @override
  void clearAllStoredCredentials() { events.add('clearAllStoredCredentials'); }
  @override
  void removeStoredAccount(String value) { events.add('removeStoredAccount'); removals.add(value); }
  @override
  String currentUsername() { events.add('currentUsername'); return username; }
  @override
  List<DesktopStoredAccount> storedAccounts() { events.add('storedAccounts'); return accounts; }
  @override
  void setSwitchTarget(String value) { events.add('setSwitchTarget'); target = value; }
  @override
  String switchTarget() { events.add('switchTarget'); return target; }
  @override
  void clearSwitchTarget() { events.add('clearSwitchTarget'); target = ''; }
}

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-desktop-login.json').readAsStringSync()) as Map;

  test('DesktopLogin local calls match original handler projections and C++ response bytes', () async {
    for (final scenario in (fixture['scenarios'] as List).cast<Map>()) {
      final access = _Access(scenario);
      final dispatcher = EsperantoDispatcher();
      DesktopLoginService(access).register(dispatcher);
      for (final step in (scenario['operations'] as List).cast<Map>()) {
        final response = await dispatcher.callSingle(EsperantoCall(DesktopLoginService.id,
          step['method'] as String, hex.decode(step['requestHex'] as String)));
        expect(hex.encode(response), step['responseHex'], reason: '${scenario['name']}: ${step['method']}');
      }
      expect(access.events, scenario['nativeAccessorEvents'], reason: scenario['name'] as String);
      expect(access.removals, scenario['nativeRemovalArguments'], reason: scenario['name'] as String);
    }
  });

  test('Native-invalid request strings fail before local mutations', () async {
    final scenario = (fixture['scenarios'] as List).first as Map;
    final access = _Access(scenario);
    final dispatcher = EsperantoDispatcher();
    DesktopLoginService(access).register(dispatcher);
    for (final row in (fixture['rejectedRequests'] as List).cast<Map>()) {
      await expectLater(dispatcher.callSingle(EsperantoCall(DesktopLoginService.id,
        row['method'] as String, hex.decode(row['requestHex'] as String))),
        throwsA(anyOf(isA<InvalidProtocolBufferException>(), isA<FormatException>())));
    }
    expect(access.events, isEmpty);
    expect(access.removals, isEmpty);
    expect(access.target, scenario['initialSwitchTarget']);
  });
}
