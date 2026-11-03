import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/generated/es_auth_blob.pb.dart';
import 'package:spotify_flutter/protocol/generated/es_encrypted_stored_credentials.pb.dart';
import 'package:spotify_flutter/protocol/generated/es_stored_user_info.pb.dart';
import 'package:spotify_flutter/protocol/generated/es_unencrypted_stored_credentials.pb.dart';
import 'package:spotify_flutter/protocol/native_auth_blob_mapper.dart';
import 'package:spotify_flutter/protocol/native_legacy_auth_codec.dart';
import 'package:spotify_flutter/protocol/native_protobuf.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16)]);

void main() {
  final native = jsonDecode(File('reverse-engineering/evidence/native-legacy-auth.json').readAsStringSync()) as Map;
  final projection = jsonDecode(File('reverse-engineering/evidence/native-auth-blob-mapper.json').readAsStringSync()) as Map;

  test('AuthStorageClient selection follows original presence, username and device ownership', () {
    for (final scenario in native['authBlobSelections'] as List) {
      final encrypted = scenario['encrypted'] as Map?, unencrypted = scenario['unencrypted'] as Map?;
      final blob = AuthBlob(storedCredentials: encrypted == null ? null : EncryptedStoredCredentials(
          username: encrypted['username'] as String, authBlob: _hex(encrypted['blobHex'] as String),
          deviceId: encrypted['deviceId'] as String),
        unencryptedStoredCredentials: unencrypted == null ? null : UnencryptedStoredCredentials(
          username: unencrypted['username'] as String, storedCredentials: _hex(unencrypted['dataHex'] as String)));
      final mapper = NativeAuthBlobMapper(deviceId: scenario['ownerDevice'] as String);
      final selected = mapper.selectStoredUserInfo(StoredUserInfo(username: scenario['outerUsername'] as String,
        authBlob: blob));
      final expected = scenario['storedUserInfo'] as Map?;
      expect(selected != null, expected != null, reason: scenario['name'] as String);
      if (selected != null) {
        expect(selected.username, expected!['username']);
        expect(selected.encodedBlob, _hex(expected['blobHex'] as String));
        expect(selected.deviceId, expected['deviceId']);
      }
      final update = mapper.selectUpdate(blob);
      final expectedUpdate = scenario['authBlobUpdate'] as Map?;
      expect(update != null, expectedUpdate != null, reason: scenario['name'] as String);
      if (update != null) {
        expect(update.encodedBlob, _hex(expectedUpdate!['blobHex'] as String));
        expect(update.deviceId, expectedUpdate['deviceId']);
      }
    }
  });

  test('AuthStorageClient projection matches original fields and independent C++ protobuf bytes', () {
    final mapper = NativeAuthBlobMapper(deviceId: 'unused-owner-device');
    for (final scenario in projection['cases'] as List) {
      final input = scenario['input'] as Map?;
      final source = input == null ? null : NativeLegacyStoredCredentials(username: input['username'] as String,
        encodedBlob: _hex(input['blobHex'] as String), deviceId: input['deviceId'] as String);
      expect(nativeProto3Bytes(mapper.project(source)), _hex(scenario['wireHex'] as String),
        reason: scenario['name'] as String);
    }
  });
}
