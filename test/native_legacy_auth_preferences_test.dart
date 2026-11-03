import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/generated/es_prefs.pb.dart' as proto;
import 'package:spotify_flutter/protocol/native_legacy_auth_codec.dart';
import 'package:spotify_flutter/protocol/native_legacy_auth_json.dart';
import 'package:spotify_flutter/protocol/native_legacy_auth_preferences.dart';
import 'package:spotify_flutter/protocol/prefs_persistence.dart';
import 'package:spotify_flutter/protocol/prefs_store.dart';

class _ObservedStore extends PrefsStore {
  final events = <Map<String, Object?>>[];
  final registrations = <Map<String, Object?>>[];
  @override
  bool register(String key, proto.Value value, {int flags = 0}) {
    registrations.add({'key': key, 'value': _value(value), 'flags': flags});
    return super.register(key, value, flags: flags);
  }
  @override
  proto.PrefValues get(String key) {
    events.add({'operation': 'get', 'key': key});
    return super.get(key);
  }
  @override
  proto.PrefValues set(Map<String, proto.Value> values) {
    for (final entry in values.entries) {
      events.add({'operation': 'set', 'key': entry.key, 'value': _value(entry.value)});
    }
    return super.set(values);
  }
  @override
  void reset(String key) {
    events.add({'operation': 'reset', 'key': key});
    super.reset(key);
  }
}

Object _value(proto.Value value) => value.whichValue() == proto.Value_Value.bool_2 ? value.bool_2 : value.string;
proto.Value _proto(Object? value) => value is bool ? proto.Value(bool_2: value) : proto.Value(string: value as String);
String _hex(List<int> value) => value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
Map<String, Object?> _stored(NativeLegacyStoredCredentials value) => {
  'username': value.username, 'blobHex': _hex(value.encodedBlob), 'deviceId': value.deviceId};

