import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/entities/controller.dart';
import 'package:spotify_flutter/entities/models.dart';
import 'package:spotify_flutter/entities/repository.dart';
import 'package:spotify_flutter/entities/view.dart';
import 'package:spotify_flutter/library/liked_songs.dart';

void main() {
  for (final uri in ['spotify:playlist:scrolling', likedSongsUri]) {
    testWidgets('$uri pages on scroll, preserves position and retries failures explicitly', (tester) async {
      final offsets = <int>[];
      var pending = Completer<EntityTrackPage>();
      final controller = EntityController(_Repository(initialCount: 50, total: 125,
        onTracks: (offset) { offsets.add(offset); return pending.future; }), uri: uri);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: EntityView(controller: controller))));
      await tester.pumpAndSettle();
      final scroll = find.byType(CustomScrollView);
      final position = tester.state<ScrollableState>(find.descendant(of: scroll,
        matching: find.byType(Scrollable)).first).position;
      expect(offsets, isEmpty);

      await tester.drag(scroll, const Offset(0, -10000));
      await tester.pump();
      await tester.pump();
      expect(offsets, [50]);
      expect(controller.state.rows, hasLength(50));
      await tester.drag(scroll, const Offset(0, -1000));
      await tester.pump();
      expect(offsets, [50]);
      final before = position.pixels;
      pending.complete(_page(50, 50, 125));
      await tester.pumpAndSettle();
      expect(controller.state.rows, hasLength(100));
      expect(position.pixels, closeTo(before, 1));
      expect(offsets, [50]);

      pending = Completer<EntityTrackPage>();
      await tester.drag(scroll, const Offset(0, -10000));
      await tester.pump();
      await tester.pump();
      expect(offsets, [50, 100]);
      pending.completeError(StateError('Synthetic page failure'));
      await tester.pumpAndSettle();
      expect(controller.state.rows, hasLength(100));
      expect(find.text('Couldn’t load more tracks').hitTestable(), findsOneWidget);
      await tester.drag(scroll, const Offset(0, -1000));
      await tester.pumpAndSettle();
      expect(offsets, [50, 100]);

      pending = Completer<EntityTrackPage>();
      await tester.tap(find.text('Try again').hitTestable());
      await tester.pump();
      expect(offsets, [50, 100, 100]);
      pending.complete(_page(100, 25, 125));
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, -10000));
      await tester.pumpAndSettle();
      expect(controller.state.rows, hasLength(125));
      expect(find.text('Track 124'), findsOneWidget);
      expect(controller.state.hasMore, isFalse);
      expect(offsets, [50, 100, 100]);
      expect(find.text('Load more'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a growing viewport fills short pages and stops when there is enough content', (tester) async {
    tester.view.physicalSize = const Size(1100, 450);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final offsets = <int>[];
    var pending = Completer<EntityTrackPage>();
    final controller = EntityController(_Repository(initialCount: 10, total: 50,
      onTracks: (offset) { offsets.add(offset); return pending.future; }), uri: 'spotify:playlist:resize');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EntityView(controller: controller))));
    await tester.pumpAndSettle();
    expect(offsets, isEmpty);
    tester.view.physicalSize = const Size(1100, 1500);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(offsets, [10]);
    pending.complete(_page(10, 1, 50));
    pending = Completer<EntityTrackPage>();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(offsets, [10, 11]);
    pending.complete(_page(11, 30, 50));
    await tester.pumpAndSettle();
    expect(offsets, [10, 11]);
    expect(controller.state.rows, hasLength(41));
    expect(controller.state.hasMore, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filtering loaded tracks does not scan unseen pages', (tester) async {
    final offsets = <int>[];
    final controller = EntityController(_Repository(initialCount: 50, total: 100,
      onTracks: (offset) async { offsets.add(offset); return _page(offset, 50, 100); }),
      uri: 'spotify:playlist:filter');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EntityView(controller: controller))));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Find in playlist'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('No matching tracks.'), findsOneWidget);
    expect(offsets, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

EntityTrackPage _page(int offset, int count, int total) => EntityTrackPage(offset: offset,
  limit: count, totalLength: total, rows: [for (var index = offset; index < offset + count; index++)
    EntityRow.fromJson({'type': 'track', 'uri': 'spotify:track:$index', 'name': 'Track $index'})]);

class _Repository implements EntityRepository {
  _Repository({required this.initialCount, required this.total, required this.onTracks});
  final int initialCount, total;
  final Future<EntityTrackPage> Function(int) onTracks;
  @override Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async => EntityPage(
    details: EntityDetails.fromJson({'type': 'playlist', 'uri': uri, 'name': 'Scrolling playlist'}),
    tracks: _page(0, initialCount, total));
  @override Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit,
    CancellationToken? cancellationToken}) => onTracks(offset).asCancellable(cancellationToken);
}
