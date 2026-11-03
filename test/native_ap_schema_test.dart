import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:protobuf/protobuf.dart' show CodedBufferReader;
import 'package:spotify_flutter/playback/generated/authentication.pb.dart' as auth;
import 'package:spotify_flutter/playback/generated/keyexchange.pb.dart' as key;
import 'package:spotify_flutter/playback/spotify_ap_handshake.dart';
import 'package:spotify_flutter/protocol/native_ap_hello.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-ap-schemas.json').readAsStringSync()) as Map;

  test('Reference-derived AP overlays expose every native addition and preserve original writer presence and bytes', () {
    final helloWire = _hex(fixture['nativeFullFeatureSetHelloHex'] as String);
    final hello = key.ClientHello.fromBuffer(helloWire);
    expect(hello.isInitialized(), isTrue);
    final features = hello.featureSet;
    expect(features.hasCurrentLocation(), isTrue);
    expect(features.currentLocation, isFalse);
    expect(features.hasNativeField3(), isTrue);
    final child = features.nativeField3;
    expect([child.hasNativeField1(), child.hasNativeField2(),
      child.hasNativeField3(), child.hasNativeField4()], everyElement(isTrue));
    expect([child.nativeField1, child.nativeField2, child.nativeField3, child.nativeField4],
      [false, true, false, true]);
    expect(features.hasNativeField4(), isTrue);
    expect(features.nativeField4, isTrue);
    expect(features.hasNativeField5(), isTrue);
    expect(features.nativeField5.hasNativeField1(), isTrue);
    expect(features.nativeField5.nativeField1, isFalse);
    expect(hello.writeToBuffer(), helloWire);

    final loginWire = _hex(fixture['nativeAuthenticationHex'] as String);
    final login = auth.ClientResponseEncrypted.fromBuffer(loginWire);
    expect(login.isInitialized(), isTrue);
    expect(login.hasNativeField11(), isTrue);
    expect(login.nativeField11, 'synthetic-extra');
    expect(login.loginCredentials.hasNativeField40(), isTrue);
    expect(login.loginCredentials.nativeField40, [0xaa, 0, ...utf8.encode('padding')]);
    expect(login.clientInfo.hasLimited(), isTrue);
    expect(login.clientInfo.limited, isFalse);
    expect(login.clientInfo.hasNativeField4(), isTrue);
    expect(login.clientInfo.nativeField4, 'synthetic-client-field-four');
    expect(login.clientInfo.hasNativeField5(), isTrue);
    expect(login.clientInfo.nativeField5, 'synthetic-client-extra');
    expect(login.writeToBuffer(), loginWire);
  });

  test('Native hello factory matches original profile/features and binds a private AES nonce key without reference enum coercion', () {
    // Explicit synthetic profile values from the original instruction oracle,
    // not a default identity for a desktop session.
    final generated = createNativeApHello(NativeApHelloProfile(
      product: 0, platform: 9, version: 0x12345678, featureFlags: 4));
    addTearDown(generated.close);
    final expected = key.ClientHello.fromBuffer(_hex(fixture['nativeExtendedHelloHex'] as String));
    final normalized = generated.hello.deepCopy()
      ..loginCryptoHello = expected.loginCryptoHello.deepCopy()
      ..clientNonce = expected.clientNonce
      ..padding = expected.padding;
    expect(normalized.writeToBuffer(), expected.writeToBuffer());
    expect(generated.hello.padding.length, inInclusiveRange(1, 255));
    final plaintext = Uint8List(16);
    final aes = AESEngine()..init(false, KeyParameter(generated.nonceKey));
    aes.processBlock(Uint8List.fromList(generated.hello.clientNonce), 0, plaintext, 0);
    expect(plaintext, List.filled(16, 0));

    final profiles = (jsonDecode(File('reverse-engineering/fixtures/native-ap-hello-profile.json')
      .readAsStringSync()) as Map)['cases'] as List;
    final reference = NativeApHelloProfile.referenceDesktop();
    final desktop = createNativeApHello(reference);
    addTearDown(desktop.close);
    expect(reference.featureFlags, (profiles[0] as Map)['profile']['featureFlags']);
    final foreignProfile = (profiles[1] as Map)['profile'] as Map;
    final foreign = createNativeApHello(NativeApHelloProfile(
      product: foreignProfile['product'] as int,
      platform: foreignProfile['platform'] as int,
      version: foreignProfile['version'] as int,
      featureFlags: foreignProfile['featureFlags'] as int));
    addTearDown(foreign.close);
    for (var index = 0; index < profiles.length; index++) {
      final owner = [desktop, foreign][index];
      final profile = (profiles[index] as Map)['profile'] as Map;
      expect(owner.hello.featureSet.hasNativeField3(), isTrue);
      expect(owner.hello.featureSet.nativeField3.hasNativeField4(),
        ((profile['featureFlags'] as int) & 4) != 0);
      final handshake = SpotifyApHandshake(clientHello: owner.hello);
      addTearDown(handshake.close);
      final reader = CodedBufferReader(handshake.clientHelloFrame.sublist(6));
      List<int>? buildBytes;
      while (!reader.isAtEnd()) {
        final tag = reader.readTag();
        if (tag == 82) { buildBytes = reader.readBytes(); }
        else if (!reader.skipField(tag)) { break; }
      }
      final buildReader = CodedBufferReader(buildBytes!);
      final raw = <int, int>{};
      while (!buildReader.isAtEnd()) {
        final tag = buildReader.readTag();
        raw[tag >> 3] = buildReader.readUint64().toInt();
      }
      expect(raw, {10: profile['product'], 20: 0,
        30: profile['platform'], 40: profile['version']});
    }
    generated.close();
    generated.close();
    expect(() => generated.nonceKey, throwsStateError);
  });
}
