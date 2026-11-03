import 'package:cancellation_token/cancellation_token.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/library/library.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';

class _PendingLoad {
  _PendingLoad(this.query);
  final LibraryQuery query;
  final result = Completer<LibraryPage>();
}

class _PendingRepository implements LibraryRepository {
  final requests = <_PendingLoad>[];
  @override
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken}) {
    final pending = _PendingLoad(query);
    requests.add(pending);
    return pending.result.future;
  }
}

LibraryItem _item(String name, {String type = 'album'}) => LibraryItem.fromJson({
  'type': type, 'name': name, 'uri': 'spotify:$type:$name',
  'images': [{'url': 'https://fixture.invalid/never-fetched', 'width': 300, 'height': 300}],
});

void main() {
  group('Original native desktop Library conformance', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/library-oracle.json').readAsStringSync()) as Map<String, dynamic>;
    for (final scenario in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () async {
        final calls = <Map<String, Object?>>[];
        final dispatcher = EsperantoDispatcher();
        dispatcher.register(EsperantoLibraryRepository.service, EsperantoService(single: {
          'All': (payload) {
            calls.add({'service': EsperantoLibraryRepository.service, 'method': 'All', 'payloadHex': hex.encode(payload)});
            return hex.decode(scenario['responseHex'] as String);
          },
        }));
        final flags = (scenario['features'] ?? fixture['features']) as Map<String, dynamic>;
        final repository = EsperantoLibraryRepository(dispatcher,
          features: LibraryFeatures(courses: flags['courses'] as bool,
            authors: flags['authors'] as bool, venues: flags['venues'] as bool,
            concertCampaigns: flags['concertCampaigns'] as bool,
            recentsSortOrder: flags['recentsSortOrder'] as bool,
            artistRecentlyUpdatedSort: flags['artistRecentlyUpdatedSort'] as bool,
            customFilterOrder: flags['customFilterOrder'] as bool));
        final actual = <String, Object?>{'calls': calls};
        try {
          actual['page'] = (await repository.load(LibraryQuery.fromJson(scenario['query'] as Map<String, dynamic>))).toJson();
        } on LibraryQueryError catch (error) {
          actual['error'] = {'kind': error.kind, 'message': error.message};
        }
        final expected = scenario['expected'] as Map;
        expect(actual['page'], expected['page']);
        expect(actual['error'], expected['error']);
        expect(calls, expected['calls']);
      });
    }
  });

  test('sort direction and per-filter restoration follow the original sidebar hook', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/library-oracle.json').readAsStringSync()) as Map<String, dynamic>;
    final repository = _PendingRepository();
    final controller = LibraryController(repository);
    addTearDown(controller.dispose);
    Future<void> finish(Future<void> action) async {
      final pending = repository.requests.last;
      pending.result.complete(LibraryPage(selectedFilters: [for (final id in pending.query.filters)
        LibraryOption(id: id, name: 'Provided filter $id')]));
      await action;
    }
    await finish(controller.initialize());
    for (final value in fixture['sortTransitions'] as List) {
      final transition = value as Map<String, dynamic>;
      final filter = transition['filter'] as String?;
      if (controller.state.query.filters.firstOrNull != filter) {
        await finish(filter == null ? controller.clearFilters() : controller.toggleFilter(filter));
      }
      final selected = transition['selected'] as String?;
      if (selected != null) await finish(controller.selectSort(selected));
      expect(controller.state.query.sortOrder, transition['sortOrder']);
      expect(controller.state.query.sortDirection?.name, transition['direction']);
    }
  });

  test('paging coalesces duplicate loads and stale pages cannot replace a new filter or disposed state', () async {
    final repository = _PendingRepository();
    final controller = LibraryController(repository, initialQuery: const LibraryQuery(limit: 2));
    final initial = controller.initialize();
    repository.requests.single.result.complete(LibraryPage(items: [_item('First'), _item('Second')], totalLength: 3));
    await initial;
    final more = controller.loadMore();
    await controller.loadMore();
    expect(repository.requests, hasLength(2));
    expect(repository.requests.last.query.offset, 2);
    final changed = controller.setTextFilter('new');
    // Text search deliberately waits for the production 200ms debounce.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    repository.requests.last.result.complete(LibraryPage(items: [_item('Newest')], totalLength: 1));
    await changed;
    repository.requests[1].result.complete(LibraryPage(items: [_item('Stale')], totalLength: 3));
    await more;
    expect(controller.state.items.map((item) => item.name), ['Newest']);
    expect(controller.state.query.textFilter, 'new');
    final late = controller.refresh();
    controller.dispose();
    repository.requests.last.result.completeError(StateError('Disposed response'));
    await late;
  });

  test('invalid server filters, sorts and folders reset only their owning state and retry once', () async {
    for (final kind in ['filter', 'sort', 'folder']) {
      final repository = _PendingRepository();
      final controller = LibraryController(repository, initialQuery: LibraryQuery(
        filters: kind == 'filter' ? ['2'] : [], sortOrder: kind == 'sort' ? '0' : null,
        folderUri: kind == 'folder' ? 'spotify:user:fixture:folder:000000000000001a' : null));
      final loaded = controller.initialize();
      repository.requests.single.result.completeError(LibraryQueryError(kind, 'Synthetic server state error'));
      await Future<void>.delayed(Duration.zero);
      expect(repository.requests, hasLength(2));
      final retried = repository.requests.last.query;
      expect(retried.filters, isEmpty);
      expect(retried.sortOrder, isNull);
      expect(retried.folderUri, isNull);
      repository.requests.last.result.completeError(LibraryQueryError(kind, 'Repeated error'));
      await loaded;
      expect(controller.state.phase, LibraryPhase.failed);
      expect(repository.requests, hasLength(2));
      controller.dispose();
    }
  });

  testWidgets('Library emits supplied selections and actions, filters, navigates folders and adapts view modes', (tester) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = _PendingRepository();
    final controller = LibraryController(repository);
    addTearDown(controller.dispose);
    final selected = <String>[];
    final folders = <String>[];
    final actions = <String>[];
    final album = LibraryItem.fromJson({..._item('Provided album').data, 'albumType': 'ep'});
    final folder = _item('Provided folder', type: 'folder');
    LibraryPage page({bool filtered = false}) => LibraryPage(items: [album, folder, LibraryItem.unsupported()],
      totalLength: 3, availableFilters: [const LibraryOption(id: '2', name: 'Playlists')],
      selectedFilters: [if (filtered) const LibraryOption(id: '2', name: 'Playlists')],
      availableSortOrders: [const LibraryOption(id: '6', name: 'Recents'), const LibraryOption(id: '0', name: 'Alphabetical')]);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: LibraryView(
      controller: controller, onSelect: (item) => selected.add(item.uri),
      onOpenFolder: (item) => folders.add(item.uri),
      artworkBuilder: (_, item) => ColoredBox(key: ValueKey('artwork:${item.uri}'), color: const Color(0xff334455)),
      actionsBuilder: (_, item) => TextButton(key: ValueKey('action:${item.uri}'),
        onPressed: () => actions.add(item.uri), child: const Text('Action')),
    ))));
    repository.requests.single.result.complete(page());
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('Search in Your Library'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    final original = jsonDecode(File('reverse-engineering/fixtures/library-oracle.json').readAsStringSync()) as Map<String, dynamic>;
    expect(find.text((original['typeLabels'] as Map)['album:ep'] as String), findsOneWidget);
    await tester.tap(find.text('Provided album'));
    await tester.tap(find.byKey(ValueKey('action:${album.uri}')));
    expect(selected, [album.uri]);
    expect(actions, [album.uri]);
    await tester.tap(find.text('Playlists'));
    expect(repository.requests.last.query.filters, ['2']);
    repository.requests.last.result.complete(page(filtered: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear Library filters'));
    repository.requests.last.result.complete(page());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Provided folder'));
    expect(folders, [folder.uri]);
    expect(repository.requests.last.query.folderUri, folder.uri);
    repository.requests.last.result.complete(LibraryPage(items: [album], totalLength: 1,
      openedFolderName: 'Provided folder', parentFolderUri: ''));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back to parent folder'));
    expect(repository.requests.last.query.folderUri, isNull);
    repository.requests.last.result.complete(page());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sort: Recents'));
    await tester.pumpAndSettle();
    await tester.tap(find.ancestor(of: find.text('Compact list'), matching: find.byType(CheckedPopupMenuItem<Object>)));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('artwork:${album.uri}')), findsNothing);
    await tester.tap(find.byTooltip('Sort: Recents'));
    await tester.pumpAndSettle();
    await tester.tap(find.ancestor(of: find.text('Default grid'), matching: find.byType(CheckedPopupMenuItem<Object>)));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(320, 640);
    await tester.pumpAndSettle();
    await tester.pumpWidget(MediaQuery(data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: LibraryView(
        controller: controller, onSelect: (item) => selected.add(item.uri))))));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Content is currently unavailable.'), 200,
      scrollable: find.descendant(of: find.byKey(const PageStorageKey('library-grid')),
        matching: find.byType(Scrollable)));
    expect(tester.takeException(), isNull);
    expect(find.text('Content is currently unavailable.'), findsOneWidget);
  });

  testWidgets('Library loading failure retries and renders an empty supplied library', (tester) async {
    final repository = _PendingRepository();
    final controller = LibraryController(repository);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(body: LibraryView(
      controller: controller, onSelect: (_) => fail('Empty Library cannot select content')))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.requests.single.result.completeError(StateError('Synthetic unavailable backend'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t load Your Library'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    repository.requests.last.result.complete(LibraryPage());
    await tester.pumpAndSettle();
    expect(find.text('Your Library is empty'), findsOneWidget);
  });
}
