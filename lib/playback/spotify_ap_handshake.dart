// Adapted from librespot core/connection/handshake.rs and diffie_hellman.rs.
// Copyright (c) 2015 Paul Lietar
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

import 'generated/keyexchange.pb.dart' as proto;
import 'native_ap_responses.dart';

enum SpotifyApHandshakeFailure { malformed, missingChallenge, unsupportedChallenge, signature, serverRejected, truncated }

final class SpotifyApHandshakeException implements Exception {
  const SpotifyApHandshakeException(this.failure, this.message, {this.untrustedResponse, this.untrustedLoginFailure});
  final SpotifyApHandshakeFailure failure;
  final String message;
  /// Server error/upgrade information is not authenticated by the DH signature.
  /// Use untrustedLoginFailure for numeric errors; generated enum getters cannot
  /// cast values absent from the reference declarations.
  final proto.APResponseMessage? untrustedResponse;
  final NativeApLoginFailure? untrustedLoginFailure;
  @override
  String toString() => 'Spotify AP handshake: ${failure.name}: $message';
}

/// The production transcript KDF. Calling this primitive does not authenticate
/// a server; [SpotifyApHandshake] calls it only after pinned signature checking.
final class SpotifyApHandshakeKeys {
  SpotifyApHandshakeKeys._(this.challenge, this.sendKey, this.receiveKey);
  factory SpotifyApHandshakeKeys.derive({required List<int> sharedSecret, required List<int> transcript}) {
    final secret = _copy(sharedSecret), packets = _copy(transcript);
    if (secret.isEmpty) throw ArgumentError.value(sharedSecret, 'sharedSecret', 'Must not be empty');
    final expanded = BytesBuilder();
    final hmac = crypto.Hmac(crypto.sha1, secret);
    for (var i = 1; i <= 5; i++) { expanded.add(hmac.convert([...packets, i]).bytes); }
    final data = expanded.takeBytes();
    return SpotifyApHandshakeKeys._(
      _copy(crypto.Hmac(crypto.sha1, data.sublist(0, 0x14)).convert(packets).bytes),
      _copy(data.sublist(0x14, 0x34)), _copy(data.sublist(0x34, 0x54)));
  }
  final Uint8List challenge, sendKey, receiveKey;

  /// Native response base. Active fingerprint/PoW challenges still require an
  /// explicit builder; the session validates their responses before sending.
  proto.ClientResponsePlaintext get clientResponse => proto.ClientResponsePlaintext(
      loginCryptoResponse: proto.LoginCryptoResponseUnion(
        diffieHellman: proto.LoginCryptoDiffieHellmanResponse(hmac: challenge)),
      powResponse: proto.PoWResponseUnion(),
      cryptoResponse: proto.CryptoResponseUnion(shannon: proto.CryptoShannonResponse()));
  Uint8List get clientResponseFrame => _frame(clientResponse.writeToBuffer());
}

final class SpotifyApHandshakeResult {
  SpotifyApHandshakeResult._(this.keys, Uint8List trailingBytes,
    this.serverResponse, this.clientHelloFrame, List<int> serverResponseFrame)
    : trailingBytes = _copy(trailingBytes), serverResponseFrame = _copy(serverResponseFrame);
  final SpotifyApHandshakeKeys keys;
  /// Frozen challenge message, exposed only after pinned signature verification.
  final proto.APResponseMessage serverResponse;
  final Uint8List clientHelloFrame;
  /// Original four-byte length and body, without protobuf reserialization.
  final Uint8List serverResponseFrame;
  Uint8List get clientResponseFrame => keys.clientResponseFrame;
  /// Bytes read after the handshake frame belong to the subsequent AP codec.
  final Uint8List trailingBytes;
}

