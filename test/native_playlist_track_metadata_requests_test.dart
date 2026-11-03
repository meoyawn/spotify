import 'dart:convert' show jsonDecode;
import 'dart:io' show File;

import 'package:convert/convert.dart' show hex;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/playlist_service/native_track_metadata_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';

void main() {
  test('Original playlist base Track producer matches outgoing batch headers and exact protobuf or gzip body', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-playlist-track-metadata-requests.json')
      .readAsStringSync()) as Map<String, dynamic>;
    final template = fixture['injectedTemplate'] as Map<String, dynamic>;
    final templateHeaders = (template['headers'] as Map).cast<String, String>();
    final requests = SpotifyRequests(baseUrl: 'https://spclient.example.test:443/',
      inheritedHeaders: const {}, defaults: NativeHttpDefaults(userAgent: templateHeaders['User-Agent']!));
    for (final value in fixture['cases'] as List) {
      final input = value as Map<String, dynamic>;
      final expected = input['request'] as Map<String, dynamic>;
      final plan = NativePlaylistTrackMetadataPlan.forFreshTracks(
        uris: (input['uris'] as List).cast<String>(),
        country: input['country'] as String, catalogue: input['catalogue'] as String,
        fetchAssociationsWithTrackV4Enabled: input['fetchAssociationsWithTrackV4Enabled'] as bool);
      final actual = plan.envelope(requests);
      final reason = input['name'] as String;
      expect(actual.method, expected['method'], reason: reason);
      expect(actual.url, expected['rawUrl'], reason: reason);
      expect(actual.headers, expected['headers'], reason: reason);
      expect(actual.body, hex.decode(expected['bodyHex'] as String), reason: reason);
    }
  });
}
