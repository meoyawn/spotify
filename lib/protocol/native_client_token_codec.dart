import 'dart:convert';
import 'dart:math';

import 'package:fixnum/fixnum.dart' show Int64;
import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;

import 'generated/client_token.pb.dart' as stored;
import 'native_base64.dart';
import 'native_client_token_provider.dart';
import 'native_protobuf.dart';
import 'native_storage_framing.dart';

/// Storage codec from 0x1017ccb10/0x1017cccac and proprietary framing
/// 0x101c6ee2c/0x101c6f224. Protobuf, AES-CTR and HMAC-SHA1 use standard packages.
/// The native OS entropy boundary is std::random_device("/dev/urandom");
/// Random.secure supplies the standard secure OS-backed Dart equivalent.
class NativeClientTokenCodec {
  NativeClientTokenCodec({Random? random}) : _framing = NativeStorageFraming(random: random);
  final NativeStorageFraming _framing;

  /// Fits NativeClientTokenProvider.encodeToken directly. Stored times retain
  /// native microseconds; the separate Esperanto mapper uses milliseconds.
  String encode(NativeClientToken token) {
    final plaintext = nativeProto3Bytes(stored.ClientToken(token: token.token,
      expiresAtTimestamp: Int64(token.expiresAtMicroseconds),
      refreshAtTimestamp: Int64(token.refreshAtMicroseconds),
      domains: token.domains.map((domain) => stored.TokenDomain(domain: domain))));
    return base64.encode(_framing.encrypt(utf8.encode(token.clientDataHash), plaintext));
  }

  /// Mirrors the native seed reader's rejected/absent result. The config hash
  /// is supplied by its owner and retained unchanged; it is not serialized.
  NativeClientToken? decode(String encoded, {required String clientDataHash}) {
    final frame = decodeNativeBase64(encoded);
    if (frame == null) return null;
    final plaintext = _framing.decrypt(utf8.encode(clientDataHash), frame);
    if (plaintext == null) return null;
    final stored.ClientToken token;
    try {
      validateNativeProto3Strings(plaintext, stored.ClientToken());
      token = stored.ClientToken.fromBuffer(plaintext);
    } on InvalidProtocolBufferException {
      return null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    return NativeClientToken(token: token.token, expiresAtMicroseconds: token.expiresAtTimestamp.toInt(),
      refreshAtMicroseconds: token.refreshAtTimestamp.toInt(), clientDataHash: clientDataHash,
      domains: token.domains.map((domain) => domain.domain).toList());
  }
}

