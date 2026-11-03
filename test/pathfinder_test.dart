import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/pathfinder.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

class _FixtureFailure implements Exception {
  const _FixtureFailure(this.status);
  final int status;
}

Map<String, Object?> _errorSummary(Object error) => switch (error) {
  HttpResponseError() => {
    'name': error.name,
    'message': error.message,
    'status': error.status,
  },
  GraphQLFallbackUnavailableError() => {
    'name': error.name,
    'message': error.message,
    'reason': error.reason,
  },
  _FixtureFailure() => {
    'name': 'Error',
    'message': 'synthetic failure',
    'status': error.status,
  },
  _ => throw StateError('Unexpected failure: $error'),
};

void main() {
  group('Original Pathfinder loader conformance', () {
    final fixture = jsonDecode(
      File('reverse-engineering/fixtures/pathfinder-oracle.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final scenario
        in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () async {
        final builder = SpotifyRequestBuilder(
          accessToken: 'fixture-access-token',
          market: 'from_token',
          locale: 'en-US',
          globalHeaders: {
            'App-Platform': 'fixture-platform',
            'Spotify-App-Version': '1.3.6.1921',
          },
        );
        final operationInput = fixture['operation'] as Map<String, dynamic>;
        final operation = PathfinderOperation(
          name: operationInput['name'] as String,
          operation: operationInput['operation'] as String,
          sha256Hash: operationInput['sha256Hash'] as String,
          value: (scenario.containsKey('value')
              ? scenario['value']
              : operationInput['value']) as String?,
        );
        final requests = <Map<String, Object?>>[];
        final cacheCalls = <Map<String, Object?>>[];
        final thrownErrors = <Object>[];
        final responses = (scenario['responses'] as List)
            .cast<Map<String, dynamic>>();
        PathfinderCacheLayer? cacheLayer;
        if (scenario.containsKey('cache')) {
          cacheLayer = (
            receivedBuilder,
            receivedOperation,
            variables,
            query,
            headers,
            fetch,
            cacheSeconds,
          ) async {
            cacheCalls.add({
              'sameBuilder': identical(receivedBuilder, builder),
              'sameOperation': identical(receivedOperation, operation),
              'variables': variables,
              'query': query,
              'headers': headers,
              'cacheSeconds': cacheSeconds,
            });
            if (scenario['cache'] == 'hit') return {'cached': true};
            return await fetch();
          };
        }
        final loader = PathfinderLoader(
          builder,
          isInternalRequest: scenario['isInternalRequest'] == true,
          cacheLayer: cacheLayer,
          send: (request) async {
            requests.add({
              'envelope': request.envelope.toJson(),
              'endpointIdentifier': request.endpointIdentifier,
              'abortSignal': request.abortSignal,
            });
            if (requests.length > responses.length) {
              throw StateError('Unexpected extra request');
            }
            final response = responses[requests.length - 1];
            if (response['error'] != null) {
              final Object error = response['error'] == 'http'
                  ? HttpResponseError(
                      message: 'synthetic failure',
                      url: request.envelope.url,
                      method: request.envelope.method,
                      status: response['status'] as int,
                    )
                  : _FixtureFailure(response['status'] as int);
              thrownErrors.add(error);
              throw error;
            }
            return PathfinderResponse(body: response['body']);
          },
        );
        final actual = <String, Object?>{
          'requests': requests,
          'cacheCalls': cacheCalls,
        };
        try {
          actual['result'] = await loader.load(
            operation,
            fixture['variables'],
            query: (scenario['query'] as Map<String, dynamic>?) ?? {},
            headers: (scenario['headers'] as Map<String, dynamic>?)
                    ?.cast<String, String>() ?? {},
            abortSignal: scenario['abortSignal'],
            cacheSeconds: (scenario['cacheSeconds'] as int?) ?? -1,
          );
        } catch (error) {
          actual['error'] = _errorSummary(error);
          actual['sameThrownError'] = thrownErrors.any(
            (thrown) => identical(thrown, error),
          );
        }
        expect(actual, scenario['expected']);
      });
    }
  });
}
