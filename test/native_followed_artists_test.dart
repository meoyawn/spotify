import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/library/native_collection_read_client.dart';
import 'package:spotify_flutter/library/native_followed_artists.dart';
import 'package:spotify_flutter/protocol/generated/collection2v2.pb.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  const uri = 'spotify:artist:0000000000000000000001';

  test('artist writes use their own bucket and wait for acknowledgement before changing membership', () async {
    final requests = <RequestEnvelope>[];
    final dispatched = Completer<void>(), acknowledged = Completer<http.Response>();
    var reads = 0, changed = 0;
    final membership = NativeCollectionReadClient(baseUrl: 'https://spclient.example.test',
      username: 'fixture-user', collectionSet: 'artist', inheritedHeaders: const {'app-platform': 'OSX_ARM64'},
      send: (_) async {
        reads++;
        return http.Response.bytes(PageResponse(syncToken: 'fixture-sync').writeToBuffer(), 200);
      });
    final owner = NativeFollowedArtists(membership: membership, onChanged: () => changed++, send: (request) async {
      requests.add(request);
      if (requests.length == 1) { dispatched.complete(); return acknowledged.future; }
      return http.Response('', 200);
    });
    expect(await owner.contains(uri), false);
    final follow = owner.setFollowing(uri, true);
    await dispatched.future;
    expect(await owner.contains(uri), false);
    acknowledged.complete(http.Response('', 200));
    await follow;
    expect(await owner.contains(uri), true);
    expect((await membership.items()).single.addedAt.toInt(), greaterThan(0));
    await owner.setFollowing(uri, true);
    expect(requests, hasLength(1));
    await owner.setFollowing(uri, false);
    expect(await owner.contains(uri), false);
    expect(reads, 1);
    expect(changed, 2);
    expect(requests, hasLength(2));

    final updateIds = <String>{};
    for (final (index, request) in requests.indexed) {
      expect(request.method, 'POST');
      expect(request.url, 'https://spclient.example.test/collection/v2/write');
      expect(request.headers, {'app-platform': 'OSX_ARM64',
        'Accept': 'application/vnd.collection-v2.spotify.proto',
        'Content-Type': 'application/vnd.collection-v2.spotify.proto'});
      final message = WriteRequest.fromBuffer(request.body as List<int>);
      expect(message.username, 'fixture-user');
      expect(message.set, 'artist');
      expect(message.items, hasLength(1));
      expect(message.items.single.uri, uri);
      expect(message.items.single.isRemoved, index == 1);
      expect(message.items.single.hasIsRemoved(), index == 1);
      expect(message.items.single.addedAt.toInt(),
        closeTo(DateTime.now().millisecondsSinceEpoch ~/ 1000, 60));
      expect(message.clientUpdateId, matches(RegExp(r'^[0-9a-f]{16}$')));
      updateIds.add(message.clientUpdateId);
    }
    expect(updateIds, hasLength(2));
  });

  test('a rejected unfollow reconciles membership instead of reporting success', () async {
    var reads = 0;
    final membership = NativeCollectionReadClient(baseUrl: 'https://spclient.example.test',
      username: 'fixture-user', collectionSet: 'artist', inheritedHeaders: const {}, send: (_) async {
        reads++;
        return http.Response.bytes(PageResponse(items: [CollectionItem(uri: uri)],
          syncToken: 'fixture-sync').writeToBuffer(), 200);
      });
    final owner = NativeFollowedArtists(membership: membership, onChanged: () {},
      send: (_) async => http.Response('', 400));
    expect(await owner.contains(uri), true);
    await expectLater(owner.setFollowing(uri, false), throwsStateError);
    expect(await owner.contains(uri), true);
    expect(reads, 2);
  });
}
