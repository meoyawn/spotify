import 'dart:async';

import 'package:fixnum/fixnum.dart';

import 'generated/es_prefs.pb.dart' as proto;

class _Entry {
  _Entry(this.flags, this.defaultValue);
  int flags;
  proto.Value defaultValue;
  proto.Value? overrideValue;
  proto.Value get effective => (flags & 0x160) == 0x100 ? overrideValue! : defaultValue;
}

/// One native mutation, including the full snapshot captured at that moment.
class PrefsChange {
  PrefsChange(this.key, this.values, {required this.flags});
  final String key;
  final proto.PrefValues values;
  final int flags;
}

/// Immutable registration/override snapshot used by the native file owner.
class PrefsRecord {
  const PrefsRecord({required this.key, required this.flags,
    required this.defaultValue, required this.overrideValue});
  final String key;
  final int flags;
  final proto.Value defaultValue;
  final proto.Value? overrideValue;
}

/// Native typed registry: registered defaults and loaded/written overrides
/// have distinct ownership. No original profile path or implicit disk store.
class PrefsStore {
  final _entries = <String, _Entry>{};
  final _changes = StreamController<PrefsChange>.broadcast(sync: true);
  final _pendingChanges = <PrefsChange>[];
  bool _notifying = false;
  bool _closed = false;

  Stream<PrefsChange> get changes => _changes.stream;

  List<PrefsRecord> records() => List.unmodifiable([
    for (final entry in _entries.entries) PrefsRecord(key: entry.key, flags: entry.value.flags,
      defaultValue: entry.value.defaultValue, overrideValue: entry.value.overrideValue),
  ]);

  /// Registration at 0x101f3fbd8. Flag 0x100 denotes a loaded override;
  /// ordinary registrations define defaults and lock the declared type.
  bool register(String key, proto.Value value, {int flags = 0}) {
    _checkOpen();
    key = _nativeKey(key);
    final incoming = _normalized(value);
    final type = _nativeType(incoming);
    var entry = _entries[key];
    if (entry != null) {
      if ((flags & 0x100) == 0 && (entry.flags & 0x60) != 0) return false;
      if ((entry.flags & 3) != type) {
        if ((entry.flags & 0x200) != 0) return false;
        entry = null;
      } else {
        entry.flags |= flags & 0x14ec;
      }
    }
    if (entry == null) {
      entry = _Entry((flags & 0xfffffcfc) | type, _zero(incoming.whichValue()));
      _entries[key] = entry;
    }
    entry.flags |= 0x200 - (flags & 0x100);
    if ((flags & 0x100) != 0) {
      entry.overrideValue = incoming;
    } else {
      entry.defaultValue = incoming;
    }
    return true;
  }

  /// Imports only explicitly supplied app-owned values. Call before registering
  /// defaults when reproducing native startup: defaults establish final types.
  void restoreOverrides(Map<String, proto.Value> values) {
    for (final item in values.entries) {
      if (item.value.whichValue() != proto.Value_Value.notSet) {
        register(item.key, item.value, flags: 0x100);
      }
    }
  }

  /// Raw override snapshot for the owning persistence adapter. Scope selection
  /// and a filesystem codec are separate from the registry contract.
  Map<String, proto.Value> overrides({int? scopeMask}) => Map.unmodifiable({
    for (final item in _entries.entries)
      if ((item.value.flags & 0x100) != 0 &&
          (scopeMask == null || (item.value.flags & scopeMask) != 0)) item.key: item.value.overrideValue!,
  });

  proto.PrefValues get(String key) => values([key]);
  proto.PrefValues getAll() => values(_entries.keys);
  proto.PrefValues values(Iterable<String> keys) => proto.PrefValues(entries: <String, proto.Value>{
    for (final key in keys.map(_nativeKey))
      if (_entries[key] case final entry?) key: entry.effective,
  }.entries);

  /// 0x100847f08 selects according to the registered type; protobuf oneof
  /// defaults perform the native false/zero/empty coercion for mismatches.
  proto.PrefValues set(Map<String, proto.Value> values) {
    _checkOpen();
    for (final item in values.entries) {
      final key = _nativeKey(item.key);
      final entry = _entries[key];
      if (entry == null || (entry.flags & 3) == 0) continue;
      final value = switch (entry.flags & 3) {
        1 => proto.Value(bool_2: item.value.bool_2),
        2 => proto.Value(number: Int64(item.value.number.toInt().toSigned(32))),
        _ => proto.Value(string: item.value.string),
      }..freeze();
      final hasOverride = (entry.flags & 0x100) != 0;
      if ((entry.flags & 0x280) == 0x200 && value == entry.defaultValue) {
        if (!hasOverride) continue;
        entry.flags &= ~0x180;
        entry.overrideValue = null;
      } else {
        if (hasOverride && value == entry.overrideValue) continue;
        entry.overrideValue = value;
        entry.flags |= 0x100;
        if ((entry.flags & 0x60) != 0) continue;
      }
      _emit(key);
    }
    return this.values(values.keys);
  }

  proto.PrefValues create(Map<String, proto.Value> values) {
    for (final item in values.entries) {
      if (item.value.whichValue() != proto.Value_Value.notSet) register(item.key, item.value);
    }
    return this.values(values.keys);
  }

