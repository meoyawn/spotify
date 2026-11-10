import 'package:cancellation_token/cancellation_token.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/app/app.dart';
import 'package:spotify_flutter/app/navigation.dart';
import 'package:spotify_flutter/app/playback_bar.dart';
import 'package:spotify_flutter/app/shell_icons.dart';
import 'package:spotify_flutter/entities/entities.dart';
import 'package:spotify_flutter/home/home.dart';
import 'package:spotify_flutter/library/library.dart';
import 'package:spotify_flutter/search/models.dart';
import 'package:spotify_flutter/search/repository.dart';

class _ProvidedSearch implements SearchRepository {
  _ProvidedSearch({this.recentItems = const []});
  final List<SearchItem> recentItems;
  final queries = <String>[];

  @override
  Future<SearchPage> recent({CancellationToken? cancellationToken}) async => SearchPage(query: '', items: recentItems);

  @override
  Future<SearchPage> suggestions(String query, {CancellationToken? cancellationToken}) async {
    queries.add(query);
    return SearchPage(query: query, items: [SearchItem(
      type: 'track', uri: 'spotify:track:provided', name: 'Provided result',
      images: [], contributors: ['Provided artist'], durationMs: 90000,
    )]);
  }
}

class _ProvidedHome implements HomeRepository {
  _ProvidedHome(this.name);
  final String name;
  var calls = 0;
  final facets = <String>[];

  @override
  Future<HomePage> load({String facet = '', CancellationToken? cancellationToken}) async {
    calls++;
    facets.add(facet);
    return HomePage(greeting: 'Supplied Home', sections: [HomeSection(
      uri: 'spotify:section:provided', kind: HomeSectionKind.carousel,
      sourceType: 'HomeGenericSectionData', title: 'Supplied shelf', items: [HomeItem(
        type: 'album', uri: 'spotify:album:provided', name: name,
        contributors: ['Supplied artist'],
      )],
    )]);
  }
}

class _ProvidedLibrary implements LibraryRepository {
  _ProvidedLibrary(this.name);
  final String name;
  final queries = <LibraryQuery>[];

  @override
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken}) async {
    queries.add(query);
    return LibraryPage(items: [LibraryItem.fromJson({
      'uri': 'spotify:album:library${query.offset == 0 ? '' : '-more'}',
      'name': '${query.offset == 0 ? '' : 'More '}${query.textFilter.isEmpty ? name : '$name ${query.textFilter}'}',
      'type': 'album', 'artists': [{'name': 'Library artist'}],
    })], totalLength: 2, unfilteredTotalLength: 2, hasUnfilteredItems: true);
  }
}

class _DeferredLibrary implements LibraryRepository {
  final pending = <Completer<LibraryPage>>[];

  @override
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken}) {
    final request = Completer<LibraryPage>();
    pending.add(request);
    return request.future;
  }
}

EntityPage _entityPage(String uri, String name) => EntityPage(
  details: EntityDetails.fromJson({'uri': uri, 'type': uri.contains(':album:') ? 'album' : 'playlist',
    'name': name, 'nrTracks': 1, 'isPlayable': true}),
  tracks: EntityTrackPage(offset: 0, limit: 50, totalLength: 1, rows: [EntityRow.fromJson({
    'type': 'track', 'uri': 'spotify:track:provided', 'linkedUri': 'spotify:track:playable',
    'uid': 'supplied-row', 'name': 'Track from $name', 'isPlayable': true,
    'duration': {'milliseconds': 90000},
  })]),
);

class _ProvidedEntities implements EntityRepository {
  _ProvidedEntities(this.name);
  final String name;
  final opened = <String>[];

  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    opened.add(uri);
    return _entityPage(uri, name);
  }

  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) async =>
    EntityTrackPage(offset: offset, limit: limit ?? 50, totalLength: 1);
}

class _DeferredEntities implements EntityRepository {
  final pending = <String, Completer<EntityPage>>{};

  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) => (pending[uri] = Completer<EntityPage>()).future;

  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) async =>
    EntityTrackPage(offset: offset, limit: limit ?? 50, totalLength: 0);
}

