import 'dart:convert';

import 'generated/es_prefs.pb.dart' as proto;
import 'native_legacy_auth_codec.dart';
import 'native_legacy_auth_json.dart';
import 'prefs_store.dart';

/// Outputs of original0x1018ee420. Failed reads retain the partial stored
/// model but have no canonical username. Enabled is an independent output.
final class NativeLegacyAuthPreferenceRead {
  const NativeLegacyAuthPreferenceRead({required this.available, required this.enabled,
    required this.stored, this.canonicalUsername});
  final bool available;
  final bool enabled;
  final NativeLegacyStoredCredentials stored;
  final String? canonicalUsername;
}

/// Local legacy-auth preference owner, original vtable0x102647220.
/// The caller owns the store, its explicit app-owned persistence and deviceId.
/// This class neither opens a profile nor creates a session or remote sender.
class NativeLegacyAuthPreferences {
  NativeLegacyAuthPreferences({required this.store, required this.deviceId}) {
    store.registerLegacyAuthDefaults();
  }

  final PrefsStore store;
  final String deviceId;
  final _codec = NativeLegacyAuthCodec();

  String _string(String key) => store.get(key).entries[key]?.string ?? '';
  void _write(String key, String value) => store.set({key: proto.Value(string: value)});

  bool get enabled => store.get('autologin.enabled').entries['autologin.enabled']?.bool_2 ?? false;

  NativeLegacyAuthPreferenceRead readLegacy() {
    final flag = enabled;
    final username = _string('autologin.username');
    if (username.isEmpty) {
      return NativeLegacyAuthPreferenceRead(available: false, enabled: flag,
        stored: NativeLegacyStoredCredentials.empty());
    }
    final blob = _string('autologin.blob');
    final stored = NativeLegacyStoredCredentials(username: username,
      encodedBlob: utf8.encode(blob), deviceId: deviceId);
    final decoded = blob.isEmpty ? null : _codec.decode(stored);
    if (decoded == null || decoded.authenticationType == -1) {
      return NativeLegacyAuthPreferenceRead(available: false, enabled: flag, stored: stored);
    }
    return NativeLegacyAuthPreferenceRead(available: true, enabled: flag, stored: stored,
      canonicalUsername: _string('autologin.canonical_username'));
  }

  NativeLegacyStoredCredentials? readSaved(String canonicalUsername) {
    final entry = NativeLegacyAuthJson.lookup(_string('autologin.saved_credentials'), canonicalUsername);
    if (entry == null) return null;
    final stored = NativeLegacyStoredCredentials(username: entry.username,
      encodedBlob: utf8.encode(entry.blob), deviceId: deviceId);
    final decoded = _codec.decode(stored);
    return decoded == null || decoded.authenticationType == -1 ? null : stored;
  }

  List<String> savedCanonicalUsernames() => NativeLegacyAuthJson.canonicalUsernames(
    _string('autologin.saved_credentials'));

  void clearBlob() => _write('autologin.blob', '');

  /// Original0x1018ee844. The supplied stored model's deviceId is not persisted;
  /// later reads use this owner's deviceId. No-save removes its username key,
  /// clears the legacy blob and still writes the supplied canonical username.
  void updateLegacy(NativeLegacyStoredCredentials stored, {required String canonicalUsername,
      required bool saveCredentials}) {
    var blob = '';
    if (saveCredentials) {
      blob = utf8.decode(stored.encodedBlob);
      if (canonicalUsername.isNotEmpty) {
        final saved = NativeLegacyAuthJson.update(_string('autologin.saved_credentials'),
          canonicalUsername: canonicalUsername, username: stored.username, blob: blob);
        if (saved != null) _write('autologin.saved_credentials', saved);
      }
    } else if (stored.username.isNotEmpty) {
      final saved = NativeLegacyAuthJson.remove(_string('autologin.saved_credentials'), stored.username);
      if (saved != null) _write('autologin.saved_credentials', saved);
    }
    _write('autologin.username', stored.username);
    _write('autologin.blob', blob);
    if (!saveCredentials || canonicalUsername.isNotEmpty) {
      _write('autologin.canonical_username', canonicalUsername);
    }
  }

  void setEnabled(String username, bool value) {
    store.set({'autologin.enabled': proto.Value(bool_2: value)});
    if (!value) forget(username);
  }

  /// Original0x1018eea44 passes the owner deviceId as the no-save canonical
  /// argument, then resets the username override. The saved map removal still
  /// matches username, not deviceId or the previous canonical preference.
  void forget(String username) {
    updateLegacy(NativeLegacyStoredCredentials(username: username, encodedBlob: const [], deviceId: deviceId),
      canonicalUsername: deviceId, saveCredentials: false);
    store.reset('autologin.username');
  }
}