  /// Native 0x101f41718/0x101f42598 removes override ownership, preserving
  /// flag0x80 and registered entries. Empty/dot-ended keys select a prefix.
  void reset(String key) {
    _checkOpen();
    key = _nativeKey(key);
    final prefix = key.isEmpty || key.endsWith('.');
    for (final item in _entries.entries) {
      if (!(prefix ? item.key.startsWith(key) : item.key == key)) continue;
      final entry = item.value;
      final flags = entry.flags;
      if ((flags & 0x100) == 0) continue;
      entry.flags &= ~0x100;
      entry.overrideValue = null;
      if ((flags & 0x60) == 0) _emit(item.key);
    }
  }

  /// Durable desktop legacy-auth catalog installed by original0x1018edcd0.
  void registerLegacyAuthDefaults() {
    register('autologin.username', proto.Value(string: ''), flags: 0x1004);
    register('autologin.saved_credentials', proto.Value(string: '{}'), flags: 0x1004);
    register('autologin.canonical_username', proto.Value(string: ''), flags: 0x1004);
    register('autologin.blob', proto.Value(string: ''), flags: 0x1004);
    register('autologin.enabled', proto.Value(bool_2: true), flags: 0x1004);
  }

  /// Base desktop defaults installed by original 0x1014b7ad8. Other modules
  /// may register more definitions; this is not the complete client inventory.
  void registerDesktopDefaults() {
    void boolean(String key, bool value, int flags) => register(key, proto.Value(bool_2: value), flags: flags);
    void number(String key, int value, int flags) => register(key, proto.Value(number: Int64(value)), flags: flags);
    void string(String key, String value, int flags) => register(key, proto.Value(string: value), flags: flags);
    boolean('app.autostart-configured', false, 4);
    string('app.autostart-mode', 'minimized', 4);
    string('app.last-launched-version', '', 4);
    boolean('app.force-offline-mode', false, 4);
    boolean('app.enable-developer-mode', false, 4);
    boolean('app.window.position.saved', false, 4);
    number('app.window.position.x', 0, 4);
    number('app.window.position.y', 0, 4);
    number('app.window.position.width', 1600, 4);
    number('app.window.position.height', 900, 4);
    boolean('app.window.state.saved', false, 4);
    number('app.window.state', 1, 4);
    boolean('app.show-chrome-toolbar', false, 4);
    boolean('app.enable-desktop-watchdog', false, 4);
    boolean('app.decorator-zero-hop', false, 4);
    boolean('app.enable-launcher', true, 4);
    boolean('app.studio.prevent-system-sleep', false, 4);
    boolean('app.player.autoplay', true, 8);
    number('app.player.volume', 65535, 8);
    string('app.player.state', '', 8);
    number('app.browser.zoom-level', 0, 8);
    string('storage.last-location', '', 4);
    boolean('ui.shuffle', false, 8);
    number('ui.repeat', 0, 8);
    boolean('ui.hide_hpto', false, 8);
    boolean('ui.hide_promoted_songs', false, 8);
    boolean('ui.hardware_acceleration', true, 4);
    boolean('ui.show_unplayable_tracks', false, 8);
    boolean('ui.track_os_notifications_enabled', false, 8);
    boolean('ui.system_media_controls_enabled', true, 8);
    boolean('ui.minimize_to_tray', false, 8);
    boolean('ui.miniplayer_auto_open_enabled', false, 8);
    string('network.proxy.addr', '', 4);
    number('network.proxy.mode', 0, 4);
    string('network.proxy.user', '', 4);
    string('network.proxy.pass', '', 4);
    string('campaign-id', '', 4);
    boolean('es.send-on-startup', false, 4);
    boolean('es.use-lmdb', false, 4);
    boolean('es.repair-greenbase', false, 4);
    string('language', '', 0x84);
    boolean('app.rollback-to-sc', false, 4);
    string('app.client-id-hash', '', 4);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }

  void _checkOpen() {
    if (_closed) throw StateError('Preference store is closed');
  }

  void _emit(String key) {
    _pendingChanges.add(PrefsChange(key, getAll()..freeze(), flags: _entries[key]!.flags));
    if (_notifying) return;
    _notifying = true;
    try {
      while (_pendingChanges.isNotEmpty) {
        _changes.add(_pendingChanges.removeAt(0));
      }
    } finally {
      _notifying = false;
    }
  }
}

String _nativeKey(String key) {
  final end = key.indexOf('\u0000');
  return end < 0 ? key : key.substring(0, end);
}

int _nativeType(proto.Value value) => switch (value.whichValue()) {
  proto.Value_Value.bool_2 => 1, proto.Value_Value.number => 2,
  proto.Value_Value.string => 3, proto.Value_Value.notSet => 0,
};

proto.Value _normalized(proto.Value value) => switch (value.whichValue()) {
  proto.Value_Value.number => proto.Value(number: Int64(value.number.toInt().toSigned(32))),
  _ => value.deepCopy(),
}..freeze();

proto.Value _zero(proto.Value_Value type) => switch (type) {
  proto.Value_Value.number => proto.Value(number: Int64.ZERO),
  proto.Value_Value.bool_2 => proto.Value(bool_2: false),
  proto.Value_Value.string => proto.Value(string: ''),
  proto.Value_Value.notSet => proto.Value(),
}..freeze();
