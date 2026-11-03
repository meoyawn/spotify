import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/desktop_prefs_service.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';
import 'package:spotify_flutter/protocol/generated/es_prefs.pb.dart' as proto;
import 'package:spotify_flutter/protocol/prefs_store.dart';

proto.Value _value(Map<String, dynamic> value) {
  if (value.containsKey('number')) return proto.Value(number: Int64.parseInt(value['number'].toString()));
  if (value.containsKey('bool')) return proto.Value(bool_2: value['bool'] as bool);
  if (value.containsKey('string')) return proto.Value(string: value['string'] as String);
  return proto.Value();
}

Map<String, Object> _jsonValue(proto.Value value) => switch (value.whichValue()) {
  proto.Value_Value.number => {'number': value.number.toString()},
  proto.Value_Value.bool_2 => {'bool': value.bool_2},
  proto.Value_Value.string => {'string': value.string},
  proto.Value_Value.notSet => {},
};

Future<proto.PrefValues> _call(EsperantoDispatcher dispatcher, String method, List<int> payload) async =>
  proto.PrefValues.fromBuffer(await dispatcher.callSingle(EsperantoCall(DesktopPrefsService.id, method, payload)));

void main() {
  group('Original native preferences', () {
    final native = jsonDecode(File('reverse-engineering/fixtures/native-prefs-values.json').readAsStringSync()) as Map<String, dynamic>;
    final cases = (native['cases'] as List).cast<Map<String, dynamic>>();

    test('local service accepts original renderer request bytes and preserves oneof defaults', () async {
      final renderer = jsonDecode(File('reverse-engineering/fixtures/prefs-renderer.json').readAsStringSync()) as Map<String, dynamic>;
      final scenario = (renderer['scenarios'] as List).cast<Map<String, dynamic>>()
        .singleWhere((item) => item['name'] == 'set preserves zero and empty oneof values');
      final hex = scenario['calls'][0]['payloadHex'] as String;
      final payload = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
      final store = PrefsStore()
        ..register('zero', proto.Value(number: Int64(42)))
        ..register('disabled', proto.Value(bool_2: true))
        ..register('empty', proto.Value(string: 'previous'))
        ..register('minimum', proto.Value(number: Int64(42)))
        ..register('maximum', proto.Value(number: Int64(42)))
        ..register('absent', proto.Value(string: 'previous'));
      addTearDown(store.close);
      final dispatcher = EsperantoDispatcher();
      DesktopPrefsService(store).register(dispatcher);
      final response = await _call(dispatcher, 'Set', payload);
      expect({for (final entry in response.entries.entries) entry.key: _jsonValue(entry.value)}, {
        'zero': {'number': '0'}, 'disabled': {'bool': false}, 'empty': {'string': ''},
        'minimum': {'number': '0'}, 'maximum': {'number': '-1'}, 'absent': {'string': ''},
      });
    });

    test('registered reads and Set coercions match original Value glue', () async {
      for (final scenario in cases.where((item) => ['read', 'write'].contains(item['input']['operation']))) {
        final input = scenario['input'] as Map<String, dynamic>;
        final store = PrefsStore();
        addTearDown(store.close);
        final type = (input['typeFlags'] as int) & 3;
        final defaultValue = switch (type) {
          1 => {'bool': input['storedValue'] ?? false},
          2 => {'number': input['storedValue'] ?? '0'},
          3 => {'string': input['storedValue'] ?? ''},
          _ => <String, dynamic>{},
        };
        if (input['registered'] != false) store.register('synthetic.key', _value(defaultValue));
        final dispatcher = EsperantoDispatcher();
        DesktopPrefsService(store).register(dispatcher);
        final response = input['operation'] == 'read'
          ? await _call(dispatcher, 'Get', proto.GetParams(key: 'synthetic.key').writeToBuffer())
          : await _call(dispatcher, 'Set', proto.SetParams(entries: {
              'synthetic.key': _value(input['inputValue'] as Map<String, dynamic>),
            }.entries).writeToBuffer());
        if (input['registered'] == false) {
          expect(response.entries, isEmpty, reason: scenario['name'] as String);
        } else {
          final expected = input['operation'] == 'read' ? scenario['value'] :
            (scenario['writes'] as List).isEmpty ? <String, dynamic>{} : scenario['writes'][0];
          expect(_jsonValue(response.entries['synthetic.key']!), expected, reason: scenario['name'] as String);
        }
      }
    });

    test('override elision, Create and notification decisions match original registry', () async {
      for (final scenario in cases.where((item) => ['engine', 'registration'].contains(item['input']['operation']))) {
        final input = scenario['input'] as Map<String, dynamic>;
        final flags = input['typeFlags'] as int;
        final store = PrefsStore();
        addTearDown(store.close);
        if ((flags & 0x200) != 0) {
          store.register('synthetic.key', _value(input['defaultValue'] as Map<String, dynamic>), flags: flags & ~0x303);
        }
        if (input['overrideValue'] != null) {
          store.restoreOverrides({'synthetic.key': _value(input['overrideValue'] as Map<String, dynamic>)});
        }
        final dispatcher = EsperantoDispatcher();
        DesktopPrefsService(store).register(dispatcher);
        final events = <PrefsChange>[];
        final subscription = store.changes.listen(events.add);
        final entries = {'synthetic.key': _value(input['inputValue'] as Map<String, dynamic>)};
        final method = input['operation'] == 'engine' ? 'Set' : 'Create';
        final request = method == 'Set' ? proto.SetParams(entries: entries.entries).writeToBuffer()
          : proto.CreateParams(entries: entries.entries).writeToBuffer();
        final response = await _call(dispatcher, method, request);
        expect(_jsonValue(response.entries['synthetic.key']!), scenario['value'], reason: scenario['name'] as String);
        expect(store.overrides().containsKey('synthetic.key'), scenario['hasOverride'], reason: scenario['name'] as String);
        expect(events.length, (scenario['notifications'] as List).length, reason: scenario['name'] as String);
        await subscription.cancel();
      }
    });

    test('desktop defaults and startup restore preserve native independent ownership', () async {
      final catalog = cases.singleWhere((item) => item['input']['operation'] == 'catalog')['registrations'] as List;
      final store = PrefsStore()..registerDesktopDefaults();
      addTearDown(store.close);
      final dispatcher = EsperantoDispatcher();
      DesktopPrefsService(store).register(dispatcher);
      final response = await _call(dispatcher, 'GetAll', proto.GetAllParams().writeToBuffer());
      expect({for (final entry in response.entries.entries) entry.key: _jsonValue(entry.value)},
        {for (final entry in catalog) entry['key']: entry['value']});
      store.set({'app.autostart-mode': proto.Value(string: 'off'), 'ui.minimize_to_tray': proto.Value(bool_2: true),
        'language': proto.Value(string: '')});
      final snapshot = store.overrides();
      expect(store.overrides(scopeMask: 4).keys, unorderedEquals(['app.autostart-mode', 'language']));
      expect(store.overrides(scopeMask: 8).keys, ['ui.minimize_to_tray']);
      final reopened = PrefsStore()..restoreOverrides(snapshot)..registerDesktopDefaults();
      addTearDown(reopened.close);
      expect(reopened.getAll(), store.getAll());
      reopened.set({'app.autostart-mode': proto.Value(string: 'minimized')});
      expect(reopened.overrides().containsKey('app.autostart-mode'), isFalse);
      expect(snapshot.containsKey('app.autostart-mode'), isTrue);
    });

    test('Sub listener filtering matches native exact and dot-prefix rules', () async {
      for (final scenario in cases.where((item) => item['input']['operation'] == 'filter')) {
        final input = scenario['input'] as Map<String, dynamic>;
        final key = input['changedKey'] as String;
        final prefix = input['prefix'] as String;
        final store = PrefsStore()..register(key, proto.Value(bool_2: false));
        final dispatcher = EsperantoDispatcher();
        DesktopPrefsService(store).register(dispatcher);
        final events = <proto.PrefValues>[];
        final first = Completer<void>();
        final subscription = dispatcher.callStream(EsperantoCall(DesktopPrefsService.id, 'Sub',
          proto.SubParams(key: prefix).writeToBuffer())).listen((bytes) {
            events.add(proto.PrefValues.fromBuffer(bytes));
            if (!first.isCompleted) first.complete();
          });
        await first.future;
        await _call(dispatcher, 'Set', proto.SetParams(entries: {key: proto.Value(bool_2: true)}.entries).writeToBuffer());
        await Future<void>.delayed(Duration.zero);
        expect(events.length, scenario['matches'] == true ? 2 : 1, reason: scenario['name'] as String);
        if (scenario['matches'] == true) {
          expect(events.last, store.get(prefix), reason: scenario['name'] as String);
        }
        await subscription.cancel();
        await store.close();
      }
    });

    test('SubAll captures every full snapshot and cancellation stops delivery', () async {
      final store = PrefsStore()..register('a', proto.Value(number: Int64.ZERO))..register('b', proto.Value(bool_2: false));
      addTearDown(store.close);
      final dispatcher = EsperantoDispatcher();
      DesktopPrefsService(store).register(dispatcher);
      final events = <Map<String, Map<String, Object>>>[];
      final first = Completer<void>();
      final subscription = dispatcher.callStream(EsperantoCall(DesktopPrefsService.id, 'SubAll',
        proto.SubAllParams().writeToBuffer())).listen((bytes) {
          events.add({for (final entry in proto.PrefValues.fromBuffer(bytes).entries.entries) entry.key: _jsonValue(entry.value)});
          if (!first.isCompleted) first.complete();
        });
      await first.future;
      store.set({'a': proto.Value(number: Int64(1))});
      store.set({'b': proto.Value(bool_2: true)});
      store.set({'b': proto.Value(bool_2: true)});
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        {'a': {'number': '0'}, 'b': {'bool': false}},
        {'a': {'number': '1'}, 'b': {'bool': false}},
        {'a': {'number': '1'}, 'b': {'bool': true}},
      ]);
      await subscription.cancel();
      store.set({'a': proto.Value(number: Int64(2))});
      await Future<void>.delayed(Duration.zero);
      expect(events.length, 3);
    });
  });
}
