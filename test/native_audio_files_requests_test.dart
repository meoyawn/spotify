import 'dart:convert' show jsonDecode;
import 'dart:io' show File;

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/native_audio_files_request.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';

void main() {
  test('Original ready Track producer reaches matching Dart HTTP query/header/body bytes', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-audio-files-requests.json')
      .readAsStringSync()) as Map<String, dynamic>;
    final injected = fixture['injectedTemplate'] as Map<String, dynamic>;
    final injectedHeaders = (injected['headers'] as Map).cast<String, String>();
    final requests = SpotifyRequests(baseUrl: 'https://spclient.example.test:443/',
      inheritedHeaders: const {}, defaults: NativeHttpDefaults(userAgent: injectedHeaders['User-Agent']!));
    for (final value in fixture['cases'] as List) {
      final input = value as Map<String, dynamic>;
      final original = input['request'] as Map<String, dynamic>;
      final plan = NativeAudioFilesRequestPlan.forReadyTrackCacheMiss(
        uri: input['uri'] as String, country: input['country'] as String,
        catalogue: input['catalogue'] as String,
        nativeOwnerFlag51: input['nativeOwnerFlag51'] as bool,
        nativeOwnerFlag52: input['nativeOwnerFlag52'] as bool,
        nativeOwnerFlag53: input['nativeOwnerFlag53'] as bool);
      final outgoing = plan.envelope(requests);
      final reason = input['name'] as String;
      expect(outgoing.method, original['method'], reason: reason);
      expect(outgoing.url, original['rawUrl'], reason: reason);
      expect(outgoing.headers, original['headers'], reason: reason);
      expect(outgoing.body, hex.decode(original['bodyHex'] as String), reason: reason);
    }
  });
}
