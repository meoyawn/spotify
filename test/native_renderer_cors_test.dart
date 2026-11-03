import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/native_cef_http2_pool.dart';
import 'package:spotify_flutter/protocol/native_renderer_cors.dart';
import 'package:spotify_flutter/protocol/native_renderer_http2_transport.dart';
import 'package:spotify_flutter/protocol/native_renderer_http3_transport.dart';
import 'package:spotify_flutter/protocol/native_renderer_http_request.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';
import 'package:spotify_flutter/transport/quiche/client.dart';

void main() {
  test('Renderer preflight fields permissions and cache gate original outgoing POST bytes', () async {
    final original = jsonDecode(File('reverse-engineering/fixtures/native-renderer-preflight.json').readAsStringSync()) as Map;
    final rules = jsonDecode(File('reverse-engineering/evidence/native-renderer-cors-cache.json').readAsStringSync()) as Map;
    final cases = (jsonDecode(File('reverse-engineering/fixtures/native-renderer-search.json').readAsStringSync()) as Map)['cases'] as List;
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/http_protocol_loopback_server.py', '--renderer-preflight']);
    final errors = <String>[];
    final stderr = peer.stderr.transform(utf8.decoder).listen(errors.add);
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    NativeCefHttp2Pool? h2;
    QuicheHttp3Client? h3;
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map;
      final authority = 'localhost:${ready['port']}';
      final endpoint = 'https://$authority/pathfinder/v2/query';
      final pool = NativeCefHttp2Pool(securityContext: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ready['certificate'] as String));
      h2 = pool;
      final quic = QuicheHttp3Client(libraryPath: File('.local/native/libquiche.dylib').absolute.path,
        trustedCertificatesPath: ready['certificate'] as String);
      h3 = quic;
      var now = 0, overH3 = false;
      final cors = NativeRendererCors(nowMicroseconds: () => now);
      Future<void> sendCase(int index) async {
        final item = cases[index] as Map, app = item['application'] as Map;
        final profile = NativeRendererSearchProfile(locale: item['locale'] as String, endpoint: endpoint);
        final request = profile.prepareSearch(RequestEnvelope(method: app['method'] as String, url: endpoint,
          headers: (app['headers'] as Map).cast<String, String>(), body: base64Decode(app['bodyBase64'] as String),
          authorize: app['authorize'] as bool, includeCredentials: app['includeCredentials'] as bool,
          responseType: app['responseType'] as String), clientToken: item['clientToken'] as String);
        Future<http.StreamedResponse> dispatch(NativeRendererHttpRequestPlan plan, CancellationToken token) async {
          final sender2 = overH3 ? null : NativeRendererHttp2Transport(profile: profile,
            clientToken: () => item['clientToken'] as String, pool: pool);
          final sender3 = overH3 ? NativeRendererHttp3Transport(profile: profile,
            clientToken: () => item['clientToken'] as String, client: quic) : null;
          void close() { sender2?.close(); sender3?.close(); }
          try {
            final response = await (sender3?.sendPrepared(plan, cancellationToken: token) ??
              sender2!.sendPrepared(plan, cancellationToken: token));
            Stream<List<int>> body() async* {
              try { yield* response.stream; }
              finally { close(); }
            }
            return http.StreamedResponse(body(), response.statusCode, headers: response.headers);
          } catch (_) { close(); rethrow; }
        }
        final response = await http.Response.fromStream(await cors.send(request,
          profile: profile, sendPrepared: dispatch));
        expect(response.statusCode, 200);
      }
      Future<List> captured() async {
        peer.stdin.writeln('captures');
        expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        return (jsonDecode(output.current) as Map)['captures'] as List;
      }
      List options(List rows) => rows.where((row) => (row['headers'] as List).first[1] == 'OPTIONS').toList();
      // Original initial misses are independent, even while another OPTIONS
      // is in flight. Both actual requests retain their original producer body.
      await Future.wait([sendCase(0), sendCase(1)]);
      var rows = await captured();
      expect(rows.length, 4);
      expect(options(rows).length, 2);
      // Cached permissions belong to the renderer context, not an H2 socket.
      // Switch to real H3 and retain them until the public maximum boundary.
      overH3 = true;
      now = (rules['maximumExpiryMicroseconds'] as int) - 1;
      await sendCase(2);
      rows = await captured();
      expect(rows.length, 5);
      expect(options(rows).length, 2);
      now = rules['maximumExpiryMicroseconds'] as int;
      await sendCase(3);
      rows = await captured();
      expect(rows.length, 7);
      final preflights = options(rows);
      expect(preflights.length, 3);
      final expectedOptions = [for (final pair in original['requestHeaderProfiles'][0]['value'] as List)
        [pair[0], pair[0] == ':authority' ? authority : pair[1]]];
      for (final row in preflights) {
        expect(row['headers'], expectedOptions);
        expect(row['bodyBase64'], '');
        expect(row['headersEndStream'], isTrue);
      }
      expect(preflights.map((row) => row['protocol']), ['h2', 'h2', 'h3']);
      final actualPosts = [for (final row in rows)
        if ((row['headers'] as List).first[1] == 'POST')
          {'headers': {for (final pair in row['headers'] as List) pair[0]: pair[1]}, 'bodyBase64': row['bodyBase64']}];
      final expectedPosts = [for (final item in cases)
        {'headers': {...(item['expected']['headers'] as Map), ':authority': authority},
          'bodyBase64': item['expected']['bodyBase64']}];
      expect(actualPosts, unorderedEquals(expectedPosts));
    } finally {
      h2?.close(); h3?.close();
      peer.stdin.writeln('stop');
      await peer.stdin.close();
      await output.cancel();
      await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () { peer.kill(); return -1; });
      await stderr.cancel();
      expect(errors, isEmpty);
    }
  });
}
