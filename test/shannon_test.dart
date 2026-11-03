import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/shannon.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

Iterable<List<int>> _fragmentPlans(int length) sync* {
  yield [length];
  if (length >= 3) yield [3, length - 3];
  yield length == 0 ? [0] : List.filled(length, 1);
  final mixed = <int>[0];
  var remaining = length, step = 1;
  while (remaining > 0) {
    final count = step < remaining ? step : remaining;
    mixed.addAll([count, 0]);
    remaining -= count;
    step = step % 5 + 1;
  }
  yield mixed;
}

Uint8List _transform(ShannonCipher cipher, Uint8List input,
    List<int> plan, {required bool decrypt}) {
  // Real packet codecs pass views, including views with an unaligned offset.
  final storage = Uint8List.fromList([0x5a, ...input, 0xa5]);
  final bytes = Uint8List.sublistView(storage, 1, input.length + 1);
  var offset = 0;
  for (final length in plan) {
    final fragment = Uint8List.sublistView(bytes, offset, offset + length);
    if (decrypt) { cipher.decrypt(fragment); } else { cipher.encrypt(fragment); }
    offset += length;
  }
  expect(offset, input.length);
  expect([storage.first, storage.last], [0x5a, 0xa5]);
  return bytes;
}

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/shannon.json').readAsStringSync()) as Map;

  test('Shannon packet bytes, MACs and nonce resets match independent reference vectors across fragments', () {
    for (final item in fixture['cases'] as List) {
      final vector = item as Map;
      final key = _hex(vector['keyHex'] as String);
      final plain = _hex(vector['plaintextHex'] as String);
      final encrypted = _hex(vector['ciphertextHex'] as String);
      final mac = _hex(vector['macHex'] as String);
      final nonce = vector['nonce'] as int;
      final macLength = vector['macLength'] as int;
      final encoder = ShannonCipher(key), decoder = ShannonCipher(key);
      for (final plan in _fragmentPlans(plain.length)) {
        final reason = '${vector['name']} nonce=$nonce chunks=$plan';
        encoder.nonce(nonce);
        decoder.nonce(nonce);
        expect(_transform(encoder, plain, plan, decrypt: false), encrypted, reason: reason);
        expect(_transform(decoder, encrypted, plan, decrypt: true), plain, reason: reason);
        expect(encoder.finish(length: macLength), mac, reason: reason);
        expect(decoder.finish(length: macLength), mac, reason: reason);
      }
      // Reuse the keyed instance for a different packet counter/message, then
      // discard an unfinished one-byte message and restore the original nonce.
      final reuse = vector['reuse'] as Map;
      encoder.nonce(reuse['nonce'] as int);
      final second = _hex(reuse['plaintextHex'] as String);
      encoder.encrypt(second);
      expect(second, _hex(reuse['ciphertextHex'] as String), reason: '${vector['name']} next nonce');
      expect(encoder.finish(), _hex(reuse['macHex'] as String), reason: '${vector['name']} next MAC');
      encoder.nonce(nonce);
      encoder.encrypt(Uint8List.fromList([0xff]));
      encoder.nonce(nonce);
      final restored = Uint8List.fromList(plain);
      encoder.encrypt(restored);
      expect(restored, encrypted, reason: '${vector['name']} reset unfinished message');
      expect(encoder.finish(length: macLength), mac, reason: '${vector['name']} reset MAC');
    }
  });
}
