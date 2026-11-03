import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mt19937/mt19937.dart';

import 'dpop.dart';

/// Native proof generation uses a crypto provider with a 64-byte public key
/// and an IEEE P1363 signature over an already computed SHA-256 digest.
abstract interface class DpopSigningKey {
  Uint8List get publicKeyBytes;
  Uint8List signDigest(Uint8List digest);
}

/// Proprietary orchestration from 0x1017a49f0, 0x1017a4704 and 0x1017a3fd4.
/// Entropy and wall-clock sources are explicit boundaries, like the native
/// provider callbacks. This class never loads credentials or sends requests.
class DpopProofGenerator {
  DpopProofGenerator({required this.key, int Function()? clockSeconds,
      int Function()? entropySeed})
    : _clockSeconds = clockSeconds ?? _wallClockSeconds,
      _entropySeed = entropySeed ?? _entropySeed32;

  final DpopSigningKey key;
  final int Function() _clockSeconds;
  final int Function() _entropySeed;

  String createProof({required String method, required String url, String? nonce}) {
    final public = _jwk();
    final random = MersenneTwister(seed: _entropySeed() & 0xffffffff);
    // The native uint64 distribution consumes the first MT word as the high
    // word; SHA-1 sees the uint64 in little-endian arm64 memory order.
    final high = random();
    final low = random();
    final word = ByteData(8)
      ..setUint32(0, low, Endian.little)
      ..setUint32(4, high, Endian.little);
    final jwtId = sha1.convert(word.buffer.asUint8List()).toString();
    final input = dpopSigningInput(
      DpopHeader(algorithm: 'ES256', type: 'dpop+jwt', jwk: public),
      DpopClaims(uri: url, method: method, jwtId: jwtId,
        issuedAt: _clockSeconds() & 0xffffffff, nonce: nonce));
    final digest = Uint8List.fromList(sha256.convert(utf8.encode(input)).bytes);
    final signature = key.signDigest(digest);
    if (signature.length != 64) {
      throw StateError('The DPoP signing provider returned an invalid signature length');
    }
    return '$input.${_base64(signature)}';
  }

  /// Canonical JWK thumbprint construction from 0x1017a5468.
  String get keyThumbprint {
    final public = _jwk();
    final encoded = jsonEncode({'crv': 'P-256', 'kty': 'EC',
      'x': public.x, 'y': public.y});
    return _base64(sha256.convert(utf8.encode(encoded)).bytes);
  }

  DpopJwk _jwk() {
    final bytes = key.publicKeyBytes;
    if (bytes.length != 64) {
      throw StateError('The DPoP signing provider returned an invalid public key length');
    }
    return DpopJwk(curve: 'P-256', keyType: 'EC',
      x: _base64(bytes.sublist(0, 32)), y: _base64(bytes.sublist(32)));
  }
}

int _wallClockSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
int _entropySeed32() => Random.secure().nextInt(0x100000000);
String _base64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
