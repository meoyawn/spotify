import 'package:cancellation_token/cancellation_token.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/entities/controller.dart';
import 'package:spotify_flutter/entities/models.dart';
import 'package:spotify_flutter/entities/repository.dart';
import 'package:spotify_flutter/entities/view.dart';
import 'package:spotify_flutter/library/saved_playlists.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';
import 'package:spotify_flutter/protocol/pathfinder.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  group('Original album and playlist entity conformance', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/entity-oracle.json').readAsStringSync()) as Map<String, dynamic>;
    for (final group in ['albumScenarios', 'playlistScenarios']) {
      for (final scenario in (fixture[group] as List).cast<Map<String, dynamic>>()) {
        test(scenario['name'] as String, () async {
          final album = group == 'albumScenarios';
          final requests = <Map<String, Object?>>[];
          final calls = <Map<String, Object?>>[];
          final dispatcher = EsperantoDispatcher();
          dispatcher.register(DesktopEntityRepository.playlistService, EsperantoService(single: {'Get': (payload) {
            calls.add({'service': DesktopEntityRepository.playlistService, 'method': 'Get', 'payloadHex': hex.encode(payload)});
            return hex.decode(scenario['responseHex'] as String);
          }}));
          final flags = (scenario['features'] ?? fixture['playlistFeatures']) as Map<String, dynamic>;
          final repository = DesktopEntityRepository(PathfinderLoader(SpotifyRequestBuilder(
            locale: 'en', market: 'from_token', globalHeaders: {
              'App-Platform': 'fixture-platform', 'Spotify-App-Version': '1.3.6.1921'}),
            send: (request) async {
              requests.add(request.envelope.toJson());
              return PathfinderResponse(body: scenario['body']);
            }), dispatcher: dispatcher, albumLocale: scenario['locale'] as String? ?? '',
            features: EntityFeatures(watchFeed: flags['watchFeed'] as bool,
              authors: flags['authors'] as bool, ageAssurance: flags['ageAssurance'] as bool));
          final actual = <String, Object?>{album ? 'requests' : 'calls': album ? requests : calls};
          try {
            if (scenario['kind'] == 'open') {
              final page = await repository.open(scenario['uri'] as String);
              actual['metadata'] = page.details.toJson();
              actual['tracks'] = page.tracks.toJson();
            } else {
              actual['tracks'] = (await repository.tracks(EntityDetails.fromJson({
                'type': album ? 'album' : 'playlist', 'uri': scenario['uri'],
                if (scenario['discs'] != null) 'discs': scenario['discs'],
              }), offset: scenario['offset'] as int, limit: scenario['limit'] as int)).toJson();
            }
          } on EntityQueryError catch (error) {
            if (error.errors == null) { actual['metadata'] = null; }
            else { actual['error'] = error.errors; }
          }
          final expected = scenario['expected'] as Map;
          expect(actual['metadata'], expected['metadata']);
          expect(actual['tracks'], expected['tracks']);
          expect(actual['error'], expected['error']);
          expect(album ? requests : calls, expected[album ? 'requests' : 'calls']);
        });
      }
    }
  });

  group('Selected entity lifecycle', () {
    test('changing selection rejects stale open and page completions including after dispose', () async {
      final opens = <String, Completer<EntityPage>>{};
      final next = Completer<EntityTrackPage>();
      final repository = _Repository(onOpen: (uri) => (opens[uri] = Completer()).future,
        onTracks: (_, _) => next.future);
      final controller = EntityController(repository, uri: 'spotify:album:first');
      final first = controller.initialize();
      final second = controller.setUri('spotify:album:second');
      opens['spotify:album:second']!.complete(_page('spotify:album:second', rows: [_row('second')], total: 2));
      await second;
      opens['spotify:album:first']!.complete(_page('spotify:album:first', rows: [_row('first')]));
      await first;
      expect(controller.state.uri, 'spotify:album:second');
      expect(controller.state.rows.single.name, 'second');
      final paging = controller.loadMore();
      final third = controller.setUri('spotify:album:third');
      expect(controller.state.rows, isEmpty);
      opens['spotify:album:third']!.complete(_page('spotify:album:third', rows: [_row('third')]));
      await third;
      next.complete(EntityTrackPage(rows: [_row('stale')], offset: 1, limit: 50, totalLength: 2));
      await paging;
      expect(controller.state.rows.single.name, 'third');
      final refresh = controller.refresh();
      controller.dispose();
      opens['spotify:album:third']!.complete(_page('spotify:album:third', rows: [_row('late')]));
      await refresh;
      expect(controller.state.rows.single.name, 'third');
    });

    test('failed pagination retains rows and retries the display cursor including disc rows', () async {
      final offsets = <int>[];
      var attempts = 0;
      final repository = _Repository(onOpen: (uri) async => _page(uri, rows: [
        EntityRow.fromJson({'type': 'AlbumDisc', 'discNumber': 1}), _row('first')], total: 3),
        onTracks: (_, offset) async {
          offsets.add(offset);
          if (attempts++ == 0) throw StateError('Synthetic page failure');
          return EntityTrackPage(rows: [_row('last')], offset: 0, limit: 1, totalLength: 3);
        });
      final controller = EntityController(repository, uri: 'spotify:album:paging');
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.loadMore();
      expect(controller.state.rows.length, 2);
      expect(controller.state.error, isA<StateError>());
      expect(controller.state.hasMore, isTrue);
      await controller.loadMore();
      expect(offsets, [2, 2]);
      expect(controller.state.rows.last.name, 'last');
      expect(controller.state.error, isNull);
      expect(controller.state.hasMore, isFalse);
    });
  });

  group('Entity detail interactions', () {
    testWidgets('playlist saving waits for acknowledgement, keeps failed state and refreshes the library on success', (tester) async {
      var receipt = Completer<void>(), writes = 0, libraryChanges = 0;
      final page = Completer<EntityTrackPage>();
      final repository = _SavingRepository(onOpen: (uri) async => EntityPage(
        details: EntityDetails.fromJson({'type': 'playlist', 'uri': uri, 'name': 'Save playlist', 'isSaved': false}),
        tracks: EntityTrackPage(rows: [_row('Music')], offset: 0, limit: 1, totalLength: 2)),
        onTracks: (_, _) => page.future,
        onSave: (saved) { expect(saved, isTrue); writes++; return receipt.future; });
      final controller = EntityController(repository, uri: 'spotify:playlist:0000000000000000000001',
        onLibraryChanged: () => libraryChanges++);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: EntityView(controller: controller))));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Save to Your Library'));
      await tester.pump();
      await tester.tap(find.byTooltip('Save to Your Library'));
      expect(writes, 1);
      expect(controller.state.details!.data['isSaved'], isFalse);
      receipt.completeError(StateError('Server rejected the write'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t update Your Library. Try again.'), findsOneWidget);
      expect(libraryChanges, 0);
      expect(controller.state.rows.single.name, 'Music');
      receipt = Completer<void>();
      await tester.tap(find.byTooltip('Save to Your Library'));
      await tester.pump();
      final paging = controller.loadMore();
      receipt.complete();
      await tester.pump();
      page.complete(EntityTrackPage(rows: [_row('Next music')], offset: 1, limit: 1, totalLength: 2));
      await paging;
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove from Your Library'), findsOneWidget);
      expect(libraryChanges, 1);
      expect(writes, 2);
    });

    testWidgets('song menu writes the original canonical URL to the clipboard without playing', (tester) async {
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-song-links.json').readAsStringSync()) as Map;
      final song = (fixture['cases'] as List).first as Map;
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final controller = EntityController(_Repository(onOpen: (uri) async => _page(uri, rows: [EntityRow.fromJson({
        'type': 'track', 'uri': song['uri'], 'name': 'Share this song', 'isPlayable': true,
        'relinkedUri': 'spotify:track:0000000000000000000002',
      })])), uri: 'spotify:album:0000000000000000000001');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: EntityView(controller: controller,
        onPlay: (_) => fail('Copying must not start playback')))));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More options for Share this song'));
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy song link'));
      await tester.pumpAndSettle();
      expect(copied, [song['originalUrl']]);
      expect(find.text('Link copied to clipboard'), findsOneWidget);
    });

    testWidgets('playlist arrows move the selected row and reveal it without playing or paging', (tester) async {
      final rows = [for (var index = 0; index < 35; index++) ...[
        if (index == 2) EntityRow.unsupported(),
        _row('Track $index'),
      ]];
      final selected = <EntityRow>[];
      final played = <EntityPlaybackSelection>[];
      var pages = 0;
      final controller = EntityController(_Repository(onOpen: (uri) async => EntityPage(
        details: EntityDetails.fromJson({'type': 'playlist', 'uri': uri, 'name': 'Keyboard playlist'}),
        tracks: EntityTrackPage(rows: rows, offset: 0, limit: rows.length, totalLength: 50)),
        onTracks: (_, offset) async {
          pages++;
          return EntityTrackPage(offset: offset, limit: 50, totalLength: 50);
        }), uri: 'spotify:playlist:keyboard');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: EntityView(
        controller: controller, onSelect: selected.add, onPlay: played.add))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Track 0'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected.last.name, 'Track 1');
      expect(find.ancestor(of: find.text('Track 1'), matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected == true)), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      expect(selected.last.name, 'Track 3');
      for (var index = 4; index <= 30; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(selected.last.name, 'Track 30');
      await tester.pumpAndSettle();
      final viewport = tester.getRect(find.byType(CustomScrollView));
      final row = tester.getRect(find.text('Track 30'));
      expect(row.top, greaterThanOrEqualTo(viewport.top));
      expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(find.text('Track 0'), findsNothing);
      for (var index = 31; index <= 35; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(selected.last.name, 'Track 34');
      for (var index = 0; index < 36; index++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
      }
      expect(selected.last.name, 'Track 0');
      await tester.pumpAndSettle();
      final firstRow = tester.getRect(find.text('Track 0'));
      expect(firstRow.top, greaterThanOrEqualTo(viewport.top));
      expect(firstRow.bottom, lessThanOrEqualTo(viewport.bottom));

      await tester.scrollUntilVisible(find.byTooltip('Find in playlist'), -200);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Find in playlist'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Track 2');
      await tester.pumpAndSettle();
      final beforeEditing = selected.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(selected.length, beforeEditing);
      await tester.tap(find.byWidgetPredicate((widget) => widget is Text && widget.data == 'Track 2'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected.last.name, 'Track 20');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(selected.last.name, 'Track 2');
      expect(played, isEmpty);
      expect(pages, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('provided album context and playable rows emit separate selections without optimistic playback', (tester) async {
      final page = _fixturePage('albumScenarios', 'album opens with original version header and first fifty');
      final controller = EntityController(_Repository(onOpen: (_) async => page), uri: page.details.uri);
      addTearDown(controller.dispose);
      final played = <EntityPlaybackSelection>[];
      final selected = <EntityRow>[];
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: EntityView(
        controller: controller, onPlay: played.add, onSelect: selected.add,
        artworkBuilder: (_, _) => const ColoredBox(color: Colors.blue),
        rowActionsBuilder: (_, row) => IconButton(tooltip: 'Action ${row.name}',
          onPressed: () => selected.add(row), icon: const Icon(Icons.more_horiz)),
      ))));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Play Synthetic album'));
      await tester.pumpAndSettle();
      expect(played.single.row, isNull);
      await tester.tap(find.text('Synthetic track 1.1'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Synthetic track 1.1'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(played.length, 2);
      expect(played.first.contextUri, page.details.uri);
      expect(played.first.row, isNull);
      expect(played.last.trackUri, page.tracks.rows.first.uri);
      expect(played.last.uid, 'album-uid-1-1');
      expect(played.last.rowIndex, 0);
      await tester.tap(find.text('Synthetic track 1.2'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Synthetic track 1.2'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(played.length, 2);
      expect(selected.last.playbackUri, 'spotify:track:relinked');
      await tester.tap(find.byTooltip('Action Synthetic track 1.1'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(selected.last.uid, 'album-uid-1-1');
      expect(find.byTooltip('Play Synthetic album'), findsOneWidget);
    });

    testWidgets('narrow scaled playlist keeps supplied rows and unsupported content usable without artwork loading', (tester) async {
      final page = _fixturePage('playlistScenarios', 'playlist metadata and track rows use original native Get policy');
      final controller = EntityController(_Repository(onOpen: (_) async => page), uri: page.details.uri);
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.8)), child: child!),
        home: Scaffold(body: EntityView(controller: controller))));
      await tester.pumpAndSettle();
      expect(find.text('Synthetic playlist'), findsOneWidget);
      expect(find.text('Album'), findsNothing);
      await tester.scrollUntilVisible(find.text('This content is unavailable.'), 200);
      expect(find.text('This content is unavailable.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('initial failure offers a real retry and inaccessible replacement shows no playback controls', (tester) async {
      final pending = Completer<EntityPage>();
      var attempts = 0;
      final controller = EntityController(_Repository(onOpen: (uri) async {
        if (attempts++ == 0) return pending.future;
        return _page(uri);
      }), uri: 'spotify:album:empty');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: EntityView(controller: controller))));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      pending.completeError(StateError('Synthetic failure'));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t load this content'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('There’s nothing to show right now.'), findsOneWidget);
      final unavailable = _fixturePage('playlistScenarios', 'forbidden playlist returns the original inaccessible metadata');
      final other = EntityController(_Repository(onOpen: (_) async => unavailable), uri: unavailable.details.uri);
      addTearDown(other.dispose);
      await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: EntityView(controller: other,
        onPlay: (_) => fail('Inaccessible metadata must not enable playback')))));
      await tester.pumpAndSettle();
      expect(find.text('This content is unavailable.'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
    });
  });
}

