import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/entities/native_song_repository.dart';
import 'package:spotify_flutter/lyrics/repository.dart';
import 'package:spotify_flutter/protocol/native_renderer_http_request.dart';
import 'package:spotify_flutter/protocol/pathfinder.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  group('Original song page contracts', () {
    test('Song, recommendations and credits reach the renderer with original descriptors and variables', () async {
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-song-page.json').readAsStringSync()) as Map;
      final calls = <String>[];
      final repository = NativeSongEntityRepository(PathfinderLoader(SpotifyRequestBuilder(locale: 'en',
        accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders), send: (request) async {
        final body = jsonDecode(utf8.decode(request.envelope.body)) as Map;
        final name = body['operationName'] as String;
        final original = (fixture['requests'] as List).singleWhere((value) => (value['operation'] as Map)['name'] == name) as Map;
        expect(body, {'variables': original['variables'], 'operationName': name,
          'extensions': {'persistedQuery': {'version': 1, 'sha256Hash': (original['operation'] as Map)['sha256Hash']}}});
        final plan = const NativeRendererSearchProfile(locale: 'en').prepareSearch(request.envelope,
          clientToken: 'fixture-client-token');
        expect(plan.method, 'POST');
        calls.add(name);
        return PathfinderResponse(body: {'data': switch (name) {
          'getTrack' => {'trackUnion': {'__typename': 'Track', 'uri': 'spotify:track:0000000000000000000001',
            'name': 'Fixture song', 'duration': {'totalMilliseconds': 226000}, 'playability': {'playable': true}}},
          'queryTrackCreditsGroupedModal' => {'trackUnion': {'__typename': 'Track',
            'creditsTrait': {'contributors': {'items': (fixture['credits'] as Map)['contributors']}}}},
          'internalLinkRecommenderTrack' => {'seoRecommendedTrack': {'items': []}},
          _ => {'seoRecommendedTrackAlbum': {'items': []}},
        }});
      }));
      const uri = 'spotify:track:0000000000000000000001';
      final page = await repository.open(uri);
      expect(page.details.name, 'Fixture song');
      expect(page.tracks.rows.single.durationMs, 226000);
      await repository.songCredits(uri);
      await repository.songRecommendations(uri);
      await repository.songRelatedAlbums(uri);
      await repository.songCredits(uri);
      expect(calls, ['getTrack', 'queryTrackCreditsGroupedModal',
        'internalLinkRecommenderTrack', 'similarAlbumsBasedOnThisTrack']);
    });

    test('Song lyrics use the original direct request and preserve account restrictions', () async {
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-song-page.json').readAsStringSync()) as Map;
      final original = fixture['lyricsCalls'] as List;
      final host = original.singleWhere((value) => value['method'] == 'withHost')['value'] as String;
      final path = original.singleWhere((value) => value['method'] == 'withPath')['value'] as String;
      final platform = (original.singleWhere((value) => value['method'] == 'withHeaders')['value'] as List).single['value'];
      for (final status in [200, 403, 404]) {
        var requests = 0;
        final repository = LyricsRepository(builder: SpotifyRequestBuilder(locale: 'en', market: 'from_token',
          accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders), send: (request) async {
          requests++;
          expect(request.url.split('?').first, '$host$path');
          expect(Uri.parse(request.url).queryParameters, {'format': 'json', 'vocalRemoval': 'false', 'market': 'from_token'});
          final plan = const NativeRendererSearchProfile(locale: 'en').prepareLyrics(request, clientToken: 'fixture-client-token');
          expect(plan.headers['app-platform'], platform);
          return LyricsResponse(status, status == 200 ? {'lyrics': {'lines': [
            {'startTimeMs': '0', 'words': 'A line written for this fixture.'}]}} : null);
        });
        final lyrics = await repository.loadSongPage('spotify:track:0000000000000000000001', 'https://fixture.invalid/cover');
        expect(requests, 1);
        expect(lyrics.availability, switch (status) {
          200 => LyricsAvailability.available, 403 => LyricsAvailability.restricted, _ => LyricsAvailability.unavailable});
      }
    });
  });
}
