import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/home/native_recent_contexts.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
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
