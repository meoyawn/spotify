import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/generated/keyexchange.pb.dart' as key;
import 'package:spotify_flutter/protocol/native_ap_authentication.dart';
import 'package:spotify_flutter/protocol/native_ap_system_info.dart';
import 'package:spotify_flutter/protocol/native_legacy_auth_codec.dart';
import 'package:spotify_flutter/protocol/native_login5_response.dart';
import 'package:spotify_flutter/protocol/platform_identity.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-ap-authentication.json').readAsStringSync()) as Map;
  final desktop = jsonDecode(File('reverse-engineering/fixtures/native-ap-desktop-authentication.json').readAsStringSync()) as Map;
  final producers = jsonDecode(File('reverse-engineering/fixtures/native-ap-credential-producers.json').readAsStringSync()) as Map;
  Future<void> compare(List cases) async {
    for (final item in cases) {
      final row = item as Map, values = row['profile'] as Map;
      final facts = row['facts'] as Map, version = facts['version'] as List;
      final credential = row['credential'] as Map;
      final system = NativeApSystemInfo.fromFacts(NativeApSystemFacts(
        majorVersion: version[0] as int, minorVersion: version[1] as int,
        patchVersion: version[2] as int, cpuType: facts['cpuType'] as int,
        cpuSubtype: facts['cpuSubtype'] as int));
      final random = _FixtureRandom();
      final profile = row['freshDesktopProfile'] == true
        ? NativeApAuthenticationProfile.freshDesktop(deviceId: values['deviceId'] as String,
            language: values['language'] as String, systemInfo: system,
            platformIdentity: MacOSPlatformIdentity(hardwareModel: values['platformModel'] as String))
        : NativeApAuthenticationProfile(
        systemInfo: system.toMessage(deviceId: values['deviceId'] as String),
        nativeField11: values['nativeField11'] as String,
        platformModel: values['platformModel'] as String,
        versionString: values['versionString'] as String,
        language: values['language'] as String, nativeField5: values['nativeField5'] as String);
      final producer = row['credentialProducer'] as String?;
      final NativeLegacyCredential selected;
      if (producer != null) {
        final input = row['producerInput'] as Map;
        selected = producer == 'login5-success'
          ? NativeLegacyCredential.login5Success(NativeLogin5Success(
              username: input['username'] as String, accessToken: input['accessToken'] as String,
              storedCredential: _hex(input['storedCredentialHex'] as String), expiresAtMicroseconds: 1000000))
          : producer == 'accounts'
          ? NativeLegacyCredential.accountsAccessToken(username: input['username'] as String,
              accessToken: input['accessToken'] as String)
          : NativeLegacyCredential.desktopAccessToken(input['accessToken'] as String);
      } else {
        selected = NativeLegacyCredential(username: credential['username'] as String,
          authenticationType: credential['authenticationType'] as int,
          data: _hex(credential['dataHex'] as String));
      }
      final builder = NativeApAuthentication(profile: profile, credential: selected,
        nonceKey: _hex(row['nonceKeyHex'] as String), random: random);
      final serverFrame = _hex(row['serverFrameHex'] as String);
      final response = key.APResponseMessage.fromBuffer(Uint8List.sublistView(serverFrame, 4));
      final result = await builder.build(challenge: response.challenge,
        clientHelloFrame: _hex(row['clientFrameHex'] as String),
        serverResponseFrame: serverFrame, dhHmac: _hex(row['dhHmacHex'] as String));
      final expectedPlain = _hex(row['plainFrameHex'] as String);
      expect(result.plaintext.writeToBuffer(), Uint8List.sublistView(expectedPlain, 4), reason: row['name'] as String);
      expect(result.encrypted.writeToBuffer(), _hex(row['encryptedHex'] as String), reason: row['name'] as String);
      final draws = (row['randomDraws'] as List).cast<String>();
      expect(random.count, draws.fold<int>(0, (count, value) => count + value.length ~/ 2), reason: row['name'] as String);
    }
  }
  test('AP authentication messages and entropy consumption match the unchanged whole native builder',
    () => compare(fixture['cases'] as List));
  test('Fresh desktop profile produces the original complete outgoing AP authentication bytes',
    () => compare(desktop['cases'] as List));
  test('Native credential producers match complete outgoing AP authentication bytes',
    () => compare(producers['cases'] as List));
}

class _FixtureRandom implements Random {
  var count = 0;
  @override
  int nextInt(int max) {
    if (max != 256) throw StateError('The native fixture supplies uniform bytes');
    return (0xa0 + count++) & 255;
  }
  @override
  bool nextBool() => throw UnsupportedError('The fixture supplies only bytes');
  @override
  double nextDouble() => throw UnsupportedError('The fixture supplies only bytes');
}
