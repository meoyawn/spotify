import 'dart:typed_data';

import 'package:protobuf/well_known_types/google/protobuf/struct.pbenum.dart' show NullValue;

import 'generated/es_auth_blob.pb.dart';
import 'generated/es_encrypted_stored_credentials.pb.dart';
import 'generated/es_stored_user_info.pb.dart';
import 'generated/es_unencrypted_stored_credentials.pb.dart';
import 'native_legacy_auth_codec.dart';

/// The two arguments passed to AuthStorageClient's credential-update owner.
/// Its native operation receives no username argument.
final class NativeLegacyCredentialUpdate {
  NativeLegacyCredentialUpdate({required List<int> encodedBlob, required this.deviceId})
    : encodedBlob = Uint8List.fromList(encodedBlob).asUnmodifiableView();
  final Uint8List encodedBlob;
  final String deviceId;
}

/// Pure policy from actual AuthStorageClient overrides 0x101936c80/f9c and
/// 0x101937294, with constructor/ClassData identities verified independently.
/// In this Esperanto context EncryptedStoredCredentials.auth_blob contains
/// the legacy Base64 envelope; it is not the separate pending-event frame.
class NativeAuthBlobMapper {
  NativeAuthBlobMapper({required this.deviceId});
  final String deviceId;
  final NativeLegacyAuthCodec _legacy = NativeLegacyAuthCodec();

  /// Unencrypted presence wins, even when empty or alongside field1. The outer
  /// StoredUserInfo username replaces either nested message's username.
  NativeLegacyStoredCredentials? selectStoredUserInfo(StoredUserInfo info) {
    final blob = info.authBlob;
    if (blob.hasUnencryptedStoredCredentials()) {
      return _legacy.encode(username: info.username,
        data: blob.unencryptedStoredCredentials.storedCredentials, deviceId: deviceId);
    }
    if (blob.whichBlob() == AuthBlob_Blob.storedCredentials) {
      return NativeLegacyStoredCredentials(username: info.username,
        encodedBlob: blob.storedCredentials.authBlob, deviceId: blob.storedCredentials.deviceId);
    }
    return null;
  }

  /// The direct AuthBlob update uses the unencrypted message's username only
  /// while deriving its envelope; the encrypted alternative forwards bytes.
  NativeLegacyCredentialUpdate? selectUpdate(AuthBlob blob) {
    if (blob.hasUnencryptedStoredCredentials()) {
      final encoded = _legacy.encode(username: blob.unencryptedStoredCredentials.username,
        data: blob.unencryptedStoredCredentials.storedCredentials, deviceId: deviceId);
      // The native update forwards the owner's device even if encoding yielded
      // the default empty stored model. It never falls back to field1.
      return NativeLegacyCredentialUpdate(encodedBlob: encoded.encodedBlob, deviceId: deviceId);
    }
    if (blob.whichBlob() == AuthBlob_Blob.storedCredentials) {
      return NativeLegacyCredentialUpdate(encodedBlob: blob.storedCredentials.authBlob,
        deviceId: blob.storedCredentials.deviceId);
    }
    return null;
  }

  /// The original projection always emits both AuthBlob messages for a present
  /// stored model. Rejected legacy decoding yields empty unencrypted data.
  NullableStoredUserInfo project(NativeLegacyStoredCredentials? stored) {
    if (stored == null) return NullableStoredUserInfo(null_2: NullValue.NULL_VALUE);
    final decoded = _legacy.decode(stored);
    return NullableStoredUserInfo(storedUserInfo: StoredUserInfo(username: stored.username,
      authBlob: AuthBlob(storedCredentials: EncryptedStoredCredentials(username: stored.username,
          authBlob: Uint8List.fromList(stored.encodedBlob), deviceId: stored.deviceId),
        unencryptedStoredCredentials: UnencryptedStoredCredentials(username: stored.username,
          storedCredentials: decoded?.data ?? const []))));
  }
}
