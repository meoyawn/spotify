import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/spotify_audio_decrypt.dart';

Stream<List<int>> _chunks(List<int> bytes) async* {
  yield const [];
  const sizes = [1, 15, 16, 17, 149, 64, 773, 7, 512];
  var offset = 0, index = 0;
  while (offset < bytes.length) {
    final end = min(bytes.length, offset + sizes[index++ % sizes.length]);
    yield bytes.sublist(offset, end);
    offset = end;
  }
}

Future<Uint8List> _collect(Stream<List<int>> source) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in source) { bytes.add(chunk); }
  return bytes.takeBytes();
}

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/spotify-audio-decrypt.json').readAsStringSync()) as Map;
  final key = hex.decode(fixture['keyHex'] as String);
  final plaintext = hex.decode(fixture['plaintextHex'] as String);
  final ciphertext = hex.decode(fixture['ciphertextHex'] as String);

  test('Authorized file chunks and range seeks match independent OpenSSL AES-CTR bytes', () async {
    final mutableKey = [...key];
    final encrypted = SpotifyAudioDecryptor.encrypted(mutableKey);
    mutableKey[0] ^= 255;
    const unencrypted = SpotifyAudioDecryptor.unencrypted();
    for (final entry in [(encrypted, ciphertext), (unencrypted, plaintext)]) {
      for (final offset in [0, 1, 15, 16, 17, 166, 167, 168, 1743, 1744, 1745, 4095, 4609]) {
        for (final length in [0, 1, 15, 16, 167, 511, plaintext.length]) {
          final end = min(plaintext.length, offset + length);
          final range = entry.$2.sublist(offset, end);
          for (final ogg in [false, true]) {
            final start = ogg ? min(end, max(offset, 0xa7)) : offset;
            final expected = plaintext.sublist(start, end);
            final label = 'offset=$offset length=$length ogg=$ogg';
            expect(await _collect(entry.$1.transform(_chunks(range), byteOffset: offset, spotifyOgg: ogg)),
              expected, reason: label);
          }
        }
      }
    }
    for (final scenario in fixture['largeOffsets'] as List) {
      expect(await _collect(encrypted.transform(_chunks(hex.decode(scenario['ciphertextHex'] as String)),
        byteOffset: scenario['offset'] as int, spotifyOgg: true)),
        hex.decode(scenario['plaintextHex'] as String), reason: '64-bit range offset ${scenario['offset']}');
    }
  });

  test('Malformed keys, offsets and non-octet input fail without an implicit plaintext mode', () async {
    for (final malformed in [List.filled(15, 0), List.filled(17, 0), [-1, ...key.skip(1)], [256, ...key.skip(1)]]) {
      expect(() => SpotifyAudioDecryptor.encrypted(malformed), throwsArgumentError);
    }
    final encrypted = SpotifyAudioDecryptor.encrypted(key);
    expect(() => encrypted.transform(const Stream.empty(), byteOffset: -1), throwsRangeError);
    expect(() => const SpotifyAudioDecryptor.unencrypted().transform(const Stream.empty(), byteOffset: -1), throwsRangeError);
    await expectLater(encrypted.transform(Stream.value([0, 256, 1])), emitsError(isArgumentError));
    await expectLater(const SpotifyAudioDecryptor.unencrypted().transform(Stream.value([-1])), emitsError(isArgumentError));
  });
}