/// A one-use, transport-independent AP handshake. Caller identity is explicit;
/// this owner never selects a product, platform, version or account policy.
final class SpotifyApHandshake {
  factory SpotifyApHandshake({required proto.ClientHello clientHello}) {
    final hello = clientHello.deepCopy();
    if (!hello.hasBuildInfo() || !hello.buildInfo.isInitialized()) {
      throw ArgumentError('Explicit initialized AP BuildInfo is required');
    }
    if (hello.cryptosuitesSupported.length != 1 ||
        hello.cryptosuitesSupported.single != proto.Cryptosuite.CRYPTO_SUITE_SHANNON) {
      throw ArgumentError('Explicit Shannon-only AP cryptosuite support is required');
    }
    if (hello.hasClientNonce() && hello.clientNonce.length != 16) {
      throw ArgumentError('Explicit AP client nonce must contain exactly 16 bytes');
    }
    final random = Random.secure();
    BigInt private;
    do {
      // The pinned reference samples a 95-byte little-endian private exponent.
      private = _integer(List.generate(95, (_) => random.nextInt(256)).reversed.toList());
    } while (private <= BigInt.one);
    hello.loginCryptoHello = proto.LoginCryptoHelloUnion(
      diffieHellman: proto.LoginCryptoDiffieHellmanHello(
        gc: _fixed96(BigInt.two.modPow(private, _dhPrime)), serverKeysKnown: _serverKeysKnown));
    hello.clientNonce = hello.hasClientNonce() ? _copy(hello.clientNonce)
      : List.generate(16, (_) => random.nextInt(256));
    if (!hello.isInitialized()) throw ArgumentError('AP ClientHello is not initialized');
    return SpotifyApHandshake._(private, _frame(hello.writeToBuffer(), hello: true));
  }
  SpotifyApHandshake._(this._private, this.clientHelloFrame);
  static const maxPacketSize = 64 * 1024;
  static const _serverKeysKnown = 1;
  final Uint8List clientHelloFrame;
  BigInt? _private;
  final _header = Uint8List(4);
  int _headerUsed = 0, _bodyUsed = 0;
  Uint8List? _body;
  bool _used = false;

  /// Consumes only the bounded handshake packet, retaining any trailing AP data.
  /// Completion or any failure retires this transcript; retries need a new owner.
  SpotifyApHandshakeResult? addResponse(Uint8List bytes) {
    _requireOpen();
    var offset = 0;
    try {
      if (_headerUsed < 4) {
        final count = min(4 - _headerUsed, bytes.length);
        _header.setRange(_headerUsed, _headerUsed + count, bytes);
        _headerUsed += count;
        offset += count;
        if (_headerUsed < 4) return null;
        final size = ByteData.sublistView(_header).getUint32(0, Endian.big);
        if (size < 4 || size > maxPacketSize) {
          throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.malformed, 'Invalid response frame length');
        }
        _body = Uint8List(size - 4);
      }
      final body = _body!;
      final count = min(body.length - _bodyUsed, bytes.length - offset);
      body.setRange(_bodyUsed, _bodyUsed + count, bytes, offset);
      _bodyUsed += count;
      offset += count;
      if (_bodyUsed != body.length) return null;
      _used = true;
      return _complete(body, Uint8List.sublistView(bytes, offset));
    } catch (_) {
      close();
      rethrow;
    }
  }

  SpotifyApHandshakeResult _complete(Uint8List body, Uint8List trailing) {
    try {
      NativeApResponse parsed;
      try { parsed = NativeApResponse.decode(body); }
      catch (_) { throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.malformed, 'Invalid response protobuf'); }
      final response = parsed.message;
      if (!response.isInitialized()) {
        throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.malformed, 'Missing required response fields');
      }
      if (response.hasLoginFailed() || response.hasUpgrade()) {
        response.freeze();
        throw SpotifyApHandshakeException(SpotifyApHandshakeFailure.serverRejected,
          'AP returned an error or required upgrade', untrustedResponse: response,
          untrustedLoginFailure: parsed.loginFailure);
      }
      if (!response.hasChallenge() || !response.challenge.loginCryptoChallenge.hasDiffieHellman()) {
        throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.missingChallenge, 'No DH server challenge');
      }
      final challenge = response.challenge;
      if (challenge.cryptoChallenge.hasRc4Sha1Hmac()) {
        throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.unsupportedChallenge, 'Unsupported AP RC4 challenge');
      }
      final dh = challenge.loginCryptoChallenge.diffieHellman;
      // Native101902b6c checks the advertised mask with the low five index bits
      // before RSA verification; e.g. index32 aliases the advertised index0.
      if (((_serverKeysKnown >> (dh.serverSignatureKey & 31)) & 1) == 0) {
        throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.unsupportedChallenge,
          'Unadvertised AP server signature key');
      }
      if (dh.gs.isEmpty || dh.gs.length > 96 || dh.gsSignature.length != 256) {
        throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.signature, 'Invalid DH key or signature length');
      }
      final remote = _integer(dh.gs);
      if (remote <= BigInt.one || remote >= _dhPrime - BigInt.one) {
        throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.signature, 'Invalid DH public value');
      }
      final verifier = pc.RSASigner(pc.SHA1Digest(), '06052b0e03021a')
        ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(pc.RSAPublicKey(_serverModulus, BigInt.from(65537))));
      if (!verifier.verifySignature(_copy(dh.gs), pc.RSASignature(_copy(dh.gsSignature)))) {
        throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.signature, 'Pinned server signature verification failed');
      }
      // Only an authenticated server key reaches the private exponent and KDF.
      // Original101902b6c exports/HMACs exactly0x60 bytes, retaining leading zero.
      final shared = _fixed96(remote.modPow(_private!, _dhPrime));
      final serverFrame = [..._header, ...body];
      final keys = SpotifyApHandshakeKeys.derive(sharedSecret: shared,
        transcript: [...clientHelloFrame, ...serverFrame]);
      response.freeze();
      return SpotifyApHandshakeResult._(keys, trailing, response, clientHelloFrame, serverFrame);
    } finally { close(); }
  }

  void finishInput() {
    _requireOpen();
    close();
    throw const SpotifyApHandshakeException(SpotifyApHandshakeFailure.truncated, 'Response ended before the handshake completed');
  }
  void close() {
    _used = true;
    _private = null;
    _body = null;
  }
  void _requireOpen() {
    if (_used) throw StateError('Spotify AP handshake is already retired');
  }
}

