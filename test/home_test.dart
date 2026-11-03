import 'package:cancellation_token/cancellation_token.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/home/home.dart';
import 'package:spotify_flutter/protocol/pathfinder.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

class _PendingHome {
  _PendingHome(this.facet);
  final String facet;
  final result = Completer<HomePage>();
}

class _PendingRepository implements HomeRepository {
  final requests = <_PendingHome>[];

  @override
  Future<HomePage> load({String facet = '', CancellationToken? cancellationToken}) {
    final request = _PendingHome(facet);
    requests.add(request);
    return request.result.future;
  }
}

void main() {
  group('Original desktop Home conformance', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/home-oracle.json').readAsStringSync())
        as Map<String, dynamic>;
    for (final scenario in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () async {
        final requests = <Map<String, Object?>>[];
        final context = (scenario['context'] ?? fixture['defaultContext']) as Map<String, dynamic>;
        final flags = context['features'] as Map<String, dynamic>;
        final repository = PathfinderHomeRepository(PathfinderLoader(
          SpotifyRequestBuilder(locale: 'en', market: 'from_token', globalHeaders: {
            'App-Platform': 'fixture-platform', 'Spotify-App-Version': '1.3.6.1921',
          }),
          send: (request) async {
            requests.add(request.envelope.toJson());
            return PathfinderResponse(body: scenario['body']);
          },
        ), context: HomeRequestContext(
          timeZone: context['timeZone'] as String,
          spT: context['spT'] as String,
          collectionUri: context['collectionUri'] as String,
          features: HomeFeatures(
            includeHomeChapterVideoCards: flags['includeHomeChapterVideoCards'] as bool,
            includeEpisodeContentRatingsV2: flags['includeEpisodeContentRatingsV2'] as bool,
            sectionItemsLimit: flags['sectionItemsLimit'] as int?,
            grid: flags['grid'] as bool, watchFeed: flags['watchFeed'] as bool,
            podcastVideos: flags['podcastVideos'] as bool, yourDJ: flags['yourDJ'] as bool,
          ),
        ));
        final actual = <String, Object?>{'requests': requests};
        try {
          final page = await repository.load(facet: scenario['facet'] as String? ?? '');
          actual.addAll({'status': 'ready', 'page': page.toJson()});
        } on HomeQueryError catch (error) {
          actual.addAll({'status': 'error', 'errors': error.errors});
        }
        final expected = {...scenario['expected'] as Map};
        final expectedPage = expected['page'];
        if (expectedPage is Map) {
          // The independent original fixture retains ads. The app deliberately
          // suppresses these owners instead of rendering empty reserved space.
          expected['page'] = {...expectedPage, 'sections': [for (final section in expectedPage['sections'] as List)
            if (!const {'HomePromotionSectionData', 'HomeNativeAdsSectionData'}.contains(section['sourceType'])) section]};
        }
        expect(actual, expected);
      });
    }
  });

  test('Home retains previous content while refreshing and rejects superseded or disposed results', () async {
    final repository = _PendingRepository();
    final controller = HomeController(repository);
    final initial = controller.initialize();
    await controller.initialize();
    expect(repository.requests.map((request) => request.facet), ['']);
    final music = controller.setFacet('music');
    repository.requests.last.result.complete(HomePage(greeting: 'Current'));
    await music;
    repository.requests.first.result.complete(HomePage(greeting: 'Stale'));
    await initial;
    expect(controller.state.facet, 'music');
    expect(controller.state.page?.greeting, 'Current');
    final refresh = controller.refresh();
    expect(controller.state.phase, HomePhase.loading);
    expect(controller.state.page?.greeting, 'Current');
    repository.requests.last.result.completeError(const HomeQueryError(null));
    await refresh;
    expect(controller.state.phase, HomePhase.failed);
    expect(controller.state.page?.greeting, 'Current');
    final disposed = controller.refresh();
    controller.dispose();
    repository.requests.last.result.completeError(StateError('Late response'));
    await disposed;
  });

  testWidgets('Music uses the server chip ID and renders the supplied personalized playlist shelves', (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final facets = <String>[];
    final names = ['Discover Weekly', for (var index = 1; index <= 6; index++) 'Daily Mix $index', 'Release Radar'];
    final repository = PathfinderHomeRepository(PathfinderLoader(
      SpotifyRequestBuilder(locale: 'en'), send: (request) async {
        final facet = (jsonDecode(utf8.decode(request.envelope.body)) as Map)['variables']['facet'] as String;
        facets.add(facet);
        if (facet.isNotEmpty && facet != 'provided-music-chip') {
          return PathfinderResponse(body: {'data': {'home': {'__typename': 'GenericError'}}});
        }
        return PathfinderResponse(body: {'data': {'home': {
          '__typename': 'HomeResponsePayload',
          'homeChips': [{'id': 'provided-music-chip', 'label': {'transformedLabel': 'Music'},
            'subChips': [{'id': 'provided-following-chip', 'label': {'transformedLabel': 'Following'}}]}],
          'sectionContainer': {'sections': {'totalCount': 1, 'items': [{
            'uri': 'spotify:section:provided', 'data': {'__typename': 'HomeGenericSectionData',
              'title': {'transformedLabel': facet.isEmpty ? 'All supplied content' : 'Made For Listener',
                'translatedBaseText': facet.isEmpty ? 'All supplied content' : 'Made For {0}'},
              'headerEntity': {'__typename': 'UnknownType'}},
            'sectionItems': {'items': [if (facet.isNotEmpty) for (final (index, name) in names.indexed) {
              'uri': 'spotify:playlist:provided$index', 'content': {'__typename': 'PlaylistResponseWrapper',
                'data': {'__typename': 'Playlist', 'uri': 'spotify:playlist:provided$index', 'name': name,
                  'description': 'Description of $name', 'images': {'items': []},
                  'ownerV2': {'data': {'__typename': 'User', 'uri': 'spotify:user:spotify', 'name': 'Spotify'}},
                  'content': {'__typename': 'PlaylistItemsPage', 'totalCount': 30}}},
            }]},
          }]}}
        }}});
      }), context: const HomeRequestContext(timeZone: 'UTC'));
    final controller = HomeController(repository);
    addTearDown(controller.dispose);
    final selected = <HomeItem>[];
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: HomeView(
      controller: controller, showFilters: true, onSelect: selected.add,
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Music'));
    await tester.pumpAndSettle();
    expect(facets, ['', 'provided-music-chip']);
    expect(find.text('Made For '), findsOneWidget);
    expect(find.text('Listener'), findsOneWidget);
    expect(controller.state.page!.sections.single.items.map((item) => item.name), names);
    expect(find.text('Description of Discover Weekly'), findsOneWidget);
    expect(find.text('Description of Daily Mix 1'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Following'), findsOneWidget);
    await tester.tap(find.text('Description of Daily Mix 1'));
    expect(selected.single.name, 'Daily Mix 1');
    await tester.scrollUntilVisible(find.text('Description of Release Radar'), 400,
      scrollable: find.descendant(of: find.byKey(const ValueKey('home-section:spotify:section:provided')),
        matching: find.byType(Scrollable)).first);
    await tester.tap(find.text('Description of Release Radar'));
    expect(selected.last.name, 'Release Radar');
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await tester.pumpAndSettle();
    expect(facets.last, '');
    expect(controller.state.phase, HomePhase.ready);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home emits supplied item and section selections and adapts shelves to narrow space', (tester) async {
    tester.view.physicalSize = const Size(1360, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PendingRepository();
    final controller = HomeController(repository);
    addTearDown(controller.dispose);
    final selected = <HomeItem>[];
    final opened = <HomeSection>[];
    final album = HomeItem(type: 'album', uri: 'spotify:album:provided', name: 'Provided album',
      images: [{'url': 'https://fixture.invalid/never-fetched', 'width': 128, 'height': 128}],
      contributors: ['Provided artist']);
    final personalized = HomeItem(type: 'playlist', uri: 'spotify:playlist:provided',
      name: 'Provided branded playlist', description: 'Provided personalized description',
      contributors: ['Spotify'], source: {'content': {'data': {'ownerV2': {
        'data': {'__typename': 'User', 'uri': 'spotify:user:spotify', 'name': 'Spotify'},
      }}}});
    final shelf = HomeSection(uri: 'spotify:section:provided', kind: HomeSectionKind.carousel,
      sourceType: 'HomeGenericSectionData', title: 'Provided shelf',
      seeAllUri: 'spotify:section:provided', items: [album, personalized]);
    final page = HomePage(greeting: 'Provided greeting', sections: [
      HomeSection(uri: 'spotify:section:shortcuts', kind: HomeSectionKind.shortcuts,
        sourceType: 'HomeShortsSectionData', items: [
          for (var index = 0; index < 4; index++)
            HomeItem(type: 'playlist', uri: 'spotify:playlist:provided$index', name: 'Provided shortcut $index'),
        ]),
      shelf,
      HomeSection(uri: 'spotify:section:feed', kind: HomeSectionKind.feed,
        sourceType: 'HomeFeedBaselineSectionData', items: [HomeItem(
          type: 'episode', uri: 'spotify:episode:provided', name: 'Provided episode',
          contributors: ['Provided podcast'], reason: 'Provided explanation',
          description: 'A supplied description with enough words to wrap at a narrow width.',
          durationMs: 123456, isExplicit: true,
        )]),
      HomeSection(uri: 'spotify:section:unsupported', kind: HomeSectionKind.unsupported,
        sourceType: 'HomeSpotlightSectionData', title: 'Provided unavailable section'),
    ]);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: HomeView(
      controller: controller, onSelect: selected.add, onOpenSection: opened.add,
      artworkBuilder: (_, item) => ColoredBox(key: ValueKey('provided-artwork:${item.uri}'),
        color: const Color(0xff334455)),
    ))));
    repository.requests.single.result.complete(page);
    await tester.pumpAndSettle();
    expect(find.text('Provided greeting'), findsOneWidget);
    expect(find.text('Provided branded playlist'), findsNothing);
    expect(find.text('Provided personalized description'), findsOneWidget);
    await tester.tap(find.text('Provided personalized description'));
    expect(selected.single.uri, personalized.uri);
    selected.clear();
    await tester.tap(find.text('Provided album'));
    await tester.tap(find.text('Show all'));
    await tester.tap(find.text('Provided shortcut 2'));
    expect(selected.map((item) => item.uri), [album.uri, 'spotify:playlist:provided2']);
    expect(opened.single, same(shelf));
    expect(find.byKey(ValueKey('provided-artwork:${album.uri}')), findsOneWidget);
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Provided episode'), 300,
      scrollable: find.descendant(of: find.byKey(const PageStorageKey('home-sections')),
        matching: find.byType(Scrollable)).first);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Content is currently unavailable.'), 300,
      scrollable: find.descendant(of: find.byKey(const PageStorageKey('home-sections')),
        matching: find.byType(Scrollable)).first);
    expect(find.text('Content is currently unavailable.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home loading failure retries and an empty provided page remains empty', (tester) async {
    final repository = _PendingRepository();
    final controller = HomeController(repository);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: HomeView(
      controller: controller, onSelect: (_) => fail('Empty Home cannot select an item'),
    ))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.requests.single.result.completeError(const HomeQueryError(null));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t load Home'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(repository.requests, hasLength(2));
    repository.requests.last.result.complete(HomePage());
    await tester.pumpAndSettle();
    expect(find.text('There’s nothing to show right now.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
