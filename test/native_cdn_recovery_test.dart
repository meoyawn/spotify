import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io' show Directory, File, HttpException;

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/playback/spotify_audio_decrypt.dart';
import 'package:spotify_flutter/playback/spotify_audio_stager.dart';
import 'package:spotify_flutter/playback/spotify_media_client.dart';
import 'package:spotify_flutter/playback/spotify_media_source.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/protocol/generated/storage-resolve.pb.dart' as storage;
import 'package:spotify_flutter/protocol/native_http_defaults.dart';

void main() {
  // The actual source owns recovery. Per-request/cursor checks cannot detect
  // this path abandoning a source or rebuilding its Range/playback ID on B.
  test('Source early-header-close failover preserves original A-to-B outgoing requests', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-cdn-recovery.json').readAsStringSync()) as Map;
    final initial = fixture['initialRange'] as Map;
    final urls = (fixture['suppliedUrls'] as List).cast<String>();
    const defaults = NativeHttpDefaults(userAgent: 'Spotify/independent-offline-fixture');
    final factory = SpotifyRequests(baseUrl: 'https://spclient.example.test',
      inheritedHeaders: const {}, defaults: defaults);
    final directory = await Directory.systemTemp.createTemp('spotify-cdn-outgoing-');
    addTearDown(() => directory.delete(recursive: true));
    final fileId = List<int>.generate(20, (index) => index);
    final outgoing = <Map<String, Object>>[];
    final admission = Completer<void>();
    final decryption = Completer<SpotifyAudioDecryptor>();
    final client = SpotifyMediaClient(requests: factory,
      playbackId16: hex.decode(initial['playbackIdHex'] as String),
      send: (request) async {
        if (request.url.startsWith('https://spclient.example.test/')) {
          final resolved = storage.StorageResolveResponse(
            result: storage.StorageResolveResponse_Result.CDN, fileid: fileId, cdnurl: urls);
          return http.StreamedResponse(Stream.value(resolved.writeToBuffer()), 200);
        }
        outgoing.add({'method': request.method, 'url': request.url,
          'headers': request.headers, 'bodyHex': hex.encode(request.body)});
        if (request.url == urls.first) {
          throw const HttpException('Connection closed before full header was received');
        }
        // An unencrypted local dummy only lets the real source/stager finish.
        // No decoder or account is involved; file contents are not asserted.
        return http.StreamedResponse(Stream.value(const [1, 2, 3, 4]), 206,
          contentLength: 4, headers: const {'content-range': 'bytes 0-3/4'});
      });
    const uri = 'spotify:track:0000000000000000000001';
    final source = SpotifyMediaSource(client: client,
      stager: SpotifyAudioStager(directory: directory),
      selectAudio: (_, {cancellationToken}) async => SpotifyAudioSelection(uri: uri, fileId: fileId,
        trackGid: List.filled(16, 0), container: SpotifyAudioContainer.mp3,
        storageMode: 0, audioFormat: 0),
      decryptionAdmission: admission.future,
      obtainDecryption: (_, {cancellationToken}) => decryption.future,
      selectCdn: (response) => response.cdnurl.first,
      rangeBytes: initial['rangeBytes'] as int);
    final pending = source.resolve(uri);
    // The original captures place the first CDN request after the successful
    // license/storage responses. Local key computation is kept pending here;
    // the actual outgoing requests must already match the original A→B bytes.
    await Future<void>.delayed(Duration.zero);
    final requestsBeforeAdmission = outgoing.length;
    admission.complete();
    await Future<void>.delayed(Duration.zero);
    final requestsBeforeLocalKeyReady = outgoing.length;
    decryption.complete(const SpotifyAudioDecryptor.unencrypted());
    final prepared = await pending;
    final expected = [for (final request in initial['requests'] as List) {
      ...request as Map,
      // The shared native constructor's separately proved explicit UA input.
      'headers': {...request['headers'] as Map, 'User-Agent': defaults.userAgent},
    }];
    try {
      expect(requestsBeforeAdmission, 0,
        reason: 'Media requests must wait for a successful license admission');
      expect(outgoing, expected);
      expect(requestsBeforeLocalKeyReady, expected.length,
        reason: 'Opening the admitted CDN request must overlap local key computation');
    }
    finally { await prepared.close(); }
  });
}
