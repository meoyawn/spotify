import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/entities/controller.dart';
import 'package:spotify_flutter/entities/models.dart';
import 'package:spotify_flutter/entities/native_liked_songs_repository.dart';
import 'package:spotify_flutter/entities/view.dart';
import 'package:spotify_flutter/library/liked_songs.dart';
import 'package:spotify_flutter/library/native_collection_read_client.dart';
import 'package:spotify_flutter/protocol/generated/collection2v2.pb.dart';

void main() {
  test('Liked Songs pages the complete shared collection and follows acknowledged changes', () async {
    final requested = <String>[];
    final described = <List<String>>[];
    final tracks = [for (var index = 1; index <= 52; index++)
      CollectionItem(uri: 'spotify:track:${index.toString().padLeft(22, '0')}',
        addedAt: Int64(1700000000 + index))];
    final collection = NativeCollectionReadClient(baseUrl: 'https://fixture.invalid',
      username: 'fixture', collectionSet: 'collection', inheritedHeaders: const {}, send: (request) async {
        final page = PageRequest.fromBuffer(request.body);
        requested.add(page.paginationToken);
        return http.Response.bytes((page.paginationToken.isEmpty
          ? PageResponse(items: [...tracks.take(50), CollectionItem(uri: 'spotify:album:0000000000000000000001')],
              nextPageToken: 'tail')
          : PageResponse(items: [...tracks.skip(50),
              CollectionItem(uri: 'spotify:track:0000000000000000000099', isRemoved: true)], syncToken: 'complete'))
          .writeToBuffer(), 200);
      });
    addTearDown(collection.changes.dispose);
    final repository = NativeLikedSongsRepository(collection: collection, username: 'fixture',
      describeTracks: (uris, {cancellationToken}) async {
        described.add(uris);
        return {for (final uri in uris) uri: EntityRow.fromJson({
          'type': 'track', 'uri': uri, 'name': uri.split(':').last, 'canRequestPlayback': true})};
      });
    final controller = EntityController(repository, uri: likedSongsUri);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.state.phase, EntityPhase.ready);
    expect(controller.state.details!.trackCount, 52);
    expect(controller.state.rows, hasLength(50));
    expect(controller.state.rows.first.uri, tracks.last.uri);
    expect(controller.state.rows.first.data['addedAt'], '2023-11-14T22:14:12.000Z');
    expect(controller.state.details!.canRequestPlayback, isTrue);
    expect(described.single, hasLength(50));
    final selection = EntityPlaybackSelection(entity: controller.state.details!, rows: controller.state.rows);
    expect(selection.contextRows!.map((row) => row.uri), tracks.reversed.map((track) => track.uri));
    expect(described, hasLength(1));
    await controller.loadMore();
    expect(controller.state.rows.map((row) => row.uri), tracks.reversed.map((track) => track.uri));
    expect(controller.state.hasMore, isFalse);
    expect(described.last, hasLength(2));
    expect((await collection.contains([tracks.last.uri]))[tracks.last.uri], isTrue);
    expect(requested, ['', 'tail']);

    final updated = Completer<void>();
    controller.addListener(() {
      if (!updated.isCompleted && controller.state.phase == EntityPhase.ready &&
          controller.state.details?.trackCount == 51) { updated.complete(); }
    });
    await collection.recordAcknowledgedChange(tracks.last.uri, false);
    await updated.future;
    expect(controller.state.rows.first.uri, tracks[50].uri);
    expect(controller.state.rows.any((row) => row.uri == tracks.last.uri), isFalse);
    expect(requested, ['', 'tail']);
  });

  testWidgets('an empty Liked Songs collection has a usable empty state without metadata requests', (tester) async {
    final collection = NativeCollectionReadClient(baseUrl: 'https://fixture.invalid',
      username: 'fixture', collectionSet: 'collection', inheritedHeaders: const {}, send: (_) async =>
        http.Response.bytes(PageResponse(syncToken: 'empty').writeToBuffer(), 200));
    addTearDown(collection.changes.dispose);
    final repository = NativeLikedSongsRepository(collection: collection, username: 'fixture',
      describeTracks: (_, {cancellationToken}) async => throw StateError('Empty collection must not request metadata'));
    final controller = EntityController(repository, uri: likedSongsUri);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: EntityView(controller: controller))));
    await tester.pumpAndSettle();
    expect(find.text('Liked Songs'), findsOneWidget);
    expect(find.text('Songs you like will appear here.'), findsOneWidget);
    expect(controller.state.details!.trackCount, 0);
    expect(controller.state.details!.canRequestPlayback, isFalse);
  });
}
