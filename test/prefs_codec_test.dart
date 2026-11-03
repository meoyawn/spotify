import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/prefs_codec.dart';

List<int> _bytes(String hex) => [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
String _hex(List<int> bytes) => bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

Map<String, Object> _entry(PrefsDiskEntry entry) => {'keyHex': _hex(entry.keyBytes),
  switch (entry.value.kind) {
    PrefsDiskKind.boolean => 'bool', PrefsDiskKind.number => 'number',
    PrefsDiskKind.string => 'stringHex', PrefsDiskKind.unset => 'unset',
  }: switch (entry.value.kind) {
    PrefsDiskKind.boolean => entry.value.boolean!, PrefsDiskKind.number => entry.value.number!,
    PrefsDiskKind.string => _hex(entry.value.stringBytes), PrefsDiskKind.unset => true,
  }};

void main() {
  group('Original native prefs disk codec', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-prefs-codec.json').readAsStringSync()) as Map<String, dynamic>;

    test('parser matches native registrations for valid and malformed byte tokens', () {
      for (final scenario in (fixture['parseCases'] as List).cast<Map<String, dynamic>>()) {
        expect(PrefsCodec.decode(_bytes(scenario['inputHex'] as String)).map(_entry).toList(), scenario['entries'],
          reason: scenario['name'] as String);
      }
    });

    test('writer matches original bytes including every byte value and override omission', () {
      for (final scenario in (fixture['writeCases'] as List).cast<Map<String, dynamic>>()) {
        final input = scenario['input'] as Map<String, dynamic>;
        final value = input.containsKey('bool') ? PrefsDiskValue.boolean(input['bool'] as bool)
          : input.containsKey('number') ? PrefsDiskValue.number(input['number'] as int)
          : PrefsDiskValue.string(_bytes(input['stringHex'] as String));
        final result = PrefsCodec.encode([PrefsDiskEntry(_bytes(input['keyHex'] as String), value,
          flags: input['flags'] as int? ?? 0x100)]);
        expect(_hex(result), scenario['outputHex'], reason: input.toString());
      }
    });

    test('raw string bytes remain intact and UTF-8 failures occur only at the explicit bridge', () {
      final raw = PrefsCodec.decode(ascii.encode('value="\\xFF"\n')).single;
      expect(raw.value.stringBytes, [255]);
      expect(raw.toProtobuf, throwsFormatException);
      final text = PrefsDiskEntry(utf8.encode('synthetic.key'), PrefsDiskValue.string(utf8.encode('雪\u0000')));
      expect(text.toProtobuf().value.string, '雪\u0000');
      final copy = text.value.stringBytes;
      copy[0] = 0;
      expect(text.toProtobuf().value.string, '雪\u0000');
    });
  });
}
