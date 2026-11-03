import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/native_cef_http2_pool.dart';
import 'package:spotify_flutter/protocol/native_http_protocol_policy.dart';
import 'package:spotify_flutter/protocol/native_renderer_http2_transport.dart';
import 'package:spotify_flutter/protocol/native_renderer_http3_transport.dart';
import 'package:spotify_flutter/protocol/native_renderer_http_request.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';
import 'package:spotify_flutter/transport/quiche/client.dart';

void main() {
  test('Original renderer connection race dispatches each original body once', () async {
    final cases = <Map>[
      for (final path in ['reverse-engineering/fixtures/native-renderer-search.json', 'reverse-engineering/fixtures/native-renderer-home.json'])
        ...(jsonDecode(File(path).readAsStringSync()) as Map)['cases'] as List,
    ];
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/http_protocol_loopback_server.py', '--hold-quic']);
    final errors = <String>[];
    final stderr = peer.stderr.transform(utf8.decoder).listen(errors.add);
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    QuicheHttp3Client? quic;
    NativeCefHttp2Pool? h2Pool;
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map;
      final authority = 'localhost:${ready['port']}';
      final origin = Uri.parse('https://$authority');
      final pool = NativeCefHttp2Pool(securityContext: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ready['certificate'] as String));
      h2Pool = pool;
      final shared = QuicheHttp3Client(libraryPath: File('.local/native/libquiche.dylib').absolute.path,
        trustedCertificatesPath: ready['certificate'] as String, connectTimeout: const Duration(milliseconds: 200));
      quic = shared;
      var wallMicros = 0, ticksMicros = 0;
      final backoff = jsonDecode(File('reverse-engineering/evidence/native-http-alternative-backoff.json').readAsStringSync()) as Map;
      final delays = (backoff['defaultDelayMicrosecondsByPriorCount'] as List).cast<int>();
      final policy = NativeHttpProtocolPolicy(nowMicroseconds: () => wallMicros,
        monotonicMicroseconds: () => ticksMicros);
      Future<void>? alternativeJob;
      Future<void> prepareHttp3() {
        final job = shared.prepareOrigin(origin);
        alternativeJob = job;
        return job;
      }
      Future<int> peerQuicConnections() async {
        peer.stdin.writeln('quic-state');
        expect(await output.moveNext().timeout(const Duration(seconds: 5)), isTrue);
        return (jsonDecode(output.current) as Map)['quicConnections'] as int;
      }
      // Original requests3987/4020 each send once over H2 while QUIC4003
      // opens, then4128 reuses established QUIC. The peer's explicit UDP gate
      // supplies the network condition without delaying either HTTP body.
      // Pinned public BrokenAlternativeServices defaults suppress a failed
      // alternative for300s, then600s. Expiry removes its cached advertisement.
      // Actual server QUIC accepts distinguish suppression from H2 merely
      // winning another connection race. No application request is replayed.
      final expectedProtocols = ['h2', 'h2', 'h2', 'h2', 'h2', 'h2', 'h2', 'h3'];
      for (var index = 0; index < expectedProtocols.length; index++) {
        final item = cases[index % cases.length];
        final application = item['application'] as Map, expected = item['expected'] as Map;
        if (index == 2) wallMicros = const Duration(days: 1).inMicroseconds;
        if (index == 3) ticksMicros = delays[0];
        if (index == 5) {
          ticksMicros = delays[0] + delays[1] ~/ 2;
          wallMicros = const Duration(days: 2).inMicroseconds;
        }
        if (index == 6) ticksMicros = delays[0] + delays[1];
        if (index == 7) {
          peer.stdin.writeln('allow-quic');
          expect(await output.moveNext().timeout(const Duration(seconds: 5)), isTrue);
          expect((jsonDecode(output.current) as Map)['quicGateOpened'], isTrue);
          await shared.prepareOrigin(origin);
        }
        final request = RequestEnvelope(method: application['method'] as String,
          url: 'https://$authority/pathfinder/v2/query',
          headers: (application['headers'] as Map).cast<String, String>(),
          body: base64Decode(application['bodyBase64'] as String),
          authorize: application['authorize'] as bool,
          includeCredentials: application['includeCredentials'] as bool,
          responseType: application['responseType'] as String);
        final selected = await policy.selectReady(request, http3FieldsVerified: true, connectionContext: shared,
          http2Available: () => pool.hasAvailableConnection(origin), http3Available: () => shared.isOriginReady(origin),
          smoothedRttMicroseconds: () => shared.smoothedRttMicroseconds(origin),
          prepareHttp2: () => pool.prepareOrigin(origin, const Duration(seconds: 3)),
          prepareHttp3: prepareHttp3);
        final profile = NativeRendererSearchProfile(locale: item['locale'] as String, endpoint: request.url);
        final h3 = NativeRendererHttp3Transport(profile: profile, clientToken: () => item['clientToken'] as String,
          client: shared);
        final h2 = NativeRendererHttp2Transport(profile: profile, clientToken: () => item['clientToken'] as String,
          pool: pool);
        try {
          final response = await (selected == NativeHttpProtocol.http3 ? h3.send(request) : h2.send(request));
          policy.observeResponse(request.url, response.headers);
          final received = jsonDecode(response.body) as Map;
          final pairs = received['headers'] as List;
          final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
          expect(fields.length, pairs.length);
          expect(fields, {...(expected['headers'] as Map).cast<String, String>(), ':authority': authority});
          expect(received['bodyBase64'], expected['bodyBase64']);
          expect(received['protocol'], expectedProtocols[index]);
          expect(received['requestCount'], index + 1,
            reason: 'Only the winning connection receives HTTP headers and the original body');
          if (const {1, 2, 4, 5}.contains(index)) {
            await expectLater(alternativeJob!, throwsA(isA<http.ClientException>()));
            expect(await peerQuicConnections(), index < 4 ? 1 : 2,
              reason: 'A failed alternative is suppressed until its original monotonic cooldown expires');
          }
        } finally { h2.close(); h3.close(); }
      }
    } finally {
      quic?.close(); h2Pool?.close();
      peer.stdin.writeln('stop');
      await peer.stdin.close();
      await output.cancel();
      await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () { peer.kill(); return -1; });
      await stderr.cancel();
      expect(errors, isEmpty);
    }
  });

  // H2 owns producer/repository coverage. This distinct boundary protects the
  // production H3 adapter's complete field and body transfer into quiche. A
  // lower-level quiche replay cannot catch a changed or bypassed renderer plan.
  test('Renderer production H3 sender preserves original Search Home album and artist requests', () async {
    final wire = jsonDecode(File('reverse-engineering/evidence/native-renderer-http3.json').readAsStringSync()) as Map;
    final priorityEvidence = jsonDecode(File('reverse-engineering/evidence/native-http3-priority.json').readAsStringSync()) as Map;
    final cases = <Map>[
      for (final path in ['reverse-engineering/fixtures/native-renderer-search.json',
          'reverse-engineering/fixtures/native-renderer-home.json', 'reverse-engineering/fixtures/native-renderer-album.json',
          'reverse-engineering/evidence/native-renderer-artist.json', 'reverse-engineering/fixtures/native-renderer-full-search.json',
          'reverse-engineering/fixtures/native-renderer-home-destinations.json'])
        ...(jsonDecode(File(path).readAsStringSync()) as Map)['cases'] as List,
    ];
    final library = File('.local/native/libquiche.dylib').absolute.path;
    if (!File(library).existsSync()) {
      throw StateError('Build quiche with uv run --project tools/oracles --locked python tools/build_quiche.py');
    }
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/http_protocol_loopback_server.py']);
    final errors = <String>[];
    final stderr = peer.stderr.transform(utf8.decoder).listen(errors.add);
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    QuicheHttp3Client? client;
    NativeRendererHttp3Transport? sender;
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map;
      final authority = 'localhost:${ready['port']}';
      final shared = QuicheHttp3Client(libraryPath: library,
        trustedCertificatesPath: ready['certificate'] as String);
      client = shared;
      var checkedH3Requests = 0;
      for (final item in cases) {
        final application = item['application'] as Map, expected = item['expected'] as Map;
        sender = NativeRendererHttp3Transport(client: shared,
          profile: NativeRendererSearchProfile(locale: item['locale'] as String,
            endpoint: 'https://$authority/pathfinder/v2/query'),
          clientToken: () => item['clientToken'] as String);
        final response = await sender.send(RequestEnvelope(method: application['method'] as String,
          url: 'https://$authority/pathfinder/v2/query',
          headers: (application['headers'] as Map).cast<String, String>(),
          body: base64Decode(application['bodyBase64'] as String),
          authorize: application['authorize'] as bool,
          includeCredentials: application['includeCredentials'] as bool,
          responseType: application['responseType'] as String));
        expect(response.statusCode, 200, reason: item['name'] as String);
        final actual = jsonDecode(response.body) as Map;
        final pairs = actual['headers'] as List;
        final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
        // Producer fixtures own values/body. Eighty original H3 POSTs also
        // join their transactions to the exact sent header blocks, supplying
        // independent order and rejecting duplicate fields hidden by a Map.
        expect(pairs.map((pair) => pair[0]).toList(), wire['profiles']['POST']['headerSequence'],
          reason: '${item['name']}: original H3 encoder-input field sequence');
        expect(actual['protocol'], 'h3', reason: item['name'] as String);
        expect(fields, {...(expected['headers'] as Map).cast<String, String>(), ':authority': authority},
          reason: item['name'] as String);
        expect(actual['bodyBase64'], expected['bodyBase64'], reason: item['name'] as String);
        final allPriorities = (actual['clientControlFrames'] as List).cast<Map>()
          .where((frame) => frame['type'] == priorityEvidence['frameType']).toList();
        expect(allPriorities, hasLength(++checkedH3Requests),
          reason: 'Original renderer control update count equals request count');
        final priorities = allPriorities.where((frame) => frame['prioritizedElementId'] == actual['streamId']).toList();
        expect(priorities, hasLength(1), reason: 'Original renderer H3 sends one targeted priority update');
        expect(priorities.single['priorityFieldValue'], (expected['headers'] as Map)['priority']);
        sender.close(); sender = null;
      }
    } finally {
      sender?.close();
      client?.close();
      peer.stdin.writeln('stop');
      await peer.stdin.close();
      await output.cancel();
      await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () { peer.kill(); return -1; });
      await stderr.cancel();
      expect(errors, isEmpty, reason: 'Independent outgoing H3 peer diagnostics');
    }
  });
}
