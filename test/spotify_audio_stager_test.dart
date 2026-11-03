import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/spotify_audio_decrypt.dart';
import 'package:spotify_flutter/playback/spotify_audio_stager.dart';

void main() {
  test('Decrypted media is owned until release; partial or failed bodies leave no file', () async {
    final root = await Directory.systemTemp.createTemp('spotify-stager-test-');
    addTearDown(() => root.delete(recursive: true));
    final stager = SpotifyAudioStager(directory: root);
    final fixture = jsonDecode(File('reverse-engineering/fixtures/spotify-audio-decrypt.json').readAsStringSync()) as Map;
    final encrypted = hex.decode(fixture['ciphertextHex'] as String);
    final media = await stager.stage(Stream.value(encrypted), encryptedLength: encrypted.length,
      decryptor: SpotifyAudioDecryptor.encrypted(hex.decode(fixture['keyHex'] as String)),
      container: SpotifyAudioContainer.flac, metadata: const {'title': 'Owned source'});
    expect(await File(media.path).readAsBytes(), hex.decode(fixture['plaintextHex'] as String));
    expect(media.metadata['title'], 'Owned source');
    await media.close();
    await media.close();
    expect(await root.list().toList(), isEmpty);

    Stream<List<int>> broken() async* { yield [1]; throw StateError('source disconnected'); }
    for (final source in [Stream<List<int>>.value([1]), Stream<List<int>>.value([1, 2, 3]), broken()]) {
      await expectLater(stager.stage(source, encryptedLength: 2,
        decryptor: const SpotifyAudioDecryptor.unencrypted(), container: SpotifyAudioContainer.mp3),
        throwsA(anyOf(isFormatException, isStateError)));
      expect(await root.list().toList(), isEmpty);
    }
  });
}
