import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/asn1/asn1_utils.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

import 'dpop_proof.dart';

/// Standard P-256 operations reused through PointyCastle. Native key storage,
/// PEM validation error mapping and session lifetime are separate concerns.
class P256DpopKey implements DpopSigningKey {
  P256DpopKey._(this._privateKey, this._random) {
    final point = (_privateKey.parameters!.G * _privateKey.d)!;
    _publicBytes = Uint8List.fromList([
      ..._unsigned32(point.x!.toBigInteger()!),
      ..._unsigned32(point.y!.toBigInteger()!),
    ]);
  }

  factory P256DpopKey.generate() {
    final random = _secureRandom();
    final generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(ECCurve_secp256r1()), random));
    return P256DpopKey._(generator.generateKeyPair().privateKey, random);
  }

  /// App-owned Keychain persistence retains this exact standard P-256 key.
  /// No token/key material is read from the original Spotify application.
  factory P256DpopKey.fromPrivateBytes(List<int> bytes) {
    if (bytes.length != 32) throw const FormatException('Expected a32-byte P-256 private scalar');
    final domain = ECCurve_secp256r1();
    final scalar = ASN1Utils.osp2i(bytes);
    if (scalar <= BigInt.zero || scalar >= domain.n) throw const FormatException('Invalid P-256 private scalar');
    return P256DpopKey._(ECPrivateKey(scalar, domain), _secureRandom());
  }

  Uint8List exportPrivateBytes() => Uint8List.fromList(_unsigned32(_privateKey.d!));

  /// Imports standard unencrypted PKCS#8 or SEC1 key material. This does not
  /// read the original application's credential store or accept another curve.
  factory P256DpopKey.fromPem(String pem) {
    try {
      final pkcs8 = pem.startsWith('-----BEGIN PRIVATE KEY-----');
      if (!pkcs8 && !pem.startsWith('-----BEGIN EC PRIVATE KEY-----')) {
        throw const FormatException('Expected an unencrypted EC private key');
      }
      final der = ASN1Utils.getBytesFromPEMString(pem);
      final key = ASN1Utils.ecPrivateKeyFromDerBytes(der, pkcs8: pkcs8);
      final domain = ECCurve_secp256r1();
      if (key.parameters!.n != domain.n ||
          key.parameters!.G != domain.G || key.d == null ||
          key.d! <= BigInt.zero || key.d! >= domain.n) {
        throw const FormatException('Expected a P-256 private key');
      }
      return P256DpopKey._(key, _secureRandom());
    } catch (_) {
      throw const FormatException('Invalid P-256 private key');
    }
  }

  final ECPrivateKey _privateKey;
  final SecureRandom _random;
  late final Uint8List _publicBytes;

  @override
  Uint8List get publicKeyBytes => Uint8List.fromList(_publicBytes);

  @override
  Uint8List signDigest(Uint8List digest) {
    if (digest.length != 32) {
      throw ArgumentError.value(digest.length, 'digest.length', 'Expected SHA-256');
    }
    // The native adapter signs the existing digest and 0x10167d4d0 maps high S
    // to n-S before returning raw R || S. Reuse that standard normalization.
    final signer = NormalizedECDSASigner(ECDSASigner())
      ..init(true, ParametersWithRandom(
        PrivateKeyParameter<ECPrivateKey>(_privateKey), _random));
    final signature = signer.generateSignature(digest) as ECSignature;
    return Uint8List.fromList([..._unsigned32(signature.r), ..._unsigned32(signature.s)]);
  }
}

SecureRandom _secureRandom() {
  final source = Random.secure();
  final seed = Uint8List.fromList(List.generate(32, (_) => source.nextInt(256)));
  return FortunaRandom()..seed(KeyParameter(seed));
}

Uint8List _unsigned32(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  if (hex.length != 64 || value.isNegative) {
    throw StateError('P-256 value exceeds 32 bytes');
  }
  return Uint8List.fromList(List.generate(32,
    (index) => int.parse(hex.substring(index * 2, index * 2 + 2), radix: 16)));
}
