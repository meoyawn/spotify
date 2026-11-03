import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:pointycastle/digests/sha1.dart' show SHA1Digest;
import 'package:pointycastle/key_derivators/api.dart' show Pbkdf2Parameters;
import 'package:pointycastle/key_derivators/pbkdf2.dart' show PBKDF2KeyDerivator;
import 'package:pointycastle/macs/hmac.dart' show HMac;
import 'package:protobuf/protobuf.dart' show CodedBufferReader, CodedBufferWriter,
  InvalidProtocolBufferException, PbFieldType;

import 'native_base64.dart';
import 'native_login5_response.dart' show NativeLogin5Success;

/// The legacy common stored model: its blob contains Base64 bytes, not the
/// separate fixed-key event-payload frame. All inputs belong to the caller.
final class NativeLegacyStoredCredentials {
  NativeLegacyStoredCredentials({required this.username, required List<int> encodedBlob,
    required this.deviceId}) : encodedBlob = Uint8List.fromList(encodedBlob).asUnmodifiableView();
  factory NativeLegacyStoredCredentials.empty() => NativeLegacyStoredCredentials(
    username: '', encodedBlob: const [], deviceId: '');
  final String username;
  final Uint8List encodedBlob;
  final String deviceId;
}

final class NativeLegacyCredential {
  NativeLegacyCredential({required this.username, required this.authenticationType, required List<int> data})
    : data = Uint8List.fromList(data).asUnmodifiableView();

  /// Accounts success callback 0x10192b924. The username belongs to the
  /// acquisition's captured context, separately from its returned access token.
  /// Only invoke after that operation succeeds; this is not a generic token or
  /// Login5 stored-credential conversion. Neither field is trimmed or prefixed.
  factory NativeLegacyCredential.accountsAccessToken({required String username,
    required String accessToken}) => NativeLegacyCredential(username: username,
      authenticationType: 3, data: utf8.encode(accessToken));

  /// Desktop token adapters 0x1003fd0dc / 0x1004053e4 supply an empty username.
  /// The AP authentication builder owns its later kind-3 anonymous-name rule.
  factory NativeLegacyCredential.desktopAccessToken(String accessToken) =>
    NativeLegacyCredential.accountsAccessToken(username: '', accessToken: accessToken);

  /// Normal Login5 success continuation 0x10192a1b0. The native owner encodes
  /// and restores the returned stored bytes with kind 1 and the same device
  /// identity; its separate access token is not AP authentication data.
  /// The caller selects the ordinary AP continuation branch. Empty username
  /// or stored bytes restore the native invalid common model (kind -1).
  factory NativeLegacyCredential.login5Success(NativeLogin5Success result) =>
    result.username.isEmpty || result.storedCredential.isEmpty
      ? NativeLegacyCredential(username: '', authenticationType: -1, data: const [])
      : NativeLegacyCredential(username: result.username, authenticationType: 1,
          data: result.storedCredential);

  final String username;
  final int authenticationType;
  final Uint8List data;
}

/// Proprietary 0x101938a6c/0x101938e98/0x101938fd8. This is a pure byte codec;
/// it does not open preferences, restore a session or enable remote traffic.
class NativeLegacyAuthCodec {
  NativeLegacyStoredCredentials encode({required String username, required List<int> data,
    required String deviceId, int authenticationType = 1}) {
    final kind = authenticationType.toSigned(32);
    if (username.isEmpty || kind == 0 || kind == 8) return NativeLegacyStoredCredentials.empty();
    final user = utf8.encode(username);
    final credential = Uint8List.fromList(data);
    // This is Spotify's compact delta-field stream, not protobuf wire. Reuse
    // the standard runtime's varint primitive separately from its field tags.
    final plaintext = (BytesBuilder(copy: false)..addByte(0x49)..add(_varint(user.length))..add(user)
      ..addByte(0x50)..add(_varint(kind, signed: true))
      ..addByte(0x51)..add(_varint(credential.length))..add(credential)).takeBytes();
    final padding = 16 - plaintext.length % 16;
    final padded = Uint8List(plaintext.length + padding)..setRange(0, plaintext.length, plaintext);
    padded[padded.length - 1] = padding;
    for (var i = 16; i < padded.length; i++) { padded[i] ^= padded[i - 16]; }
    final encrypted = _ecb(_key(username, deviceId), padded, true);
    return NativeLegacyStoredCredentials(username: username, deviceId: deviceId,
      encodedBlob: ascii.encode(base64.encode(encrypted)));
  }

  NativeLegacyCredential? decode(NativeLegacyStoredCredentials stored) {
    if (stored.encodedBlob.isEmpty) return null;
    final encrypted = decodeNativeBase64(latin1.decode(stored.encodedBlob));
    if (encrypted == null || encrypted.isEmpty || encrypted.length % 16 != 0) return null;
    final clear = _ecb(_key(stored.username, stored.deviceId), encrypted, false);
    for (var i = clear.length - 1; i >= 16; i--) { clear[i] ^= clear[i - 16]; }
    final padding = clear.last;
    if (padding > clear.length) return null;
    // Native strips only the last byte's count: zero and counts over16 are
    // accepted when within the total length; preceding padding is unchecked.
    final plaintext = Uint8List.sublistView(clear, 0, clear.length - padding);
    try {
      final parsed = _CompactReader(plaintext).parse();
      final user = utf8.encode(stored.username);
      if (parsed == null || parsed.data.isEmpty || parsed.username.length != user.length) return null;
      for (var i = 0; i < user.length; i++) { if (parsed.username[i] != user[i]) return null; }
      return NativeLegacyCredential(username: stored.username, authenticationType: parsed.kind, data: parsed.data);
    } on InvalidProtocolBufferException {
      return null;
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }
}

Uint8List _key(String username, String deviceId) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA1Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(utf8.encode(username)), 256, 20));
  final derived = derivator.process(Uint8List.fromList(sha1.convert(utf8.encode(deviceId)).bytes));
  return Uint8List(24)..setRange(0, 20, sha1.convert(derived).bytes)..[23] = 20;
}