Object? _apply(NativeLegacyAuthPreferences owner, String operation, Map arguments) {
  switch (operation) {
    case 'readLegacy':
      final result = owner.readLegacy();
      return {'available': result.available, 'enabled': result.enabled,
        'stored': _stored(result.stored), 'canonicalUsername': result.canonicalUsername};
    case 'readSaved':
      final result = owner.readSaved(arguments['canonicalUsername'] as String);
      return result == null ? null : _stored(result);
    case 'savedCanonicalUsernames': return owner.savedCanonicalUsernames();
    case 'enabled': return owner.enabled;
    case 'clearBlob': owner.clearBlob();
    case 'updateLegacy':
      owner.updateLegacy(NativeLegacyStoredCredentials(username: arguments['username'] as String,
        encodedBlob: utf8.encode(arguments['blob'] as String), deviceId: 'ignored-device'),
        canonicalUsername: arguments['canonicalUsername'] as String,
        saveCredentials: arguments['saveCredentials'] as bool);
    case 'setEnabled': owner.setEnabled(arguments['username'] as String, arguments['enabled'] as bool);
    case 'forget': owner.forget(arguments['username'] as String);
    default: throw StateError('Unknown fixture operation $operation');
  }
  return null;
}

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-legacy-preferences.json').readAsStringSync()) as Map;
  final device = fixture['deviceId'] as String;
  test('native legacy accessor registers its durable desktop defaults', () {
    final store = _ObservedStore();
    addTearDown(store.close);
    NativeLegacyAuthPreferences(store: store, deviceId: device);
    expect(store.registrations, fixture['registration']);
    expect({for (final record in store.records()) record.key: _value(record.defaultValue)},
      {for (final record in fixture['registration'] as List) record['key']: record['value']});
  });

  for (final scenario in fixture['scenarios'] as List) {
    test('original legacy preference owner: ${scenario['name']}', () {
      final store = _ObservedStore();
      addTearDown(store.close);
      store.restoreOverrides({for (final entry in (scenario['preferences'] as Map).entries)
        entry.key as String: _proto(entry.value)});
      final owner = NativeLegacyAuthPreferences(store: store, deviceId: device);
      store.events.clear();
      final result = _apply(owner, scenario['operation'] as String, scenario['arguments'] as Map);
      final expected = scenario['expected'] as Map;
      expect(result, expected['result']);
      expect(store.events, expected['events']);
      expect({for (final entry in store.getAll().entries.entries) entry.key: _value(entry.value)}, expected['preferences']);
    });
  }

  test('native reset removes override ownership without erasing registration or flag0x80', () async {
    for (final row in fixture['resetCallback'] as List) {
      final store = PrefsStore();
      addTearDown(store.close);
      final flags = row['flags'] as int;
      store.register('key', proto.Value(string: 'default'), flags: flags & ~0x303);
      if ((flags & 0x100) != 0) store.set({'key': proto.Value(string: 'override')});
      expect(store.records().single.flags, flags);
      final changes = <PrefsChange>[];
      final subscription = store.changes.listen(changes.add);
      store.reset('key');
      final expected = row['expected'] as Map;
      expect(store.records().single.flags, expected['flags'], reason: row['name'] as String);
      expect(store.get('key').entries['key']!.string, 'default');
      expect(changes.length, (expected['events'] as List).where((value) => value == 'changed').length);
      await subscription.cancel();
    }
  });

  test('unsupported preserved saved-map data prevents legacy preference replacement', () {
    final store = _ObservedStore();
    addTearDown(store.close);
    store.restoreOverrides({'autologin.username': proto.Value(string: 'prior-user'),
      'autologin.blob': proto.Value(string: 'prior-blob'),
      'autologin.saved_credentials': proto.Value(string: '{"other":42}')});
    final owner = NativeLegacyAuthPreferences(store: store, deviceId: device);
    store.events.clear();
    expect(() => owner.updateLegacy(NativeLegacyStoredCredentials(username: 'replacement',
      encodedBlob: utf8.encode('replacement-blob'), deviceId: device),
      canonicalUsername: 'canonical', saveCredentials: true), throwsA(isA<NativeLegacyAuthJsonUnsupported>()));
    expect(store.events, [{'operation': 'get', 'key': 'autologin.saved_credentials'}]);
    expect(store.get('autologin.username').entries['autologin.username']!.string, 'prior-user');
    expect(store.get('autologin.blob').entries['autologin.blob']!.string, 'prior-blob');
    expect(store.get('autologin.saved_credentials').entries['autologin.saved_credentials']!.string, '{"other":42}');
  });

  test('saved credentials persist through an owned file and disabling survives reopening', () async {
    final directory = await Directory.systemTemp.createTemp('spotify-legacy-auth-owned-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/prefs');
    final original = (fixture['scenarios'] as List).first['preferences'] as Map;
    final stored = NativeLegacyStoredCredentials(username: original['autologin.username'] as String,
      encodedBlob: utf8.encode(original['autologin.blob'] as String), deviceId: device);

    Future<(NativeLegacyAuthPreferences, PrefsPersistence)> open() async {
      final store = PrefsStore();
      addTearDown(store.close);
      final persistence = await PrefsPersistence.open(store: store, file: file, scope: PrefsScope.desktop);
      addTearDown(persistence.close);
      return (NativeLegacyAuthPreferences(store: store, deviceId: device), persistence);
    }

    final (first, firstFile) = await open();
    first.updateLegacy(stored, canonicalUsername: stored.username, saveCredentials: true);
    expect(firstFile.dirty, isTrue);
    expect(await firstFile.close(), isTrue);

    final (second, secondFile) = await open();
    expect(secondFile.loadSucceeded, isTrue);
    expect(second.readLegacy().available, isTrue);
    expect(_stored(second.readSaved(stored.username)!), _stored(stored));
    second.setEnabled(stored.username, false);
    expect(await secondFile.close(), isTrue);

    final (third, thirdFile) = await open();
    expect(thirdFile.loadSucceeded, isTrue);
    final restored = third.readLegacy();
    expect(restored.enabled, isFalse);
    expect(restored.available, isFalse);
    expect(restored.stored.username, isEmpty);
    expect(third.readSaved(stored.username), isNull);
  });
}
