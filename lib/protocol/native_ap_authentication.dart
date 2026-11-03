import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:protobuf/protobuf.dart' show ProtobufEnum;

import '../playback/generated/authentication.pb.dart' as auth;
import '../playback/generated/keyexchange.pb.dart' as key;
import '../playback/spotify_ap_session.dart' show SpotifyApAuthenticationFrames;
import 'desktop_identity.dart';
import 'native_ap_hashcash.dart';
import 'native_ap_system_info.dart';
import 'native_legacy_auth_codec.dart' show NativeLegacyCredential;
import 'platform_identity.dart';

/// Explicit text/device projection consumed by native builder 0x101902fa8.
/// Unknown names retain their schema aliases; no desktop identity is invented.
final class NativeApAuthenticationProfile {
  NativeApAuthenticationProfile({required auth.SystemInfo systemInfo,
    required this.nativeField11, required this.platformModel,
    required this.versionString, required this.language, required this.nativeField5})
    : systemInfo = systemInfo.deepCopy()..freeze();

  /// Installed desktop mapping through 0x100061f64 -> 0x1018ef2cc ->
  /// 0x1018fc904. Hardware model, OS facts and caller-owned device identity
  /// remain distinct. Language is the owning configuration's actual value;
  /// the manager's initial "en" is not an unconditional desktop default.
  /// Opaque fields have no inferred token/identifier or empty-value default.
  factory NativeApAuthenticationProfile.referenceDesktop({required String deviceId,
    required String language, required String nativeField11, required String nativeField5,
    NativeApSystemInfo? systemInfo, MacOSPlatformIdentity? platformIdentity}) =>
    NativeApAuthenticationProfile(
      systemInfo: (systemInfo ?? NativeApSystemInfo.readCurrent()).toMessage(deviceId: deviceId),
      nativeField11: nativeField11,
      platformModel: (platformIdentity ?? MacOSPlatformIdentity.readCurrent()).hardwareModel,
      versionString: DesktopIdentity.fullVersion, language: language, nativeField5: nativeField5);

  /// A newly constructed native manager, before any external profile mutation.
  /// Original 0x1018f73dc supplies both empty opaque strings; the original
  /// credential entry and connection projection preserve them. Restored or
  /// explicitly modified profiles must use [referenceDesktop] with their values.
  factory NativeApAuthenticationProfile.freshDesktop({required String deviceId,
    required String language, NativeApSystemInfo? systemInfo,
    MacOSPlatformIdentity? platformIdentity}) =>
    NativeApAuthenticationProfile.referenceDesktop(deviceId: deviceId, language: language,
      systemInfo: systemInfo, platformIdentity: platformIdentity,
      nativeField11: '', nativeField5: '');

  final auth.SystemInfo systemInfo;
  final String nativeField11, platformModel, versionString, language, nativeField5;
}

/// Original encrypted authentication and plaintext challenge construction.
/// The caller invokes this only after signature verification and supplies the
/// exact raw handshake frames. An AP credential is explicit: this owner does
/// not infer a mapping from Login5 access tokens or stored credentials.
final class NativeApAuthentication {
  NativeApAuthentication({required this.profile, required this.credential,
    required List<int> nonceKey, Random? random})
    : _nonceKey = Uint8List.fromList(nonceKey).asUnmodifiableView(),
      _random = random ?? Random.secure() {
    if (nonceKey.length != 16) throw ArgumentError('Native AP nonce AES key must contain 16 bytes');
    RangeError.checkValueInInterval(credential.authenticationType, 0, 0x7fffffff, 'authenticationType');
  }
  final NativeApAuthenticationProfile profile;
  final NativeLegacyCredential credential;
  final Uint8List _nonceKey;
  final Random _random;

  Future<SpotifyApAuthenticationFrames> build({required key.APChallenge challenge,
    required List<int> clientHelloFrame, required List<int> serverResponseFrame,
    required List<int> dhHmac}) async {
    if (dhHmac.length != 20) throw ArgumentError('Native AP DH response must contain 20 bytes');
    final server = challenge.deepCopy()..freeze();
    final helloBytes = Uint8List.fromList(clientHelloFrame);
    final responseBytes = Uint8List.fromList(serverResponseFrame);
    final plaintext = key.ClientResponsePlaintext(
      loginCryptoResponse: key.LoginCryptoResponseUnion(
        diffieHellman: key.LoginCryptoDiffieHellmanResponse(hmac: Uint8List.fromList(dhHmac))),
      powResponse: key.PoWResponseUnion(),
      cryptoResponse: key.CryptoResponseUnion(shannon: key.CryptoShannonResponse()));
    if (server.hasPowChallenge() && server.powChallenge.hasHashCash()) {
      final hashcash = server.powChallenge.hashCash;
      if (hashcash.prefix.length != 16) throw ArgumentError('Native AP HashCash prefix must contain 16 bytes');
      plaintext.powResponse.hashCash = key.PoWHashCashResponse(hashSuffix:
        await solveNativeApHashcash(clientHello: helloBytes, serverResponse: responseBytes,
          prefix: hashcash.prefix, difficulty: hashcash.length.toUnsigned(8),
          target: hashcash.target.toUnsigned(32)));
    }

    final kind = credential.authenticationType;
    final username = kind == 3 && credential.username.isEmpty
      ? hex.encode(_bytes(8)) : credential.username;
    final login = auth.LoginCredentials(username: username, authData: credential.data);
    // Public protobuf writes the native number without inventing an enum name.
    // Its typed reference getter must not be used for a foreign numeric value.
    login.setField(20, ProtobufEnum(kind, ''));
    if (kind == 0 || kind == 8) {
      login.nativeField40 = _bytes(32 - (credential.data.length & 31));
    }
    final encrypted = auth.ClientResponseEncrypted(loginCredentials: login,
      nativeField11: profile.nativeField11,
      accountCreation: auth.AccountCreation.ACCOUNT_CREATION_ALWAYS_PROMPT,
      systemInfo: profile.systemInfo, platformModel: profile.platformModel,
      versionString: profile.versionString,
      clientInfo: auth.ClientInfo(limited: false, language: profile.language,
        nativeField5: profile.nativeField5));
    if (server.hasFingerprintChallenge() && server.fingerprintChallenge.hasGrain()) {
      final kek = server.fingerprintChallenge.grain.kek;
      if (kek.length != 16) throw ArgumentError('Native AP Grain key must contain 16 bytes');
      final digest = crypto.sha1.convert([...helloBytes, ...responseBytes]).bytes;
      final intermediate = _aes(kek, digest.sublist(0, 16));
      encrypted.fingerprintResponse = auth.FingerprintResponseUnion(
        grain: auth.FingerprintGrainResponse(encryptedKey: _aes(intermediate, _nonceKey)));
    }
    // The original advertises Grain and does not construct HmacRipemd here.
    // The surrounding session owns unsupported-challenge admission.
    return SpotifyApAuthenticationFrames(plaintext: plaintext, encrypted: encrypted);
  }

  Uint8List _bytes(int count) => Uint8List.fromList(
    List.generate(count, (_) => _random.nextInt(256)));
}

Uint8List _aes(List<int> key, List<int> block) {
  final cipher = AESEngine()..init(true, KeyParameter(Uint8List.fromList(key)));
  final output = Uint8List(16);
  cipher.processBlock(Uint8List.fromList(block), 0, output, 0);
  return output;
}