DesktopRouter _router(WidgetTester tester) =>
    tester.widget<MaterialApp>(find.byType(MaterialApp)).routerDelegate! as DesktopRouter;

void main() {
  setUpAll(() async {
    for (final entry in const {
      'SpotifyMixUI': ['SpotifyMixUI-Regular.ttf', 'SpotifyMixUI-Bold.ttf'],
      'SpotifyMixUITitle': ['SpotifyMixUITitle-Bold.ttf', 'SpotifyMixUITitle-Extrabold.ttf'],
      'SpotifyShellIcons': ['SpotifyShellIcons.ttf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final asset in entry.value) {
        loader.addFont(rootBundle.load('assets/app-shell/fonts/$asset'));
      }
      await loader.load();
    }
  });

  test('platform link routes match independently executed original normalization', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-open-links.json').readAsStringSync())
      as Map<String, dynamic>;
    for (final entry in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final route = await const DesktopRouteParser().parseRouteInformation(
        RouteInformation(uri: Uri.parse((entry['input'] as String).trim())));
      final path = entry['originalPath'] as String;
      if (path.startsWith('/user/')) {
        expect(route.entityUri, entry['originalUri'], reason: entry['input'] as String);
      } else {
        expect(route.location, path, reason: entry['input'] as String);
      }
    }
  });

  testWidgets('pasted Spotify link opens content before stale suggestions without searching or playing', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final search = _ProvidedSearch(recentItems: [SearchItem(type: 'track',
      uri: 'spotify:track:provided', name: 'Recent result', images: [], contributors: [])]);
    final entities = _ProvidedEntities('Linked album');
    final plays = <String>[];
    await tester.pumpWidget(SpotifyDesktopApp(
      searchRepository: search, entityRepository: entities,
      playbackBuilder: (_, _, _) => const SizedBox.shrink(),
      onSelect: (item) => plays.add(item.uri), onEntitySelect: (row) => plays.add(row.uri)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.enterText(find.byType(TextField),
      'https://open.spotify.com/intl-de/album/4uLU6hMCjMI75M1A2tKUQC?si=sharing');
    await tester.pump(const Duration(milliseconds: 300));
    expect(search.queries, isEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/album/4uLU6hMCjMI75M1A2tKUQC');
    expect(entities.opened, ['spotify:album:4uLU6hMCjMI75M1A2tKUQC']);
    expect(search.queries, isEmpty);
    expect(plays, isEmpty);
    await tester.tap(find.byTooltip('Go back'));
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/');
    expect(tester.takeException(), isNull);
  }, semanticsEnabled: false);

  for (final warmBeforeInitial in [false, true]) {
    testWidgets('macOS ${warmBeforeInitial ? 'warm link supersedes delayed startup' : 'startup and warm links navigate once'}', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const links = MethodChannel('spotify_flutter/desktop_links');
      const codec = StandardMethodCodec();
      final pending = Completer<String?>();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(links, (call) async =>
        call.method == 'takePendingUrl' ? pending.future : null);
      addTearDown(() => messenger.setMockMethodCallHandler(links, null));
      final entities = _ProvidedEntities('Incoming content');
      await tester.pumpWidget(SpotifyDesktopApp(entityRepository: entities,
        playbackBuilder: (_, _, _) => const SizedBox.shrink()));
      await tester.pumpAndSettle();
      Future<void> deliver(String input) async {
        tester.binding.channelBuffers.push(links.name, codec.encodeMethodCall(MethodCall('openUrl', input)),
          (_) {});
        await tester.pumpAndSettle();
      }
      const cold = 'spotify:album:4uLU6hMCjMI75M1A2tKUQC';
      const warm = 'http://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=sharing';
      if (warmBeforeInitial) {
        await deliver(warm);
      } else {
        await deliver('https://unrelated.invalid/track/4uLU6hMCjMI75M1A2tKUQC');
      }
      pending.complete(cold);
      await tester.pumpAndSettle();
      expect(_router(tester).route.entityUri, warmBeforeInitial
        ? 'spotify:track:4uLU6hMCjMI75M1A2tKUQC' : cold);
      expect(entities.opened, [warmBeforeInitial ? 'spotify:track:4uLU6hMCjMI75M1A2tKUQC' : cold]);
      if (!warmBeforeInitial) await deliver(warm);
      final opened = List.of(entities.opened);
      await deliver(warm);
      await deliver('https://open.spotify.com.evil.invalid/album/4uLU6hMCjMI75M1A2tKUQC');
      expect(_router(tester).route.entityUri, 'spotify:track:4uLU6hMCjMI75M1A2tKUQC');
      expect(entities.opened, opened);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }, semanticsEnabled: false, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('unconnected root keeps recovered shell dimensions and cannot imply authentication or playback', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SpotifyDesktopApp());
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.getSize(find.byType(TextField)).height, 48);
    expect(tester.getSize(find.byType(DesktopPlaybackBar)).height, 88);
    expect(find.text('Sign-in is currently unavailable.'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, SpotifyShellIcons.play)).onPressed, isNull);
    await tester.tap(find.text('Log in'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Sign-in is currently unavailable.'), findsNWidgets(2));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Your Library'));
    await tester.pumpAndSettle();
    expect(find.text('Your Library'), findsNothing);
    await tester.tap(find.byTooltip('Expand Your Library'));
    await tester.pumpAndSettle();
    expect(find.text('Your Library'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand Your Library'));
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/collection');
    for (final size in [const Size(720, 600), const Size(420, 640), const Size(320, 480)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('encoded search routes share one input and preserve supplied results across selection and history', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ProvidedSearch();
    final selected = <String>[];
    await tester.pumpWidget(SpotifyDesktopApp(
      initialLocation: '/search/a%20b%2F%E9%9B%AA',
      searchRepository: repository,
      onSelect: (item) => selected.add(item.uri),
    ));
    await tester.pumpAndSettle();
    expect(repository.queries, ['a b/雪']);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'a b/雪');
    expect(find.text('Provided result'), findsOneWidget);
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(selected, ['spotify:track:provided']);
    expect(_router(tester).route.location, '/track/provided');
    expect(find.text('Provided result'), findsOneWidget);
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, SpotifyShellIcons.play)).onPressed, isNull);
    await tester.tap(find.byTooltip('Go back'));
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/search/a%20b%2F%E9%9B%AA');
    expect(find.text('Search results'), findsOneWidget);
    expect(find.text('Provided result'), findsOneWidget);
    expect(repository.queries, ['a b/雪']);
    await tester.tap(find.byTooltip('Go forward'));
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/track/provided');
    expect(selected, ['spotify:track:provided']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported initial route stays inside shell and home navigation recovers', (tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SpotifyDesktopApp(initialLocation: '/not-implemented'));
    await tester.pumpAndSettle();
    expect(find.text('This page is unavailable'), findsOneWidget);
    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/');
    expect(find.text('Home'), findsOneWidget);
    expect(find.byType(DesktopPlaybackBar), findsOneWidget);
  });

  testWidgets('Home Music deep links and history retain the original facet ID', (tester) async {
    final repository = _ProvidedHome('Music content');
    await tester.pumpWidget(SpotifyDesktopApp(homeRepository: repository,
      initialLocation: '/home?facet=music-chip'));
    await tester.pumpAndSettle();
    expect(repository.facets, ['music-chip']);
    expect(_router(tester).route.location, '/home?facet=music-chip');
    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    expect(repository.facets.last, '');
    await tester.tap(find.byTooltip('Go back'));
    await tester.pumpAndSettle();
    expect(repository.facets.last, 'music-chip');
    _router(tester).go(DesktopRoute.fromUri(Uri.parse('/home/music')));
    await tester.pumpAndSettle();
    expect(find.text('This page is unavailable'), findsNothing);
    expect(repository.facets.last, 'music-chip');
    expect(tester.takeException(), isNull);
  });

  testWidgets('supplied Home survives navigation and replaces the owned backend without stale shelves', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = _ProvidedHome('First supplied album');
    final selected = <String>[];
    await tester.pumpWidget(SpotifyDesktopApp(homeRepository: first,
      onHomeSelect: (item) => selected.add(item.uri)));
    await tester.pumpAndSettle();
    expect(find.text('First supplied album'), findsOneWidget);
    expect(first.calls, 1);
    await tester.tap(find.text('First supplied album'));
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/album/provided');
    expect(selected, ['spotify:album:provided']);
    expect(find.text('Supplied artist'), findsOneWidget);
    await tester.tap(find.byTooltip('Go back'));
    await tester.pumpAndSettle();
    expect(find.text('Supplied shelf'), findsOneWidget);
    expect(first.calls, 1);
    final replacement = _ProvidedHome('Replacement album');
    await tester.pumpWidget(SpotifyDesktopApp(homeRepository: replacement));
    await tester.pumpAndSettle();
    expect(find.text('First supplied album'), findsNothing);
    expect(find.text('Replacement album'), findsOneWidget);
    expect(replacement.calls, 1);
    expect(first.calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar and expanded Library share queries, selection, filters and backend lifetime', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ProvidedLibrary('Supplied library album');
    final selected = <String>[];
    var actions = 0;
    await tester.pumpWidget(SpotifyDesktopApp(libraryRepository: repository,
      onLibrarySelect: (item) => selected.add(item.uri),
      libraryItemActionsBuilder: (context, item) => IconButton(
        tooltip: 'Supplied library action', icon: const Icon(Icons.push_pin),
        onPressed: () => actions++)));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const PageStorageKey('library-sidebar'));
    final main = find.byKey(const PageStorageKey('library-main'));
    expect(repository.queries, hasLength(1));
    await tester.tap(find.descendant(of: sidebar, matching: find.text('Supplied library album')));
    await tester.pumpAndSettle();
    expect(selected, ['spotify:album:library']);
    expect(_router(tester).route.location, '/album/library');
    expect(find.text('Library artist'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand Your Library'));
    await tester.pumpAndSettle();
    expect(main, findsOneWidget);
    expect(repository.queries, hasLength(1));
    await tester.enterText(find.descendant(of: main, matching: find.byType(TextField)), 'jazz');
    await tester.pumpAndSettle();
    expect(repository.queries, hasLength(2));
    expect(repository.queries.last.textFilter, 'jazz');
    expect(tester.widget<TextField>(find.descendant(of: sidebar, matching: find.byType(TextField)))
      .controller!.text, 'jazz');
    expect(find.text('Supplied library album jazz'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, 'Your Library'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Supplied library album jazz'), findsOneWidget);
    await tester.tap(find.byTooltip('Actions for Supplied library album jazz'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Supplied library action').last);
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(selected, ['spotify:album:library']);
    await tester.tap(find.byTooltip('Load more'));
    await tester.pumpAndSettle();
    expect(repository.queries, hasLength(3));
    expect(repository.queries.last.offset, 1);
    expect(find.byTooltip('More Supplied library album jazz'), findsOneWidget);
    for (final size in [const Size(720, 600), const Size(320, 480)]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (size.width == 720) {
        await tester.tap(find.byTooltip('Home'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Your Library'));
        await tester.pumpAndSettle();
        expect(_router(tester).route.location, '/collection');
      }
    }
    final replacement = _ProvidedLibrary('Replacement library album');
    await tester.pumpWidget(SpotifyDesktopApp(libraryRepository: replacement));
    await tester.pumpAndSettle();
    expect(replacement.queries, hasLength(1));
    expect(replacement.queries.single.textFilter, '');
    expect(find.text('Supplied library album jazz'), findsNothing);
    expect(find.text('Replacement library album'), findsOneWidget);
    expect(repository.queries, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact Library shows loading, recoverable failure and empty result', (tester) async {
    tester.view.physicalSize = const Size(720, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _DeferredLibrary();
    await tester.pumpWidget(SpotifyDesktopApp(libraryRepository: repository));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.pending.single.completeError(StateError('supplied failure'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Couldn’t load Your Library. Try again'));
    await tester.pump();
    expect(repository.pending, hasLength(2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.pending.last.complete(LibraryPage());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Your library is empty.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home selection opens entity pages with caller-owned actions and cached navigation history', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _ProvidedEntities('Supplied detail');
    final selections = <EntityRow>[];
    final playback = <EntityPlaybackSelection>[];
    var actions = 0;
    await tester.pumpWidget(SpotifyDesktopApp(homeRepository: _ProvidedHome('Open album'),
      entityRepository: repository, onEntitySelect: selections.add, onEntityPlay: playback.add,
      entityArtworkBuilder: (context, entity) => const Text('Supplied entity artwork'),
      entityRowActionsBuilder: (context, row) => IconButton(tooltip: 'Supplied entity action',
        icon: const Icon(Icons.more_horiz), onPressed: () => actions++)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open album'));
    await tester.pumpAndSettle();
    expect(repository.opened, ['spotify:album:provided']);
    expect(find.text('Supplied detail'), findsOneWidget);
    expect(find.text('Supplied entity artwork'), findsOneWidget);
    await tester.tap(find.byTooltip('Play Track from Supplied detail'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(playback.single.contextUri, 'spotify:album:provided');
    expect(playback.single.trackUri, 'spotify:track:playable');
    expect(playback.single.uid, 'supplied-row');
    expect(playback.single.rowIndex, 0);
    await tester.tap(find.byTooltip('Supplied entity action'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(actions, 1);
    expect(selections, isEmpty);
    await tester.tap(find.text('Track from Supplied detail'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(selections.single.uri, 'spotify:track:provided');
    expect(_router(tester).route.location, '/album/provided');
    _router(tester).go(DesktopRoute.content('spotify:user:owner:playlist:legacy'));
    await tester.pumpAndSettle();
    expect(repository.opened, ['spotify:album:provided', 'spotify:user:owner:playlist:legacy']);
    await tester.tap(find.byTooltip('Go back'));
    await tester.pumpAndSettle();
    expect(_router(tester).route.location, '/album/provided');
    await tester.tap(find.byTooltip('Go forward'));
    await tester.pumpAndSettle();
    expect(repository.opened, hasLength(2));
    _router(tester).go(DesktopRoute.content('spotify:artist:provided', title: 'Selected artist'));
    await tester.pumpAndSettle();
    expect(find.text('Selected artist'), findsOneWidget);
    expect(repository.opened, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('repository replacement retires pending and cached entity pages across history', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final old = _DeferredEntities();
    await tester.pumpWidget(SpotifyDesktopApp(initialLocation: '/album/pending', entityRepository: old));
    await tester.pump();
    _router(tester).go(DesktopRoute.content('spotify:playlist:current'));
    await tester.pump();
    final replacement = _ProvidedEntities('Replacement detail');
    await tester.pumpWidget(SpotifyDesktopApp(entityRepository: replacement));
    await tester.pump();
    expect(replacement.opened, ['spotify:playlist:current']);
    await tester.pumpAndSettle();
    expect(find.text('Replacement detail'), findsOneWidget);
    old.pending['spotify:playlist:current']!.complete(_entityPage('spotify:playlist:current', 'Retired playlist'));
    old.pending['spotify:album:pending']!.complete(_entityPage('spotify:album:pending', 'Retired album'));
    await tester.pumpAndSettle();
    expect(find.text('Retired playlist'), findsNothing);
    await tester.tap(find.byTooltip('Go back'));
    await tester.pumpAndSettle();
    expect(replacement.opened, ['spotify:playlist:current', 'spotify:album:pending']);
    expect(find.text('Replacement detail'), findsOneWidget);
    expect(find.text('Retired album'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
