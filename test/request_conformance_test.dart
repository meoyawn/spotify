import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spotify_flutter/protocol/http_transport.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  group('Original proprietary RequestBuilder conformance', () {
    final fixture = jsonDecode(
      File('reverse-engineering/fixtures/request-oracle.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final scenario
        in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () {
        final builder = SpotifyRequestBuilder(
          accessToken: 'fixture-access-token',
          market: 'from_token',
          locale: 'en-US',
          globalHeaders: {
            'App-Platform': 'fixture-platform',
            'Spotify-App-Version': '1.3.6.1921',
          },
        );
        final request = builder
            .build()
            .withHost('https://fixture.invalid')
            .withPath('/query');
        final options = scenario['options'] as Map<String, dynamic>;
        if (options['query'] case final Map<String, dynamic> query) {
          request.withQueryParameters(query);
        }
        if (options['method'] case final String method) {
          request.withMethod(method);
        }
        if (options['locale'] case final String locale) {
          request.withLocale(locale);
        }
        if (options['responseType'] case final String responseType) {
          request.withResponseType(responseType);
        }
        if (options['headers'] case final Map<String, dynamic> headers) {
          request.withHeaders(headers.cast<String, String>());
        }
        if (options.containsKey('body')) request.withBody(options['body']);
        if (options['withoutMarket'] == true) request.withoutMarket();
        if (options['withoutGlobalHeaders'] == true) {
          request.withoutGlobalHeaders();
        }
        if (options['withoutAuthorization'] == true) {
          request.withoutAuthorization();
        }
        if (options['json'] == true) request.withJsonContentType();
        if (options['credentials'] == true) request.withCredentials();
        expect(request.envelope().toJson(), scenario['expected']);
      });
    }
  });

  test('Pathfinder payload matches the body captured from the original UI', () {
    final fixture = jsonDecode(
      File('reverse-engineering/fixtures/original-search.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final captured = (fixture['requests'] as List).last as Map<String, dynamic>;
    final body = jsonDecode(captured['body'] as String) as Map<String, dynamic>;
    final request = persistedQuery(
      SpotifyRequestBuilder(locale: 'en', market: 'from_token'),
      operationName: body['operationName'] as String,
      sha256Hash: body['extensions']['persistedQuery']['sha256Hash'] as String,
      variables: body['variables'] as Map<String, dynamic>,
    );
    expect(request.method, captured['method']);
    expect(request.url, captured['url']);
    expect(request.body, utf8.encode(captured['body'] as String));
  });

  test(
    'Unverified remote requests never reach the underlying HTTP client',
    () async {
      var calls = 0;
      final transport = DartHttpTransport(
        MockClient((request) async {
          calls++;
          return http.Response('', 200);
        }),
      );
      addTearDown(transport.close);
      for (final url in [
        'https://api-partner.spotify.com/pathfinder/v2/query',
        'http://localhost:8000/query',
        'http://127.0.0.1.evil.invalid/query',
      ]) {
        await expectLater(
          transport.send(
            RequestEnvelope(method: 'POST', url: url, headers: {}),
          ),
          throwsStateError,
        );
      }
      expect(calls, 0);
    },
  );
}
