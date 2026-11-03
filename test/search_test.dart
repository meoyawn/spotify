import 'package:cancellation_token/cancellation_token.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/pathfinder.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';
import 'package:spotify_flutter/search/controller.dart';
import 'package:spotify_flutter/search/models.dart';
import 'package:spotify_flutter/search/repository.dart';
import 'package:spotify_flutter/search/view.dart';

class _PendingSearch {
  _PendingSearch(this.query);
  final String? query;
  final result = Completer<SearchPage>();
}

class _PendingRepository implements SearchRepository {
  final requests = <_PendingSearch>[];

  @override
  Future<SearchPage> recent({CancellationToken? cancellationToken}) => _request(null);

  @override
  Future<SearchPage> suggestions(String query, {CancellationToken? cancellationToken}) => _request(query);

  Future<SearchPage> _request(String? query) {
    final request = _PendingSearch(query);
    requests.add(request);
    return request.result.future;
  }
}

SearchItem _item(String name, {String type = 'track', int? durationMs}) => SearchItem(
  type: type, uri: 'spotify:$type:$name', name: name,
  images: [{'url': 'https://fixture.invalid/never-fetched', 'width': 48, 'height': 48}],
  contributors: ['Fixture contributor'], durationMs: durationMs,
  isExplicit: type == 'track',
);

void main() {
  group('Original desktop search conformance', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/search-oracle.json').readAsStringSync())
        as Map<String, dynamic>;
    for (final scenario in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () async {
        final requests = <Map<String, Object?>>[];
        final flags = (scenario['flags'] ?? fixture['flags']) as Map<String, dynamic>;
        final repository = PathfinderSearchRepository(
          PathfinderLoader(
            SpotifyRequestBuilder(locale: 'en', market: 'from_token', globalHeaders: {
              'App-Platform': 'fixture-platform', 'Spotify-App-Version': '1.3.6.1921',
            }),
            send: (request) async {
              requests.add(request.envelope.toJson());
              if (scenario['httpStatus'] case final int status) {
                throw HttpResponseError(message: 'synthetic failure',
                  url: request.envelope.url, method: request.envelope.method, status: status);
              }
              return PathfinderResponse(body: scenario['body']);
            },
          ),
          features: SearchFeatures(
            includeAuthors: flags['includeAuthors'] as bool,
            includeAlbumPreReleases: flags['includeAlbumPreReleases'] as bool,
            includeEpisodeContentRatingsV2: flags['includeEpisodeContentRatingsV2'] as bool,
          ),
        );
        final actual = <String, Object?>{'requests': requests, 'query': '', 'items': []};
        try {
          final page = scenario['kind'] == 'recent'
              ? await repository.recent()
              : await repository.suggestions(scenario['query'] as String);
          actual.addAll(page.toJson());
        } on SearchQueryError catch (error) {
          actual['error'] = error.errors;
        }
        expect(actual, scenario['expected']);
      });
    }

    test('default search bodies match the original UI capture byte for byte', () async {
      final capture = jsonDecode(File('reverse-engineering/fixtures/original-search.json').readAsStringSync())
          as Map<String, dynamic>;
      final capturedRequests = (capture['requests'] as List).cast<Map<String, dynamic>>();
      final bodies = <List<int>>[];
      final repository = PathfinderSearchRepository(PathfinderLoader(
        SpotifyRequestBuilder(),
        send: (request) async {
          bodies.add(request.envelope.body);
          return const PathfinderResponse(body: {'data': {}});
        },
      ));
      await repository.recent();
      await repository.suggestions('ambient');
      expect(bodies, [utf8.encode(capturedRequests.first['body'] as String),
        utf8.encode(capturedRequests.last['body'] as String)]);
    });
  });

  test('leading/trailing search coalesces input and ignores superseded responses and disposal', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/search-oracle.json').readAsStringSync())
        as Map<String, dynamic>;
    final debounce = fixture['debounce'] as Map<String, dynamic>;
    final repository = _PendingRepository();
    final controller = DesktopSearchController(repository);
    for (final query in (debounce['input'] as List).cast<String>()) {
      controller.setQuery(query);
    }
    expect(repository.requests.map((request) => request.query), ['old']);
    await Future<void>.delayed(const Duration(milliseconds: 260));
    expect(repository.requests.map((request) => request.query),
      (debounce['emitted'] as List).map((event) => event['query']));
    repository.requests.last.result.complete(SearchPage(query: 'new', items: [_item('Newest')]));
    await Future<void>.delayed(Duration.zero);
    repository.requests.first.result.complete(SearchPage(query: 'old', items: [_item('Stale')]));
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.responseQuery, 'new');
    expect(controller.state.items.single.name, 'Newest');
    controller.setQuery('');
    expect(repository.requests.last.query, null);
    controller.dispose();
    repository.requests.last.result.completeError(StateError('Disposed request'));
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('search renders supplied results, emits selections, and handles narrow, empty and retry states', (tester) async {
    tester.view.physicalSize = const Size(640, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PendingRepository();
    final controller = DesktopSearchController(repository);
    addTearDown(controller.dispose);
    final selected = <String>[];
    final viewed = <String>[];
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(
      body: SearchView(controller: controller, onSelect: (item) => selected.add(item.uri),
        onViewAllResults: viewed.add),
    )));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.requests.last.result.complete(SearchPage(query: '', items: [_item('Recent artist', type: 'artist')]));
    await tester.pump();
    expect(find.text('Recent searches'), findsOneWidget);
    await tester.tap(find.text('Recent artist'));
    expect(selected, ['spotify:artist:Recent artist']);
    await tester.enterText(find.byType(TextField), 'ambient');
    repository.requests.last.result.complete(SearchPage(query: 'ambient', items: [
      _item('A supplied track with a long name that must fit a narrow window', durationMs: 123456),
    ]));
    await tester.pump();
    expect(find.text('Search results'), findsOneWidget);
    expect(find.text('2:03'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(selected.last, startsWith('spotify:track:'));
    await tester.tap(find.text('View all results for “ambient”'));
    expect(viewed, ['ambient']);
    tester.view.physicalSize = const Size(320, 480);
    await tester.pump();
    expect(tester.takeException(), isNull);
    final retry = controller.refresh();
    repository.requests.last.result.completeError(StateError('Fixture transport failed'));
    await retry;
    await tester.pump();
    expect(find.text('Something went wrong. Try searching again.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    repository.requests.last.result.complete(SearchPage(query: 'ambient', items: []));
    await tester.pump();
    expect(find.text('No results found for “ambient”'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    repository.requests.last.result.complete(SearchPage(query: '', items: []));
    await tester.pump();
    expect(find.text('Your recent searches will appear here.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
