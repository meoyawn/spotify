import 'dart:convert';
import 'dart:typed_data';

import 'generated/spotify/login5/v3/client_info.pb.dart' as info;
import 'generated/spotify/login5/v3/credentials/credentials.pb.dart' as credentials;
import 'generated/spotify/login5/v3/identifiers/identifiers.pb.dart' as identifiers;
import 'generated/spotify/login5/v3/login5.pb.dart' as proto;

sealed class NativeLogin5Credential {
  const NativeLogin5Credential();
}

final class NativeLogin5Password extends NativeLogin5Credential {
  const NativeLogin5Password({required this.id, required this.password});
  final String id, password;
}

final class NativeLogin5StoredCredential extends NativeLogin5Credential {
  NativeLogin5StoredCredential({required this.username, required List<int> data})
    : data = Uint8List.fromList(data).asUnmodifiableView();
  final String username;
  final Uint8List data;
}

final class NativeLogin5FacebookAccessToken extends NativeLogin5Credential {
  const NativeLogin5FacebookAccessToken({required this.userId, required this.accessToken});
  final String userId, accessToken;
}

final class NativeLogin5PhoneNumber extends NativeLogin5Credential {
  const NativeLogin5PhoneNumber({required this.number, required this.isoCountryCode,
    required this.countryCallingCode});
  final String number, isoCountryCode, countryCallingCode;
}

final class NativeLogin5AppleSignIn extends NativeLogin5Credential {
  const NativeLogin5AppleSignIn({required this.authCode, required this.redirectUri, required this.bundleId});
  final String authCode, redirectUri, bundleId;
}

final class NativeLogin5GoogleSignIn extends NativeLogin5Credential {
  const NativeLogin5GoogleSignIn({required this.authCode, required this.redirectUri});
  final String authCode, redirectUri;
}

final class NativeLogin5OneTimeToken extends NativeLogin5Credential {
  const NativeLogin5OneTimeToken({required this.token});
  final String token;
}

final class NativeLogin5ParentChildCredential extends NativeLogin5Credential {
  NativeLogin5ParentChildCredential({required this.childId, required this.parentUsername,
    required List<int> parentData}) : parentData = Uint8List.fromList(parentData).asUnmodifiableView();
  final String childId, parentUsername;
  final Uint8List parentData;
}

final class NativeLogin5SamsungSignIn extends NativeLogin5Credential {
  const NativeLogin5SamsungSignIn({required this.authCode, required this.redirectUri,
    required this.tokenEndpointUrl});
  final String authCode, redirectUri, tokenEndpointUrl;
}

/// Credential body construction at 0x1018bb6a4. This component owns no sender,
/// account state, challenge continuation, or response/error decoder.
class NativeLogin5Credentials {
  const NativeLogin5Credentials({required this.clientId, required this.deviceId});
  final String clientId, deviceId;

  /// Selected message presence and ordinary default omission follow original
  /// constructor/serializer captures, without assuming other Login5 fields.
  proto.LoginRequest build(NativeLogin5Credential credential) {
    final request = proto.LoginRequest(clientInfo: info.ClientInfo(
      clientId: _text(clientId), deviceId: _text(deviceId)));
    switch (credential) {
      case NativeLogin5Password(:final id, :final password):
        final paddingLength = 64 - ((utf8.encode(id).length + utf8.encode(password).length) % 64);
        request.password = credentials.Password(id: _text(id), password: _text(password),
          padding: Uint8List.fromList(List.filled(paddingLength, paddingLength)));
      case NativeLogin5StoredCredential(:final username, :final data):
        request.storedCredential = credentials.StoredCredential(username: _text(username), data: _bytes(data));
      case NativeLogin5FacebookAccessToken(:final userId, :final accessToken):
        request.facebookAccessToken = credentials.FacebookAccessToken(fbUid: _text(userId), accessToken: _text(accessToken));
      case NativeLogin5PhoneNumber(:final number, :final isoCountryCode, :final countryCallingCode):
        request.phoneNumber = identifiers.PhoneNumber(number: _text(number), isoCountryCode: _text(isoCountryCode),
          countryCallingCode: _text(countryCallingCode));
      case NativeLogin5AppleSignIn(:final authCode, :final redirectUri, :final bundleId):
        request.appleSignInCredential = credentials.AppleSignInCredential(authCode: _text(authCode),
          redirectUri: _text(redirectUri), bundleId: _text(bundleId));
      case NativeLogin5GoogleSignIn(:final authCode, :final redirectUri):
        request.googleSignInCredential = credentials.GoogleSignInCredential(authCode: _text(authCode), redirectUri: _text(redirectUri));
      case NativeLogin5OneTimeToken(:final token):
        request.oneTimeToken = credentials.OneTimeToken(token: _text(token));
      case NativeLogin5ParentChildCredential(:final childId, :final parentUsername, :final parentData):
        request.parentChildCredential = credentials.ParentChildCredential(childId: _text(childId),
          parentStoredCredential: credentials.StoredCredential(username: _text(parentUsername), data: _bytes(parentData)));
      case NativeLogin5SamsungSignIn(:final authCode, :final redirectUri, :final tokenEndpointUrl):
        request.samsungSignInCredential = credentials.SamsungSignInCredential(authCode: _text(authCode),
          redirectUri: _text(redirectUri), tokenEndpointUrl: _text(tokenEndpointUrl));
    }
    return request;
  }

  Uint8List encode(NativeLogin5Credential credential) => build(credential).writeToBuffer();
}

String? _text(String value) => value.isEmpty ? null : value;
List<int>? _bytes(List<int> value) => value.isEmpty ? null : List<int>.of(value);
