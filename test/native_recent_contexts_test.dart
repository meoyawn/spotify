import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/home/native_recent_contexts.dart';
import 'package:spotify_flutter/home/native_recently_played_repository.dart';
import 'package:spotify_flutter/home/destinations_repository.dart';
import 'package:spotify_flutter/home/models.dart';
import 'package:spotify_flutter/library/liked_songs.dart';
import 'package:spotify_flutter/protocol/generated/recently_played_backend.pb.dart' as wire;
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('Recently Played matches the independently executed original projection and reuses the native snapshot', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-liked-recent-projection.json').readAsStringSync()) as Map;
    final scenario = fixture['recentlyPlayed'] as Map;
    final response = wire.RecentlyPlayed()..mergeFromProto3Json({'contexts': scenario['input']});
    var sends = 0, descriptions = 0;
    final client = NativeRecentContextsClient(baseUrl: 'https://fixture.invalid', inheritedHeaders: const {},
      nowMicroseconds: () => 0, send: (_) async {
        sends++;
        return http.Response.bytes(response.writeToBuffer(), 200, headers: {
          'cache-control': 'private, max-age=3600', 'date': HttpDate.format(DateTime.now().toUtc())});
      });
    final repository = NativeRecentlyPlayedRepository(client: client, describe: (uris, {cancellationToken}) async {
      descriptions++;
      return {for (final uri in uris) uri: HomeItem(type: uri.split(':')[1], uri: uri, name: uri)};
    });
    const target = HomeDestinationTarget(HomeDestinationKind.recentlyPlayed, 'spotify:genre:recently-played');
    final (page, duplicate) = await (repository.destination(target), repository.destination(target)).wait;
    expect(duplicate, same(page));
    expect(page.sections.single.items.map((item) => item.uri),
      (scenario['expected'] as List).map((item) => (item as Map)['uri']));
    expect(page.sections.single.items.where((item) => item.uri == likedSongsUri).single.images, fixture['likedSongs']['images']);
    expect(page.nextOffset, isNull);
    expect(sends, 1);
    expect(descriptions, 1);
  });

  test('Recent contexts shares fresh reads and aborts transport only after the last reader leaves', () async {
    var now = 0;
    final requests = <RequestEnvelope>[];
    final firstSent = Completer<void>(), secondSent = Completer<void>();
    final firstResponse = Completer<http.Response>(), secondResponse = Completer<http.Response>();
    final client = NativeRecentContextsClient(baseUrl: 'https://fixture.invalid',
      inheritedHeaders: const {}, nowMicroseconds: () => now, send: (request) {
        requests.add(request);
        if (requests.length == 1) {
          firstSent.complete();
          return firstResponse.future.asCancellable(request.cancellationToken);
        }
        secondSent.complete();
        return secondResponse.future.asCancellable(request.cancellationToken);
      });
    final first = CancellationToken(), second = CancellationToken();
    final abandoned = client.read(cancellationToken: first);
    final retained = client.read(cancellationToken: second);
    await firstSent.future;
    first.cancel();
    await expectLater(abandoned, throwsA(isA<CancelledException>()));
    expect(requests.single.cancellationToken!.isCancelled, isFalse);
    firstResponse.complete(http.Response.bytes(const [], 200, headers: {
      'cache-control': 'private, max-age=3600', 'date': HttpDate.format(DateTime.now().toUtc()),
    }));
    final snapshot = await retained;
    expect(await client.read(), same(snapshot));
    expect(requests, hasLength(1));

    now = const Duration(hours: 1, seconds: 1).inMicroseconds;
    final last = CancellationToken();
    final expired = client.read(cancellationToken: last);
    await secondSent.future;
    last.cancel();
    await expectLater(expired, throwsA(isA<CancelledException>()));
    expect(requests.last.cancellationToken!.isCancelled, isTrue);
  });
}