EntityPage _fixturePage(String group, String name) {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/entity-oracle.json').readAsStringSync()) as Map;
  final expected = ((fixture[group] as List).firstWhere((item) => item['name'] == name) as Map)['expected'] as Map;
  final tracks = expected['tracks'] as Map;
  return EntityPage(details: EntityDetails.fromJson((expected['metadata'] as Map).cast<String, Object?>()),
    tracks: EntityTrackPage(rows: (tracks['items'] as List).map((row) => row == null ? EntityRow.unsupported()
      : EntityRow.fromJson((row as Map).cast<String, Object?>())).toList(),
      offset: tracks['offset'] as int, limit: tracks['limit'] as int, totalLength: tracks['totalLength'] as int));
}

EntityRow _row(String name) => EntityRow.fromJson({'type': 'track', 'name': name, 'uri': 'spotify:track:$name'});
EntityPage _page(String uri, {List<EntityRow> rows = const [], int? total}) => EntityPage(
  details: EntityDetails.fromJson({'type': 'album', 'uri': uri, 'name': 'Synthetic album'}),
  tracks: EntityTrackPage(rows: rows, offset: 0, limit: 50, totalLength: total ?? rows.length));

class _Repository implements EntityRepository {
  _Repository({required this.onOpen, this.onTracks});
  final Future<EntityPage> Function(String) onOpen;
  final Future<EntityTrackPage> Function(EntityDetails, int)? onTracks;
  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) => onOpen(uri);
  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) => onTracks!(details, offset);
}

class _SavingRepository extends _Repository implements SavedPlaylistsRepository {
  _SavingRepository({required super.onOpen, super.onTracks, required this.onSave});
  final Future<void> Function(bool saved) onSave;
  @override Future<bool> containsPlaylist(String uri, {CancellationToken? cancellationToken}) async => false;
  @override Future<void> setPlaylistSaved(String uri, bool saved, {CancellationToken? cancellationToken}) => onSave(saved);
}