Uint8List _frame(List<int> body, {bool hello = false}) {
  final prefix = hello ? 6 : 4;
  final size = prefix + body.length;
  if (size > SpotifyApHandshake.maxPacketSize) throw ArgumentError('AP handshake frame exceeds 64 KiB');
  final frame = Uint8List(size);
  if (hello) { frame[1] = 4; }
  ByteData.sublistView(frame).setUint32(hello ? 2 : 0, size, Endian.big);
  frame.setRange(prefix, size, body);
  return frame.asUnmodifiableView();
}
Uint8List _copy(List<int> value) {
  for (final byte in value) { RangeError.checkValueInInterval(byte, 0, 255, 'byte'); }
  return Uint8List.fromList(value).asUnmodifiableView();
}
BigInt _integer(List<int> bytes) => BigInt.parse(hex.encode(bytes), radix: 16);
Uint8List _bigEndian(BigInt value) {
  final text = value.toRadixString(16);
  return Uint8List.fromList(hex.decode(text.length.isOdd ? '0$text' : text));
}
Uint8List _fixed96(BigInt value) {
  final bytes = _bigEndian(value);
  return Uint8List(96)..setRange(96 - bytes.length, 96, bytes);
}

final _dhPrime = BigInt.parse(
  'ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd'
  'ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a63a3620ffffffffffffffff', radix: 16);
final _serverModulus = BigInt.parse(
  'ace0460bffc230aff46bfec3bfbf863da191c6cc336c93a14fb3b01612acac6af180e7f614d9429dbe2e346643e362d2'
  '327a1a0d923baedd1402b18155056104d52c96a44c1ecc024ad4b20c001f17edc22fc43521c8f0cbaed2add72b0f9db3'
  'c5321a2afe59f35a0dac68f1fa621efb2c8d0cb7392d9247e3d7351a6dbd24c2ae255b88ffab73298a0bcccd0c586731'
  '89e8bd3480784a5fc96b899d956bfc86d74f33a6781796c9c32d0d32a5abcd0527e2f710a39613c42f99c027bfed049c'
  '3c275804b6b219f9c12f02e94863eca1b642a09d4825f8b39dd0e86af9484da1c2ba863042ea9db3086c190e48b39d66'
  'eb0006a25aeea11b13873cd719e655bd', radix: 16);
