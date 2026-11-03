import 'dart:math';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:protobuf/protobuf.dart' show ProtobufEnum;

import '../playback/generated/keyexchange.pb.dart' as wire;
import 'desktop_identity.dart';

/// Caller-supplied native fields at owner+0xfc/+0xf8/+0x18/+0x68.
/// Numeric enum values are deliberately independent of the reference labels.
final class NativeApHelloProfile {
  NativeApHelloProfile({required this.product, required this.platform,
    required this.version, required this.featureFlags}) {
    RangeError.checkValueInInterval(product, 0, 0xffffffff, 'product');
    RangeError.checkValueInInterval(platform, 0, 0xff, 'platform');
    RangeError.checkValueInInterval(version, 0, 0xffffffff, 'version');
    RangeError.checkValueInInterval(featureFlags, 0, 0xff, 'featureFlags');
  }

  /// Installed 1.3.6.1921 root/connection profile, captured without a peer.
  /// Native helpers 0x101a4c850/858 select raw platform 43/product 0 when the
  /// desktop root leaves their optional overrides absent. No account policy
  /// or authorization is implied by choosing this identity.
  factory NativeApHelloProfile.referenceDesktop() => NativeApHelloProfile(
    product: 0, platform: 43, version: DesktopIdentity.numericVersion,
    featureFlags: 0);

  final int product, platform, version, featureFlags;
}

/// Native hello template plus its private fingerprint input. The AP handshake
/// fills required DH fields using its own secure ephemeral key. Call [close]
/// once authentication has consumed the nonce key. Copies requested by callers
/// have their own lifetime; nothing is logged or persisted by this owner.
final class NativeApHello {
  NativeApHello._(this.hello, this._nonceKey);
  final wire.ClientHello hello;
  final Uint8List _nonceKey;
  bool _closed = false;

  Uint8List get nonceKey {
    if (_closed) throw StateError('Native AP nonce key is closed');
    return Uint8List.fromList(_nonceKey).asUnmodifiableView();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _nonceKey.fillRange(0, _nonceKey.length, 0);
  }
}

/// Native0x101904024 profile/nonce/feature construction. Standard entropy and
/// AES implement only their ordinary primitives; DH remains handshake-owned.
/// No desktop identity, HTTP sender, account or authorization is inferred.
NativeApHello createNativeApHello(NativeApHelloProfile profile) {
  final random = Random.secure();
  final nonceKey = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
  final nonce = Uint8List(16);
  final aes = AESEngine()..init(true, KeyParameter(nonceKey));
  aes.processBlock(Uint8List(16), 0, nonce, 0);
  final build = wire.BuildInfo(productFlags: [wire.ProductFlags.PRODUCT_FLAG_NONE],
    version: Int64(profile.version));
  // ProtobufEnum preserves native numbers that have no reference enum label.
  // Do not call typed product/platform getters on this foreign-value template.
  build.setField(10, ProtobufEnum(profile.product, 'native_product'));
  build.setField(30, ProtobufEnum(profile.platform, 'native_platform'));
  final hello = wire.ClientHello(buildInfo: build, clientNonce: nonce,
    fingerprintsSupported: [wire.Fingerprint.FINGERPRINT_GRAIN],
    cryptosuitesSupported: [wire.Cryptosuite.CRYPTO_SUITE_SHANNON],
    powschemesSupported: [wire.Powscheme.POW_HASH_CASH],
    padding: List.generate(random.nextInt(255) + 1, (_) => random.nextInt(256)),
    featureSet: wire.FeatureSet(autoupdate2: true,
      nativeField3: wire.NativeFeatureSetField3(
        nativeField4: (profile.featureFlags & 4) != 0 ? true : null),
      nativeField5: wire.NativeFeatureSetField5(nativeField1: false)))..freeze();
  return NativeApHello._(hello, nonceKey);
}