Uint8List _ecb(Uint8List key, Uint8List bytes, bool encrypt) {
  final cipher = AESEngine()..init(encrypt, KeyParameter(key));
  final result = Uint8List(bytes.length);
  for (var offset = 0; offset < bytes.length; offset += 16) { cipher.processBlock(bytes, offset, result, offset); }
  return result;
}

Uint8List _varint(int value, {bool signed = false}) {
  // CodedBufferWriter exposes field writing, not a public raw-varint method.
  // Field1's single-byte tag is discarded; its uint32 value is the primitive.
  final writer = CodedBufferWriter()..writeField(1,
    signed ? PbFieldType.O6 : PbFieldType.OU3, signed ? Int64(value) : value);
  final encoded = writer.toBuffer();
  final primitive = Uint8List.sublistView(encoded, 1);
  // The compact stream packs the final eight bits into byte9, unlike
  // protobuf's seven-bit byte9 plus one-bit byte10 for negative int64 values.
  if (primitive.length == 10) {
    return Uint8List.fromList([...primitive.sublist(0, 8), (primitive[8] & 0x7f) | ((primitive[9] & 1) << 7)]);
  }
  return primitive;
}

final class _Parsed {
  _Parsed(this.username, this.kind, this.data);
  final Uint8List username;
  final int kind;
  final Uint8List data;
}

/// Native compact helpers 0x101cf5c20/6044/6094/6bb8 and model0x1019394f0.
/// Standard protobuf readers handle only raw unsigned-varint primitives here.
final class _CompactReader {
  _CompactReader(this.bytes);
  final Uint8List bytes;
  int offset = 0;
  int tag = 8;
  int depth = 1;
  bool endedByEof = false;

  int _unsigned({bool wide = false}) {
    final start = offset;
    while (true) {
      if (offset >= bytes.length) throw const FormatException('Truncated compact varint');
      if (bytes[offset++] < 128 || offset - start == 9) break;
    }
    final primitive = Uint8List.sublistView(bytes, start, offset);
    final expanded = primitive.length == 9 && primitive.last >= 128 ? Uint8List.fromList([
      ...primitive.sublist(0, 8), primitive.last & 0x7f, 1]) : primitive;
    final reader = CodedBufferReader(expanded);
    return wide ? reader.readUint64().toInt() : reader.readUint32();
  }

  Uint8List _take(int length) {
    if (length < 0 || length > bytes.length - offset) throw const FormatException('Truncated compact value');
    final result = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return result;
  }

  int _next() {
    if (offset == bytes.length) { endedByEof = true; return tag = 0; }
    endedByEof = false;
    final first = bytes[offset];
    if (first < 0x78) { offset++; return tag = ((tag & 0xfffffff8) + first) & 0xffffffff; }
    if (first < 0x80) { offset++; return tag = first & 7; }
    return tag = _unsigned();
  }

  void _skip() {
    switch (tag & 7) {
      case 0: _unsigned(wide: true); return;
      case 1: _take(_unsigned()); return;
      case 2: _take(4); return;
      case 3: _take(8); return;
      case 4:
        if (depth == 64) throw const FormatException('Compact recursion limit');
        final parent = tag;
        depth++;
        tag = 8;
        while (_next() != 0) { _skip(); }
        if (endedByEof) throw const FormatException('Unterminated compact group');
        depth--;
        tag = parent;
        return;
      case 5:
        final header = _unsigned();
        final wire = header & 7;
        for (var count = header >> 3; count > 0; count--) {
          tag = (tag & 0xfffffff8) | wire;
          _skip();
        }
        return;
      default: throw const FormatException('Unknown compact wire kind');
    }
  }

  bool _want(int wire) {
    if ((tag & 7) == wire) return true;
    if ((tag & 7) != 5) { _skip(); return false; }
    final header = _unsigned();
    final count = header >> 3;
    if ((header & 7) == wire) {
      if (count == 0) return false;
      // Match the original mismatch helper, including its use of the current
      // packed tag while discarding all but the final scalar occurrence.
      for (var remaining = count - 1; remaining > 0; remaining--) { _skip(); }
      return true;
    }
    for (var remaining = count; remaining > 0; remaining--) {
      tag = (tag & 0xfffffff8) | (header & 7);
      _skip();
    }
    return false;
  }

  _Parsed? parse() {
    var user = Uint8List(0);
    var data = Uint8List(0);
    var kind = 0;
    var hasKind = false;
    while (true) {
      final field = _next() >> 3;
      if (field == 0) {
        if (tag != 0) continue;
        if (!endedByEof) throw const FormatException('Unexpected compact group end');
        return hasKind ? _Parsed(user, kind, data) : null;
      }
      if (field == 10) {
        if (_want(1)) user = _take(_unsigned());
      } else if (field == 20) {
        if (_want(0)) { kind = _unsigned().toSigned(32); hasKind = true; }
      } else if (field == 30) {
        if (_want(1)) data = _take(_unsigned());
      } else {
        _skip();
      }
    }
  }
}

