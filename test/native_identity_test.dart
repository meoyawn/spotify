import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/desktop_identity.dart';
import 'package:spotify_flutter/protocol/platform_identity.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-user-agent.json')
    .readAsStringSync()) as Map;
  for (final scenario in fixture['cases'] as List) {
    test('Native user agent preserves ${scenario['hardwareModel']} / ${scenario['userAgentOverride']}', () {
      expect(DesktopIdentity.nativeUserAgent(scenario['hardwareModel'] as String,
        userAgentOverride: scenario['userAgentOverride'] as String),
        scenario['userAgent']);
    });
  }

  test('In-process macOS metadata agrees with the independent system utility', () async {
    final expected = await Process.run('/usr/sbin/sysctl', ['-n', 'hw.model']);
    expect(expected.exitCode, 0, reason: expected.stderr.toString());
    final identity = MacOSPlatformIdentity.readCurrent();
    expect(identity.hardwareModel, (expected.stdout as String).trimRight());
    expect(identity.nativeUserAgent, DesktopIdentity.nativeUserAgent(identity.hardwareModel));
  }, skip: !Platform.isMacOS);
}
