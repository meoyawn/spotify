import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/entities/models.dart';
import 'package:spotify_flutter/entities/native_artist_repository.dart';
import 'package:spotify_flutter/entities/repository.dart';
import 'package:spotify_flutter/home/models.dart';
import 'package:spotify_flutter/home/destinations_repository.dart';
import 'package:spotify_flutter/home/destinations_controller.dart';
import 'package:spotify_flutter/home/repository.dart';
import 'package:spotify_flutter/protocol/native_renderer_http2_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_http2_pool.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';
import 'package:spotify_flutter/protocol/native_renderer_http_request.dart';
import 'package:spotify_flutter/protocol/pathfinder.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';
import 'package:spotify_flutter/search/models.dart';
import 'package:spotify_flutter/search/repository.dart';

void main() {
  test('Renderer Pathfinder sends original decoded fields and original Search Home album and artist body bytes', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-renderer-search.json').readAsStringSync()) as Map;
    final homeFixture = jsonDecode(File('reverse-engineering/fixtures/native-renderer-home.json').readAsStringSync()) as Map;
    final albumFixture = jsonDecode(File('reverse-engineering/fixtures/native-renderer-album.json').readAsStringSync()) as Map;
    final artistFixture = jsonDecode(File('reverse-engineering/evidence/native-renderer-artist.json').readAsStringSync()) as Map;
    final fullSearchFixture = jsonDecode(File('reverse-engineering/fixtures/native-renderer-full-search.json').readAsStringSync()) as Map;
    final destinationsFixture = jsonDecode(File('reverse-engineering/fixtures/native-renderer-home-destinations.json').readAsStringSync()) as Map;
    final originalH2 = jsonDecode(File('reverse-engineering/evidence/native-renderer-http2.json').readAsStringSync()) as Map;
    final priorityEvidence = jsonDecode(File('reverse-engineering/evidence/native-http2-priority.json').readAsStringSync()) as Map;
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/native_cef_h2_peer.py']);
    final errors = <String>[];
    final stderr = peer.stderr.transform(utf8.decoder).listen(errors.add);
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    NativeRendererHttp2Transport? sender;
    NativeCefHttp2Pool? pool;
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map;
      final authority = 'localhost:${ready['port']}';
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ready['certificate'] as String);
      final shared = NativeCefHttp2Pool(securityContext: trust);
      pool = shared;
      int? connectionId;
      var requestIndex = 0;
      for (final item in [...fixture['cases'] as List, ...homeFixture['cases'] as List,
          ...albumFixture['cases'] as List, ...artistFixture['cases'] as List, ...fullSearchFixture['cases'] as List,
          ...destinationsFixture['cases'] as List]) {
        final application = item['application'] as Map, expected = item['expected'] as Map;
        final originalFetch = item['fetchBoundary'] as Map;
        expect(originalFetch['mode'], 'cors');
        expect(originalFetch['credentials'], 'same-origin');
        expect(originalFetch['redirect'], 'follow');
        // Drain the peer while it writes its cumulative frame capture. Waiting
        // until after the HTTP response can fill stdout before the peer sends it.
        final nextCapture = output.moveNext().timeout(const Duration(seconds: 10));
        sender = NativeRendererHttp2Transport(profile: NativeRendererSearchProfile(
          locale: item['locale'] as String, endpoint: 'https://$authority/pathfinder/v2/query'),
          clientToken: () => item['clientToken'] as String, pool: shared);
        if (item['destinationKind'] != null) {
          final builder = SpotifyRequestBuilder(locale: item['locale'] as String,
            accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders);
          final transport = sender;
          Object? outgoingFailure;
          var requests = 0;
          final loader = PathfinderLoader(builder, send: (request) async {
            final original = request.envelope;
            final payload = jsonDecode(utf8.decode(original.body)) as Map;
            final variables = payload['variables'] as Map;
            final initialOffset = variables['sectionItemsOffset'] ??
              (variables['pagination'] as Map?)?['offset'] ?? (variables['pagePagination'] as Map?)?['offset'];
            if ((item['offset'] as int) > 0 && initialOffset == 0) {
              final kind = item['destinationKind'] as String;
              final section = {'__typename': kind == 'homeSection' ? 'HomeSection' : 'BrowseSection',
                'uri': item['uri'], 'data': {'__typename': kind == 'homeSection'
                  ? 'HomeGenericSectionData' : 'BrowseGenericSectionData'},
                'sectionItems': {'items': <Object?>[], 'pagingInfo': {'nextOffset': item['offset']}}};
              // A synthetic initial response reaches the public controller's
              // continuation. Original-executed cursor policy and body bytes
              // independently own the subsequent request; no first-page replay.
              return PathfinderResponse(body: {'data': {
                if (kind == 'homeSection') 'homeSections': {'__typename': 'HomeSectionCollection', 'sections': [section]}
                else if (kind == 'browseSection') 'browseSection': section
                else 'browse': {'__typename': 'BrowseSectionContainer', 'sections': {
                  'items': [section, section], 'pagingInfo': {'nextOffset': item['offset']}}},
              }});
            }
            try {
              requests++;
              final response = await transport.send(RequestEnvelope(method: original.method,
                url: 'https://$authority/pathfinder/v2/query', headers: original.headers, body: original.body,
                authorize: original.authorize, includeCredentials: original.includeCredentials, responseType: original.responseType));
              expect(response.statusCode, 200);
            } catch (error) { outgoingFailure = error; rethrow; }
            return const PathfinderResponse(body: {});
          });
          final repository = PathfinderHomeDestinationRepository(loader,
            context: HomeRequestContext(timeZone: 'Europe/Moscow', features: HomeFeatures(
              includeHomeChapterVideoCards: item['chapter'] as bool,
              includeEpisodeContentRatingsV2: item['ratings'] as bool)), sectionItemsLimit: item['limit'] as int?);
          try {
            final target = HomeDestinationTarget(
              HomeDestinationKind.values.byName(item['destinationKind'] as String), item['uri'] as String);
            if ((item['offset'] as int) == 0) {
              await repository.destination(target);
            } else {
              final controller = HomeDestinationController(repository, target);
              try { await controller.initialize(); await controller.loadMore(); }
              finally { controller.dispose(); }
            }
          } on HomeQueryError { /* Empty peer response; outgoing contract only. */ }
          final failure = outgoingFailure;
          if (failure != null) throw failure;
          expect(requests, 1, reason: '${item['destinationKind']}: one shelf/page request');
        } else if (item['searchKind'] != null) {
          final builder = SpotifyRequestBuilder(locale: item['locale'] as String,
            accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders);
          final transport = sender;
          Object? outgoingFailure;
          var requests = 0;
          final loader = PathfinderLoader(builder, send: (request) async {
            final original = request.envelope;
            try {
              requests++;
              final response = await transport.send(RequestEnvelope(method: original.method,
                url: 'https://$authority/pathfinder/v2/query', headers: original.headers, body: original.body,
                authorize: original.authorize, includeCredentials: original.includeCredentials, responseType: original.responseType));
              expect(response.statusCode, 200);
            } catch (error) { outgoingFailure = error; rethrow; }
            return const PathfinderResponse(body: {});
          });
          final flags = item['flags'] as Map;
          final repository = PathfinderSearchRepository(loader, features: SearchFeatures(
            includeAuthors: flags['includeAuthors'] as bool,
            includeAlbumPreReleases: flags['includeAlbumPreReleases'] as bool,
            includeEpisodeContentRatingsV2: flags['includeEpisodeContentRatingsV2'] as bool));
          try {
            switch (item['searchKind']) {
              case 'full': await repository.results(item['query'] as String);
              case 'category': case 'episodes': await repository.results(item['query'] as String,
                category: SearchCategory.parse(item['category'] as String), offset: item['offset'] as int, limit: item['limit'] as int);
              case 'remove': await repository.removeRecent((item['uris'] as List).cast<String>());
              case 'save': await repository.saveRecent((item['uris'] as List).cast<String>());
            }
          } on SearchQueryError { /* Empty peer response; inspect outgoing bytes only. */ }
          final failure = outgoingFailure;
          if (failure != null) throw failure;
          expect(requests, 1, reason: '${item['name']}: the real repository sends exactly once');
        } else if (item['operation'] == 'home') {
          final variables = item['originalProviderVariables'] as Map;
          final builder = SpotifyRequestBuilder(locale: item['locale'] as String,
            accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders);
          final transport = sender;
          final loader = PathfinderLoader(builder, send: (request) async {
            final original = request.envelope;
            final response = await transport.send(RequestEnvelope(method: original.method,
              url: 'https://$authority/pathfinder/v2/query', headers: original.headers,
              body: original.body, authorize: original.authorize,
              includeCredentials: original.includeCredentials, responseType: original.responseType));
            expect(response.statusCode, 200);
            return const PathfinderResponse(body: {});
          });
          final repository = PathfinderHomeRepository(loader, context: HomeRequestContext(
            timeZone: variables['timeZone'] as String, spT: variables['sp_t'] as String,
            features: HomeFeatures(includeHomeChapterVideoCards: variables['includeHomeChapterVideoCards'] as bool,
              includeEpisodeContentRatingsV2: variables['includeEpisodeContentRatingsV2'] as bool,
              sectionItemsLimit: variables['sectionItemsLimit'] as int)));
          // The independent peer returns an empty response. Home response
          // projection is outside this check; inspect only its outgoing bytes.
          try { await repository.load(facet: variables['facet'] as String); }
          on HomeQueryError { /* Request already captured by the peer. */ }
        } else if (item['artistKind'] != null) {
          final builder = SpotifyRequestBuilder(locale: item['locale'] as String,
            accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders);
          final transport = sender;
          Object? outgoingFailure;
          var artistRequests = 0;
          final loader = PathfinderLoader(builder, send: (request) async {
            final original = request.envelope;
            final payload = jsonDecode(utf8.decode(original.body)) as Map;
            final operation = payload['operationName'];
            if (item['artistKind'] == 'section' && operation != item['operation']) {
              return const PathfinderResponse(body: {'data': {'artistUnion': {
                '__typename': 'Artist', 'profile': {'name': 'Synthetic artist'},
                'discography': {'all': {'totalCount': 200}, 'albums': {'totalCount': 200},
                  'singles': {'totalCount': 200}, 'compilations': {'totalCount': 200}},
              }}});
            }
            if (item['artistKind'] == 'section' && (item['offset'] as int) > 0 && payload['variables']['offset'] == 0) {
              return PathfinderResponse(body: {'data': {'artistUnion': {
                '__typename': 'Artist', 'profile': {'name': 'Synthetic artist'},
                'discography': {'albums': {'totalCount': 200, 'items': List.generate(50,
                  (_) => {'releases': {'items': [{'uri': 'spotify:album:0000000000000000000001', 'name': 'Synthetic album'}]}})}},
              }}});
            }
            if (item['artistKind'] == 'tracks' && operation == 'queryArtistOverview') {
              // The independent overview cases own that first request. A
              // synthetic successful service response reaches the public
              // repository's second, original top-track request here.
              return const PathfinderResponse(body: {'data': {'artistUnion': {
                '__typename': 'Artist', 'profile': {'name': 'Synthetic artist'},
              }}});
            }
            if (item['artistKind'] == 'tracks' && (item['offset'] as int) > 0 &&
                (jsonDecode(utf8.decode(original.body)) as Map)['variables']['offset'] == 0) {
              return PathfinderResponse(body: {'data': {'artistUnion': {
                '__typename': 'Artist', 'profile': {'name': 'Synthetic artist'},
                'discography': {'topTracks': {'items': List.generate(200,
                  (_) => {'track': {'uri': 'spotify:track:0000000000000000000001'}}),
                  'pagingInfo': {'nextOffset': item['offset']}}},
              }}});
            }
            try {
              artistRequests++;
              final response = await transport.send(RequestEnvelope(method: original.method,
                url: 'https://$authority/pathfinder/v2/query', headers: original.headers, body: original.body,
                authorize: original.authorize, includeCredentials: original.includeCredentials,
                responseType: original.responseType));
              expect(response.statusCode, 200);
            } catch (error) { outgoingFailure = error; rethrow; }
            return const PathfinderResponse(body: {});
          });
          final repository = NativeArtistEntityRepository(loader, describeTracks: (_, {cancellationToken}) async => {},
            preReleaseV2: item['preReleaseV2'] as bool? ?? false,
            locale: item['artistLocale'] as String? ?? '');
          try {
            final page = await repository.open((item['routeUri'] ?? item['uri']) as String);
            if (item['artistKind'] == 'tracks' && (item['offset'] as int) > 0) {
              await repository.tracks(page.details, offset: 200);
            }
            if (item['artistKind'] == 'section' && (item['offset'] as int) > 0) {
              await repository.tracks(page.details, offset: item['offset'] as int);
            }
          }
          on EntityQueryError { /* Empty peer response; only outgoing scope. */ }
          final failure = outgoingFailure;
          if (failure != null) throw failure;
          expect(artistRequests, 1, reason: '${item['name']}: exactly one original artist request must reach transport');
        } else if (item['entityKind'] != null) {
          final builder = SpotifyRequestBuilder(locale: item['locale'] as String,
            accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders);
          final transport = sender;
          Object? outgoingFailure;
          final loader = PathfinderLoader(builder, send: (request) async {
            final original = request.envelope;
            try {
              final response = await transport.send(RequestEnvelope(method: original.method,
                url: 'https://$authority/pathfinder/v2/query', headers: original.headers, body: original.body,
                authorize: original.authorize, includeCredentials: original.includeCredentials,
                responseType: original.responseType));
              expect(response.statusCode, 200);
            } catch (error) { outgoingFailure = error; rethrow; }
            return const PathfinderResponse(body: {});
          });
          final repository = DesktopEntityRepository(loader, dispatcher: EsperantoDispatcher(),
            albumLocale: item['albumLocale'] as String);
          try {
            if (item['entityKind'] == 'open') {
              await repository.open(item['uri'] as String);
            } else {
              await repository.tracks(EntityDetails.fromJson({'uri': item['uri'], 'type': 'album',
                'discs': item['discs']}), offset: item['offset'] as int, limit: item['limit'] as int);
            }
          } on EntityQueryError { /* Empty peer response; only outgoing scope. */ }
          final failure = outgoingFailure;
          if (failure != null) throw failure;
        } else {
          final response = await sender.send(RequestEnvelope(method: application['method'] as String,
            url: 'https://$authority/pathfinder/v2/query',
            headers: (application['headers'] as Map).cast<String, String>(),
            body: base64Decode(application['bodyBase64'] as String),
            authorize: application['authorize'] as bool,
            includeCredentials: application['includeCredentials'] as bool,
            responseType: application['responseType'] as String));
          expect(response.statusCode, 200);
        }
        expect(await nextCapture, isTrue);
        final actual = (jsonDecode(output.current) as Map)['capture'] as Map;
        final priority = actual['headersPriority'] as Map?;
        final priorityProfile = priorityEvidence['profiles']['renderer-pathfinder'] as Map;
        expect({'hasPriority': priority != null, 'weight': priority?['weight'], 'exclusive': priority?['exclusive']},
          {for (final name in ['hasPriority', 'weight', 'exclusive']) name: priorityProfile[name]},
          reason: 'Original renderer H2 HEADERS priority section');
        final pairs = actual['headers'] as List;
        final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
        // Original producer captures own values/body; actual original H2
        // NetLog sends independently own this context's decoded field order.
        expect(fields.length, pairs.length);
        expect(actual['alpn'], 'h2');
        expect(fields, {...(expected['headers'] as Map).cast<String, String>(), ':authority': authority},
          reason: item['name'] as String);
        final expectedFields = {...(expected['headers'] as Map).cast<String, String>(), ':authority': authority};
        expect(pairs, [for (final name in originalH2['headerSequence'] as List)
          [name, expectedFields[name]]], reason: 'Original renderer H2 field order: ${item['name']}');
        expect(actual['bodyBase64'], expected['bodyBase64'], reason: item['name'] as String);
        // Closing a completed request adapter must retain its session's H2
        // connection, as independently observed in original streams1 and3.
        connectionId ??= actual['connectionId'] as int;
        expect(actual['connectionId'], connectionId,
          reason: 'Original renderer session4071 reuses one connection for repeated Pathfinder POSTs');
        expect(actual['streamId'], 1 + 2 * requestIndex++);
        sender.close(); sender = null;
      }
    } finally {
      sender?.close();
      pool?.close();
      peer.stdin.writeln('stop');
      await peer.stdin.close();
      await output.cancel();
      await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () { peer.kill(); return -1; });
      await stderr.cancel();
      expect(errors, isEmpty, reason: 'Independent outgoing H2 peer diagnostics');
    }
  });
}
