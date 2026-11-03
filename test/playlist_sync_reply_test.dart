import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playlist_service/sync_reply.dart';

List<int> _bytes(String hex) => [for (var at = 0; at < hex.length; at += 2)
  int.parse(hex.substring(at, at + 2), radix: 16)];
String _hex(List<int> bytes) => bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/playlist-service-sync-reply.json').readAsStringSync()) as Map;
  group('Original primary playlist sync callbacks', () {
    for (final scenario in fixture['scenarios'] as List) {
      test(scenario['name'] as String, () {
        // A foreign category can even have the name "http" without being the
        // original category singleton. Its identity must pass through intact.
        const external = 'http';
        Object category(String name) => switch (name) {
          'http' => PlaylistSyncKnownCategory.http,
          'system' => PlaylistSyncKnownCategory.system,
          _ => external,
        };
        final replies = <PlaylistSyncReply>[];
        final responseSources = <Map>[];
        Map current = {};
        final processor = PlaylistSyncReplyProcessor(onReply: (reply) {
          replies.add(reply);
          responseSources.add(current);
        });
        for (final raw in scenario['operations'] as List) {
          current = raw as Map;
          switch (current['kind']) {
            case 'close': processor.close();
            case 'response': processor.receiveResponse(statusCode: current['statusCode'] as int,
              headers: (current['headers'] as Map? ?? {}).cast<String, String>(),
              body: _bytes(current['bodyHex'] as String? ?? ''));
            case 'failure': processor.receiveFailure(PlaylistSyncCode(current['value'] as int,
              category(current['category'] as String)));
          }
        }
        final expected = (scenario['expected'] as Map)['deliveries'] as List;
        expect(replies, hasLength(expected.length));
        for (var at = 0; at < replies.length; at++) {
          final reply = replies[at], source = responseSources[at];
          final original = expected[at] as Map;
          final error = original['error'] as Map, status = original['status'] as Map;
          expect(reply.error.value, error['value']);
          expect(reply.error.category, same(category(error['category'] as String)));
          expect(reply.status.value, status['value']);
          expect(reply.status.category, same(category(status['category'] as String)));
          expect(reply.headers, original['headers']);
          expect(reply.responseStatusCode, source['statusCode']);
          expect(_hex(reply.responseBody), source['bodyHex'] ?? '');
          expect(reply.content.hasLength() ? reply.content.length : null, original['contentLength']);
          expect(reply.content.isInitialized(), original['contentInitialized']);
          expect(reply.content.isFrozen, isTrue);
          if (reply.error.value == 4 && reply.error.category == PlaylistSyncKnownCategory.http) {
            // Protobuf specifies failure, not a portable partially-mutated
            // string value. Prefix fields and raw received bytes remain above.
            expect(reply.contentFidelity, PlaylistSyncContentFidelity.partial);
          } else if (source['bodyHex'] == '820101ff' && source['statusCode'] == 200) {
            expect(reply.contentFidelity, PlaylistSyncContentFidelity.lossyStrings);
            expect(reply.content.ownerUsername, '\uFFFD');
          } else {
            expect(reply.contentFidelity, PlaylistSyncContentFidelity.complete);
            expect(_hex(reply.content.writeToBuffer()), original['contentWireHex']);
          }
        }
      });
    }
  });

  test('reply snapshots survive caller mutation and subsequent completion', () {
    final replies = <PlaylistSyncReply>[];
    final processor = PlaylistSyncReplyProcessor(onReply: replies.add);
    final headers = {'ETag': 'first'};
    final body = [0x10, 7];
    processor.receiveResponse(statusCode: 200, headers: headers, body: body);
    headers.clear();
    body.clear();
    processor.receiveResponse(statusCode: 204, headers: const {}, body: const []);
    expect(replies.first.headers, {'ETag': 'first'});
    expect(replies.first.responseBody, [0x10, 7]);
    expect(replies.first.content.length, 7);
    expect(replies.last.content.hasLength(), isFalse);
    expect(() => replies.first.headers.clear(), throwsUnsupportedError);
    expect(() => replies.first.responseBody.clear(), throwsUnsupportedError);
    expect(() => replies.first.content.length = 9, throwsUnsupportedError);
  });
}
