import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/lyrics/repository.dart';
import 'package:spotify_flutter/protocol/native_renderer_http_request.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  group('Original lyrics outgoing protocol', () {
    test('Repository GET and preflight fields match original execution and capture', () async {
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-renderer-lyrics.json').readAsStringSync()) as Map;
      for (final input in fixture['cases'] as List) {
        final profile = NativeRendererSearchProfile(locale: input['locale'] as String);
        var captured = 0;
        final repository = LyricsRepository(builder: SpotifyRequestBuilder(
          locale: input['locale'] as String, market: 'from_token', accessToken: 'fixture-access-token',
          globalHeaders: NativeRendererSearchProfile.globalHeaders), send: (envelope) async {
          // Availability is a separate original producer. Its own fixture owns
          // that first request; a synthetic response admits the lyrics GET.
          if (input['kind'] == 'lyrics' && Uri.parse(envelope.url).path.startsWith('/metadata/4/')) {
            return const LyricsResponse(200, {'has_lyrics': true});
          }
          captured++;
          expect(envelope.toJson(), input['application'], reason: '${input['kind']} application request');
          final plan = profile.prepareLyrics(envelope, clientToken: input['clientToken'] as String);
          final fields = {':method': plan.method, ':authority': plan.authority,
            ':scheme': 'https', ':path': plan.rawTarget, ...plan.headers};
          expect(fields, input['expected']);
          expect(fields.keys.toList(), (input['expected'] as Map).keys.toList());
          expect(plan.body, isEmpty);
          final preflight = profile.preparePreflight(plan);
          final preflightFields = {':method': preflight.method, ':authority': preflight.authority,
            ':scheme': 'https', ':path': preflight.rawTarget, ...preflight.headers};
          expect(preflightFields, input['expectedPreflight']);
          expect(preflightFields.keys.toList(), (input['expectedPreflight'] as Map).keys.toList());
          expect(preflight.body, isEmpty);
          return input['kind'] == 'availability' ? const LyricsResponse(200, {'has_lyrics': false})
            : const LyricsResponse(404, null);
        });
        await repository.load(input['uri'] as String, input['image'] as String? ?? '',
          clientLanguage: input['clientLanguage'] as String?);
        expect(captured, 1);
      }
    });
  });
}
