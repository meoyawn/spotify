import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-login5-credentials.json').readAsStringSync()) as Map<String, dynamic>;

  test('Credential request bodies match original constructor and serializer bytes across supported variants', () {
    for (final item in fixture['cases'] as List<dynamic>) {
      final row = item as Map<String, dynamic>;
      final expected = row['result'] as Map<String, dynamic>;
      if (expected['status'] != 0) continue;
      final builder = NativeLogin5Credentials(clientId: row['clientId'] as String, deviceId: row['deviceId'] as String);
      final credential = _credential(row['credential'] as Map<String, dynamic>);
      expect(hex.encode(builder.encode(credential)), expected['hex'], reason: row['name'] as String);
    }
  });
}

NativeLogin5Credential _credential(Map<String, dynamic> input) {
  String text(String name) => input[name] as String;
  List<int> bytes(String name) => hex.decode(text(name));
  switch (input['variant']) {
    case 'password': return NativeLogin5Password(id: text('id'), password: utf8.decode(bytes('secretHex')));
    case 'stored': return NativeLogin5StoredCredential(username: text('id'), data: bytes('secretHex'));
    case 'facebook': return NativeLogin5FacebookAccessToken(userId: text('id'), accessToken: utf8.decode(bytes('secretHex')));
    case 'phone': return NativeLogin5PhoneNumber(number: text('number'), isoCountryCode: text('isoCountryCode'), countryCallingCode: text('countryCallingCode'));
    case 'apple': return NativeLogin5AppleSignIn(authCode: text('authCode'), redirectUri: text('redirectUri'), bundleId: text('bundleId'));
    case 'google': return NativeLogin5GoogleSignIn(authCode: text('authCode'), redirectUri: text('redirectUri'));
    case 'oneTime': return NativeLogin5OneTimeToken(token: text('token'));
    case 'parentChild': return NativeLogin5ParentChildCredential(childId: text('childId'), parentUsername: text('parentUsername'), parentData: bytes('parentDataHex'));
    case 'samsung': return NativeLogin5SamsungSignIn(authCode: text('authCode'), redirectUri: text('redirectUri'), tokenEndpointUrl: text('tokenEndpointUrl'));
    default: throw StateError('Unsupported successful fixture credential');
  }
}
