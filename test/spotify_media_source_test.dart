import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/generated/storage-resolve.pb.dart';
import 'package:spotify_flutter/playback/spotify_audio_decrypt.dart';
import 'package:spotify_flutter/playback/spotify_audio_stager.dart';
import 'package:spotify_flutter/playback/spotify_media_client.dart';
import 'package:spotify_flutter/playback/spotify_media_source.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';

void main() {
  test('Dart source stages authenticated byte ranges and rejects shifted or truncated media', () async {
    final directory = await Directory.systemTemp.createTemp('spotify-source-test-');
    addTearDown(() => directory.delete(recursive: true));
    final fixture = jsonDecode(File('reverse-engineering/fixtures/spotify-audio-decrypt.json').readAsStringSync()) as Map;
    final ciphertext = hex.decode(fixture['ciphertextHex'] as String);
    final plaintext = hex.decode(fixture['plaintextHex'] as String);
    const signedUrl = 'https://media.example/audio?token=synthetic%2fproof&x=+&x=%7e';
    const uri = 'spotify:track:0123456789abcdefghijkl';
    final requests = SpotifyRequests(baseUrl: 'https://spclient.example',
      inheritedHeaders: const {'Authorization': 'Bearer synthetic-access', 'client-token': 'synthetic-client'},
      defaults: const NativeHttpDefaults(userAgent: 'synthetic-native-UA'));
    for (final failure in [null, 'shift', 'truncate']) {
      final ranges = <String>[];
      final client = SpotifyMediaClient(requests: requests, send: (request) async {
        if (request.url.startsWith('https://spclient.example/')) {
          final body = StorageResolveResponse(cdnurl: [signedUrl]).writeToBuffer();
          return http.StreamedResponse(Stream.value(body), 200);
        }
        expect(request.url, signedUrl);
        expect(request.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
        expect(request.headers.keys.map((key) => key.toLowerCase()), isNot(contains('client-token')));
        final range = request.headers['Range']!;
        ranges.add(range);
        final bounds = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range)!;
        final start = int.parse(bounds[1]!);
        final end = min(int.parse(bounds[2]!), ciphertext.length - 1);
        final body = ciphertext.sublist(start, end + 1 - (failure == 'truncate' ? 1 : 0));
        return http.StreamedResponse(Stream.value(body), 206,
          headers: {'Content-Range': 'bytes ${start + (failure == 'shift' ? 1 : 0)}-$end/${ciphertext.length}'});
      });
      final source = SpotifyMediaSource(client: client, stager: SpotifyAudioStager(directory: directory),
        selectAudio: (selected, {cancellationToken}) async => SpotifyAudioSelection(uri: selected,
          fileId: List.filled(20, 7), trackGid: List.filled(16, 8), container: SpotifyAudioContainer.flac,
          storageMode: 0, audioFormat: 42,
          metadata: const {'title': 'Authorized fixture'}),
        obtainDecryption: (_, {cancellationToken}) async => SpotifyAudioDecryptor.encrypted(hex.decode(fixture['keyHex'] as String)),
        selectCdn: (response) => response.cdnurl.single, rangeBytes: 2048);
      if (failure != null) {
        await expectLater(source.resolve(uri), throwsFormatException);
      } else {
        final file = await source.resolve(uri);
        expect(ranges, ['bytes=0-2047', 'bytes=2048-4095', 'bytes=4096-${ciphertext.length - 1}']);
        expect(await File(file.path).readAsBytes(), plaintext);
        expect(file.metadata['title'], 'Authorized fixture');
        await file.close();
      }
      expect(await directory.list().toList(), isEmpty);
    }
  });
}
