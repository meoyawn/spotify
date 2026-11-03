import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/pathfinder.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';
import 'package:spotify_flutter/search/repository.dart';

void main() {
  test('Quick search outgoing query headers and body match original producer bytes', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/search-modal-original.json').readAsStringSync()) as Map;
    for (final row in fixture['scenarios'] as List) {
      final requests = <Map<String, Object?>>[];
      final repository = PathfinderSearchRepository(PathfinderLoader(
        SpotifyRequestBuilder(accessToken: 'fixture-access-token', market: 'from_token',
          locale: 'en', globalHeaders: const {
            'App-Platform': 'OSX_ARM64', 'Spotify-App-Version': '1.3.6.1921',
          }), send: (request) async {
            requests.add(request.envelope.toJson());
            return const PathfinderResponse(body: {'data': {}});
          }), features: SearchFeatures(includeAuthors: row['includeAuthors'] as bool));
      await repository.modal(row['query'] as String);
      expect(requests, row['expectedRequests'], reason: '${row['query']} / ${row['includeAuthors']}');
    }
  });
}
