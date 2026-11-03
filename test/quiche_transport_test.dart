import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart' show hex;
import 'package:spotify_flutter/library/native_collection_read_client.dart';
import 'package:spotify_flutter/library/native_metadata_client.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/playback/native_audio_files_request.dart';
import 'package:spotify_flutter/playback/native_playplay_body.dart';
import 'package:spotify_flutter/playback/native_playplay_canary.dart';
import 'package:spotify_flutter/playback/native_playplay_request.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/playlist_service/native_track_metadata_request.dart';
import 'package:spotify_flutter/playlist_service/native_read_client.dart';
import 'package:spotify_flutter/protocol/generated/playlist_sync_reason.pb.dart';
import 'package:spotify_flutter/protocol/native_cef_context.dart';
import 'package:spotify_flutter/protocol/native_cef_http2_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_http3_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/native_http_protocol_policy.dart';
import 'package:spotify_flutter/protocol/native_image_projection_map.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';
import 'package:spotify_flutter/transport/quiche/client.dart';

void main() {
  group('Direct quiche HTTP/3 against independent aioquic peer', () {
    Process? server;
    late int port;
    late String certificate;
    late String untrustedCertificate;
    final library = File('.local/native/libquiche.dylib').absolute.path;

    setUpAll(() async {
      if (!File(library).existsSync()) {
        throw StateError('Build the native dependency with uv run --project tools/oracles --locked python tools/build_quiche.py');
      }
      server = await Process.start('uv', ['run', '--project', 'tools/oracles',
        '--locked', '--no-sync', 'python', 'test/support/http_protocol_loopback_server.py']);
      final diagnostics = StringBuffer();
      server!.stderr.transform(utf8.decoder).listen(diagnostics.write);
      final String line;
      try {
        line = await server!.stdout.transform(utf8.decoder)
          .transform(const LineSplitter()).first.timeout(const Duration(seconds: 15));
      } catch (error) {
        throw StateError('Local HTTP/3 peer did not start: $error\n$diagnostics');
      }
      final peer = jsonDecode(line) as Map<String, dynamic>;
      port = peer['port'] as int;
      certificate = peer['certificate'] as String;
      untrustedCertificate = peer['untrustedCertificate'] as String;
    });

    tearDownAll(() async {
      server?.kill();
      await server?.exitCode;
    });

    QuicheHttp3Client client({String? trust, Duration? timeout, Duration? connectTimeout}) {
      final value = QuicheHttp3Client(libraryPath: library,
        trustedCertificatesPath: trust ?? certificate,
        connectTimeout: connectTimeout ?? const Duration(seconds: 10),
        requestTimeout: timeout ?? const Duration(seconds: 15));
      addTearDown(value.close);
      return value;
    }

    Uri url(String path) => Uri.parse('https://localhost:$port$path');

    test('Captured renderer headers and payload reach the HTTP/3 peer unchanged', () async {
      final transport = client();
      final fixture = jsonDecode(File('reverse-engineering/fixtures/wire-header-profile.json')
        .readAsStringSync()) as Map<String, dynamic>;
      for (final profile in fixture['profiles'] as List) {
        final captured = (profile['headers'] as Map).cast<String, String>();
        final headers = Map<String, String>.fromEntries(captured.entries
          .where((entry) => !entry.key.startsWith(':')));
        const path = '/pathfinder/v2/query?q=a+b&encoded=%7E%2B';
        final bytes = utf8.encode(profile['body'] as String);
        final response = await transport.sendEnvelope(RequestEnvelope(method: 'POST',
          url: 'https://localhost:$port$path', headers: headers, body: bytes));
        expect(response.statusCode, 200);
        final received = jsonDecode(response.body) as Map<String, dynamic>;
        final actual = <String, String>{
          for (final pair in received['headers'] as List)
            pair[0] as String: pair[1] as String,
        };
        expect(received['protocol'], 'h3');
        expect(actual, {...headers, ':method': 'POST', ':scheme': 'https',
          ':authority': 'localhost:$port', ':path': path});
        expect(received['bodyBase64'], base64Encode(bytes));
      }
    });

    test('Native header policy reaches the loopback peer with exact values and raw path', () async {
      final transport = client();
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-user-agent-headers.json')
        .readAsStringSync()) as Map;
      const path = '/native-header-check?q=%7E+%2f';
      for (final scenario in fixture['cases'] as List) {
        final request = RequestEnvelope(method: 'POST', url: 'https://localhost:$port$path',
          authorize: false, responseType: 'bytes', body: [0, 128, 255],
          headers: {for (final pair in scenario['headers'] as List)
            pair[0] as String: pair[1] as String});
        final prepared = NativeHttpDefaults(userAgent: scenario['userAgent'] as String).prepare(request);
        final response = await transport.sendEnvelope(prepared);
        expect(response.statusCode, 200);
        final received = jsonDecode(response.body) as Map;
        expect(received['headers'], unorderedEquals([
          [':method', 'POST'], [':scheme', 'https'],
          [':authority', 'localhost:$port'], [':path', path],
          for (final pair in scenario['result'] as List)
            [(pair[0] as String).toLowerCase(), pair[1]],
        ]));
        expect(received['bodyBase64'], 'AID/');
      }
    });

    // Independent NetLog fields plus original proprietary body-producer bytes
    // protect the actual adapter -> quiche -> peer boundary. H2 checks cannot
    // detect dropped fields or changed targets in the H3 adapter/serializer.
    test('Native metadata playlist key and storage original fields and body reach the H3 peer', () async {
      final priorityEvidence = jsonDecode(File('reverse-engineering/evidence/native-http3-priority.json').readAsStringSync()) as Map;
      final priorityFrameType = priorityEvidence['frameType'] as int;
      var checkedH3Requests = 0;
      void verifyPriority(Map received, String originalField) {
        final allUpdates = (received['clientControlFrames'] as List).cast<Map>()
          .where((frame) => frame['type'] == priorityFrameType).toList();
        expect(allUpdates, hasLength(++checkedH3Requests),
          reason: 'Original frame count equals request count, without extra updates for other streams');
        final updates = allUpdates.where((frame) => frame['prioritizedElementId'] == received['streamId']).toList();
        expect(updates, hasLength(1), reason: 'Every original H3 request has one targeted PRIORITY_UPDATE');
        expect(updates.single['priorityFieldValue'], originalField,
          reason: 'Original control-frame ASCII exactly matches the request Priority field');
      }
      final shared = client();
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-streaming-http-fields.json')
        .readAsStringSync()) as Map;
      final originalBody = (jsonDecode(File('reverse-engineering/fixtures/native-playplay-body.json')
        .readAsStringSync()) as Map)['cases'][0] as Map;
      final sender = NativeCefHttp3Transport(client: shared,
        defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
        options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
        context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']));
      addTearDown(sender.close);
      final authority = 'localhost:$port';
      final metadata = jsonDecode(File('reverse-engineering/fixtures/native-metadata-h3.json')
        .readAsStringSync()) as Map;
      final connectionProfile = jsonDecode(File('reverse-engineering/evidence/native-http3-initial-settings.json')
        .readAsStringSync()) as Map;
      final protocols = NativeHttpProtocolPolicy(nowMicroseconds: () => 0);
      final h2Sender = NativeCefHttp2Transport(
        defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
        options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
        context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']),
        securityContext: SecurityContext(withTrustedRoots: false)..setTrustedCertificates(certificate));
      addTearDown(h2Sender.close);
      var bootstrap = true;
      String? h3Connection;
      for (final item in metadata['cases'] as List) {
        final expected = (item['expectedHeaders'] as Map).cast<String, String>();
        final input = item['originalBodyInput'] as Map;
        final requests = SpotifyRequests(baseUrl: 'https://$authority',
          inheritedHeaders: {for (final key in ['accept-language', 'app-platform',
            'spotify-app-version', 'time-zone', 'user-agent', 'authorization', 'client-token'])
              key: expected[key]!},
          defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'));
        final RequestEnvelope request;
        if (item['name'] == 'audio-source') {
          request = NativeAudioFilesRequestPlan.forReadyTrackCacheMiss(
            uri: input['uri'] as String, country: input['country'] as String,
            catalogue: input['catalogue'] as String,
            nativeOwnerFlag51: input['nativeOwnerFlag51'] as bool,
            nativeOwnerFlag52: input['nativeOwnerFlag52'] as bool,
            nativeOwnerFlag53: input['nativeOwnerFlag53'] as bool).envelope(requests);
        } else {
          request = NativePlaylistTrackMetadataPlan.forFreshTracks(
            uris: (input['uris'] as List).cast<String>(), country: input['country'] as String,
            catalogue: input['catalogue'] as String,
            fetchAssociationsWithTrackV4Enabled: input['fetchAssociationsWithTrackV4Enabled'] as bool)
              .envelope(requests);
        }
        final protocol = protocols.select(request, http3FieldsVerified: true);
        final response = await (protocol == NativeHttpProtocol.http3 ? sender.send(request) : h2Sender.send(request));
        protocols.observeResponse(request.url, response.headers);
        expect(response.statusCode, 200);
        final received = jsonDecode(response.body) as Map;
        final ordered = {...expected, ':authority': authority, 'origin': 'https://$authority'};
        final pairs = received['headers'] as List;
        final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
        expect(fields.length, pairs.length);
        expect(fields, ordered, reason: item['name'] as String);
        if (!bootstrap) {
          final negotiated = (received['clientHttp3Settings'] as Map).cast<String, int>();
          final standardSettings = {for (final entry in negotiated.entries)
            if ((int.parse(entry.key) - 33) % 31 != 0) entry.key: entry.value};
          expect(standardSettings, connectionProfile['http3SettingsById'],
            reason: 'All97 original named H3 SETTINGS agree; NetLog does not prove wire order');
          final grease = negotiated.entries.where((entry) => (int.parse(entry.key) - 33) % 31 == 0).toList();
          expect(grease, hasLength(1), reason: 'Each of the97 original SETTINGS maps contains one GREASE setting');
          final greaseId = int.parse(grease.single.key);
          expect((greaseId - 33) ~/ 31, inInclusiveRange(0, 0xffffffff),
            reason: 'Pinned original public send-control source draws a uint32 for the reserved setting ID');
          expect(grease.single.value, inInclusiveRange(0, 0xffffffff),
            reason: 'The second original random draw is a uint32 value');
          final order = (received['clientHttp3SettingsSequence'] as List)
            .map((pair) => (pair as List)[0] as int).toList();
          expect([for (var index = 1; index < order.length; index++) order[index - 1] < order[index]],
            everyElement(isTrue), reason: 'Pinned original public HttpEncoder sorts complete settings by numeric ID');
          final controls = (received['clientControlFrames'] as List).cast<Map>()
            .where((frame) => frame['type'] != priorityFrameType).toList();
          expect(controls, hasLength(2),
            reason: 'Original public control stream sends SETTINGS then one GREASE frame per session');
          expect(controls[0]['type'], 4);
          final frameId = controls[1]['type'] as int;
          expect((frameId - 33) % 31, 0);
          final draw = (frameId - 33) ~/ 31;
          expect(draw, inInclusiveRange(0, 0xffffffff));
          expect(controls[1]['length'], draw % 4,
            reason: 'Original frame length is correlated with its uint32 type draw');
          verifyPriority(received, expected['priority']!);
          expect(received['clientQuicTransportParameters'], connectionProfile['quicTransportParameters'],
            reason: 'All101 original client transport-parameter diagnostics agree');
          expect(pairs, [for (final entry in ordered.entries) [entry.key, entry.value]],
            reason: '${item['name']}: original decoded H3 metadata sequence');
          h3Connection ??= received['connectionId'] as String;
          expect(received['connectionId'], h3Connection);
        }
        expect(received['bodyBase64'], base64Encode(hex.decode(item['bodyHex'] as String)),
          reason: item['name'] as String);
        expect(received['protocol'], bootstrap ? metadata['bootstrapObservation']['expectedProtocol'] : item['expectedProtocol']);
        bootstrap = false;
      }
      final libraryMetadata = jsonDecode(File('reverse-engineering/fixtures/native-library-metadata.json')
        .readAsStringSync()) as Map;
      final libraryHeaders = (libraryMetadata['originalRequestHeaders'] as Map).cast<String, String>();
      final libraryRequests = SpotifyRequests(baseUrl: 'https://$authority',
        inheritedHeaders: {for (final key in ['accept-language', 'app-platform', 'spotify-app-version',
          'time-zone', 'user-agent', 'authorization', 'client-token']) key: libraryHeaders[key]!},
        defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'));
      final collectionBindings = jsonDecode(File('reverse-engineering/fixtures/native-library-collection.json')
        .readAsStringSync()) as Map;
      for (final scenario in [...libraryMetadata['cases'] as List, ...collectionBindings['requests'] as List]) {
        final original = (scenario['request'] ?? scenario['original']) as Map;
        final expectedBytes = hex.decode(original['bodyHex'] as String);
        final request = scenario['uris'] is List
          ? NativeLibraryMetadataPlan(uris: (scenario['uris'] as List).cast<String>(),
              country: scenario['country'] as String, catalogue: scenario['catalogue'] as String)
                .envelope(libraryRequests)
          : nativeCollectionPageRequest(baseUrl: 'https://$authority', username: scenario['username'] as String,
              collectionSet: scenario['set'] as String, paginationToken: scenario['paginationToken'] as String,
              inheritedHeaders: {for (final key in ['accept-language', 'app-platform', 'spotify-app-version',
                'time-zone', 'user-agent', 'authorization', 'client-token']) key: libraryHeaders[key]!});
        final response = await sender.send(request);
        expect(response.statusCode, 200);
        final actual = jsonDecode(response.body) as Map;
        final pairs = actual['headers'] as List;
        final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
        final expected = {...libraryHeaders}..remove('content-encoding');
        if (scenario['uris'] is! List) expected.remove('client-feature-id');
        expected.addAll({':authority': authority, 'origin': 'https://$authority',
          ':method': original['method'] as String,
          ':path': Uri.parse(original['rawUrl'] as String).path,
          'content-length': '${expectedBytes.length}',
          for (final entry in (original['headers'] as Map).entries)
            if (entry.key != 'User-Agent') (entry.key as String).toLowerCase(): entry.value as String});
        expect(fields.length, pairs.length);
        expect(fields, expected, reason: 'Original Library ${scenario['uris'] ?? scenario['set']}');
        expect(actual['bodyBase64'], base64Encode(expectedBytes));
        expect(actual['protocol'], 'h3');
        verifyPriority(actual, expected['priority']!);
      }
      final playlists = jsonDecode(File('reverse-engineering/fixtures/native-playlist-h3.json')
        .readAsStringSync()) as Map;
      final artistPopular = jsonDecode(File('reverse-engineering/fixtures/native-artist-popular.json')
        .readAsStringSync()) as Map;
      for (final item in [...playlists['cases'] as List, ...artistPopular['cases'] as List]) {
        final policy = item['policy'] as Map, app = item['applicationHeaders'] as Map;
        Map? received;
        await NativePlaylistReadClient(baseUrl: 'https://$authority',
          policy: NativePlaylistReadPolicy(caller: PlaylistSyncCaller.valueOf(policy['caller'] as int)!,
            prioritized: policy['prioritized'] as bool, acceptListItems: policy['acceptListItems'] as bool,
            dsaMode: policy['dsaMode'] as bool, listPlayerEnabled: policy['listPlayerEnabled'] as bool,
            applyAutoLens: policy['applyAutoLens'] as bool),
          headers: NativePlaylistRequestHeaders(locale: app['locale'] as String,
            timeZone: app['timeZone'] as String, userAgent: app['userAgent'] as String),
          nativeHttpSend: (request) async {
            final response = await sender.send(RequestEnvelope(method: request.method, url: request.url,
              headers: {...request.headers, 'Authorization': 'Bearer fixture-access-token',
                'client-token': 'fixture-client-token'}, body: request.body,
              responseType: request.responseType));
            expect(response.statusCode, 200);
            received = jsonDecode(response.body) as Map;
            // Only outgoing bytes are checked. The echo is not playlist
            // protobuf content; the reply processor receives an empty body.
            return http.Response.bytes(const [], response.statusCode);
          }).readReply(item['canonicalUri'] as String);
        final actual = received!;
        expect(actual['headers'], [for (final pair in item['expectedHeaderSequence'] as List)
          [pair[0], pair[0] == ':authority' ? authority : pair[1]]], reason: item['name'] as String);
        expect(actual['bodyBase64'], base64Encode(hex.decode(item['bodyHex'] as String)));
        expect(actual['protocol'], item['expectedProtocol']);
        expect(actual['connectionId'], h3Connection);
        verifyPriority(actual, (item['expectedHeaders'] as Map)['priority'] as String);
      }
      for (final item in fixture['cases'] as List) {
        final expected = (item['expectedHeaders'] as Map).cast<String, String>();
        final inherited = {for (final key in ['accept-language', 'app-platform',
          'spotify-app-version', 'time-zone', 'user-agent', 'authorization', 'client-token'])
            key: expected[key]!};
        final fileId = hex.decode(item['fileIdHex'] as String);
        final RequestEnvelope request;
        final List<int> expectedBody;
        if (item['name'] == 'music-key') {
          final body = NativePlayPlayLicenseBody(cacheId: utf8.encode(originalBody['cacheId'] as String),
            timestampSeconds: originalBody['timestampSeconds'] as int,
            nativeInteractivity: originalBody['nativeInteractivity'] as int).encode();
          request = NativePlayPlayRequestPlan.musicKey(template: RequestEnvelope(method: 'GET',
            url: 'https://$authority/', headers: inherited, responseType: 'bytes'),
            fileId20: fileId, serializedBody: body).request;
          expectedBody = hex.decode(originalBody['bodyHex'] as String);
        } else {
          request = SpotifyRequests(baseUrl: 'https://$authority', inheritedHeaders: inherited,
            defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'))
              .storageResolve(fileId, storageMode: 0, audioFormat: 1);
          expectedBody = const [];
        }
        final response = await sender.send(request);
        expect(response.statusCode, 200);
        final received = jsonDecode(response.body) as Map;
        final pairs = received['headers'] as List;
        final ordered = {...expected, ':authority': authority,
          if (item['name'] == 'music-key') 'origin': 'https://$authority'};
        expect(pairs, [for (final entry in ordered.entries) [entry.key, entry.value]],
          reason: '${item['name']}: original decoded field sequence');
        expect(received['bodyBase64'], base64Encode(expectedBody), reason: item['name'] as String);
        expect(received['protocol'], 'h3');
        verifyPriority(received, expected['priority']!);
        expect(received['connectionId'], h3Connection,
          reason: 'Metadata, key and storage retain one actual QUIC connection');
        expect(received['peerQpackEncoderBytesSent'] as int, greaterThan(0),
          reason: 'The independent peer actually uses the advertised dynamic-table capacity');
        expect(received['peerQpackDecoderBytesReceived'] as int, greaterThan(0),
          reason: 'The peer receives valid client QPACK acknowledgements, not just an advertised capability');
      }
    });

    // This unique canary identity is computed by the real session-property
    // request owner. The ordinary file-key check cannot detect a wrong digest,
    // signed-property projection or canary body at this outgoing boundary.
    test('Original canary property owner URI body and native fields reach the H3 peer', () async {
      final captured = jsonDecode(File('reverse-engineering/evidence/native-playplay-actual-upload.json')
        .readAsStringSync()) as Map;
      final upload = (captured['cases'] as List).cast<Map>()
        .singleWhere((entry) => entry['sourceId'] == 2442);
      final originalHeaders = (upload['headers'] as Map).cast<String, String>();
      final fixture = jsonDecode(File('reverse-engineering/evidence/native-playplay-canary-concrete-provider.json')
        .readAsStringSync()) as Map;
      final authority = 'localhost:$port';
      final sender = NativeCefHttp3Transport(client: client(),
        defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
        options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
        context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']));
      addTearDown(sender.close);
      for (final row in fixture['cases'] as List) {
        final properties = row['propertiesReadThroughOriginalOwner'] as Map;
        final plan = NativePlayPlayCanaryRequest(template: RequestEnvelope(method: 'GET',
          url: 'https://$authority', responseType: 'bytes', headers: {
            for (final key in ['accept-language', 'app-platform', 'authorization',
              'spotify-app-version', 'time-zone', 'user-agent', 'client-token'])
                key: originalHeaders[key]!,
          }), productState: {for (final entry in properties.entries)
            if (entry.value is String) entry.key as String: entry.value as String},
          timestampSeconds: upload['timestampSeconds'] as int);
        final response = await sender.send(plan.request);
        expect(response.statusCode, 200);
        final actual = jsonDecode(response.body) as Map;
        final expected = {...originalHeaders, ':authority': authority,
          ':path': '/${row['originalRelativePath']}', 'origin': 'https://$authority'};
        expect(actual['headers'], [for (final entry in expected.entries) [entry.key, entry.value]],
          reason: row['name'] as String);
        expect(actual['bodyBase64'], base64Encode(hex.decode(row['originalBodyHex'] as String)),
          reason: row['name'] as String);
      }
    });

    // Expected fields derive from the independently proved common original
    // template binding, original map GET execution and original empty-GET
    // capture. This checks the real request plan at the outgoing H3 peer.
    test('Native image map shared template fields reach the H3 peer', () async {
      final evidence = jsonDecode(File('reverse-engineering/evidence/native-image-template-binding.json')
        .readAsStringSync()) as Map;
      final original = evidence['outgoingImageMap'] as Map;
      final template = original['suppliedCommonTemplate'] as Map;
      final authority = 'localhost:$port';
      final request = NativeImageProjectionMapRequestPlan.forEnabledLoading(
        template: RequestEnvelope(method: template['method'] as String,
          url: 'https://$authority/', headers: (template['headers'] as Map).cast<String, String>(),
          body: hex.decode(template['bodyHex'] as String)),
        configuration: const NativeImageResolveConfiguration(enableProjectionMapLoading: true,
          enableImageResolve: true, enableOnlineImageResolve: true,
          enableOnlineSizeImageResolve: true)).request;
      final sender = NativeCefHttp3Transport(client: client(),
        defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
        options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
        context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']));
      addTearDown(sender.close);
      final response = await sender.send(request);
      expect(response.statusCode, 200);
      final received = jsonDecode(response.body) as Map;
      final pairs = received['headers'] as List;
      final actual = {for (final pair in pairs) pair[0] as String: pair[1] as String};
      final expected = {...(original['expectedHttp3Headers'] as Map).cast<String, String>(),
        ':authority': authority};
      expect(actual.length, pairs.length, reason: 'No duplicate decoded fields');
      expect(actual, expected);
      expect(actual.length, 16, reason: 'Complete independently derived native GET profile');
      expect(actual.keys, isNot(contains(anyOf('origin', 'content-type', 'content-length',
        'pragma', 'cache-control'))));
      expect(received['bodyBase64'], base64Encode(hex.decode(original['expectedBodyHex'] as String)));
      expect(received['protocol'], 'h3');
    });

    test('Concurrent streams and a body exceeding flow control finish on one connection', () async {
      final transport = client();
      final payload = Uint8List.fromList(List.generate(2100000, (index) => index & 255));
      final responses = await Future.wait(List.generate(5, (index) async {
        final data = index == 0 ? payload : Uint8List.fromList([index, 0, 255]);
        final request = http.Request('POST', url('/echo?index=$index'))..bodyBytes = data;
        final response = await http.Response.fromStream(await transport.send(request));
        expect(response.statusCode, 200);
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        expect(decoded['bodyBase64'], base64Encode(data));
        return decoded;
      }));
      expect(responses.map((r) => r['streamId']).toSet(), hasLength(5));
      expect(responses.map((r) => r['connectionId']).toSet(), hasLength(1));
    });

    test('A certificate outside the supplied trust set fails during TLS', () async {
      await expectLater(client(trust: untrustedCertificate).get(url('/')),
        throwsA(isA<http.ClientException>().having((error) => error.message,
          'TLS failure', contains('QUIC receive failed (-10)'))));
    });

    test('A redirect is returned without following its remote location', () async {
      final response = await client().get(url('/redirect'));
      expect(response.statusCode, 302);
      expect(response.headers['location'], 'https://accounts.spotify.com/must-not-follow');
    });

    test('Stream cancellation allows another request on the connection', () async {
      final transport = client();
      final abort = Completer<void>();
      final result = transport.send(http.AbortableRequest('GET', url('/hang'),
        abortTrigger: abort.future));
      final assertion = expectLater(result, throwsA(isA<http.RequestAbortedException>()));
      abort.complete();
      await assertion;
      expect((await transport.get(url('/'))).statusCode, 200);
    });

    test('An already aborted request is rejected before finalization', () async {
      final abort = Completer<void>()..complete();
      final request = http.AbortableRequest('GET', url('/'), abortTrigger: abort.future);
      await expectLater(client().send(request), throwsA(isA<http.RequestAbortedException>()));
      expect(request.finalized, isFalse);
    });

    test('Abortion interrupts an unfinished request body', () async {
      final abort = Completer<void>();
      final request = http.AbortableStreamedRequest('POST', url('/'), abortTrigger: abort.future);
      request.sink.add([1]);
      final result = client().send(request);
      final assertion = expectLater(result.timeout(const Duration(milliseconds: 500)),
        throwsA(isA<http.RequestAbortedException>()));
      await Future<void>.delayed(Duration.zero);
      abort.complete();
      await assertion;
      await request.sink.close();
    });

    test('Abortion interrupts a handshake with a silent loopback peer', () async {
      final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      final packet = Completer<void>();
      final subscription = silent.listen((event) {
        if (event == RawSocketEvent.read && silent.receive() != null && !packet.isCompleted) {
          packet.complete();
        }
      });
      addTearDown(subscription.cancel);
      final abort = Completer<void>();
      final result = client(connectTimeout: const Duration(milliseconds: 600)).send(
        http.AbortableRequest('GET', Uri.parse('https://localhost:${silent.port}/'),
          abortTrigger: abort.future));
      final assertion = expectLater(result.timeout(const Duration(milliseconds: 300)),
        throwsA(isA<http.RequestAbortedException>()));
      await packet.future.timeout(const Duration(seconds: 1));
      abort.complete();
      await assertion;
    });

    test('Client close cancels a shared handshake and releases its UDP socket', () async {
      final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      final initial = Completer<Datagram>();
      final subscription = silent.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = silent.receive()) != null) {
          if (!initial.isCompleted) initial.complete(packet);
        }
      });
      addTearDown(subscription.cancel);
      final transport = client(connectTimeout: const Duration(seconds: 2));
      final target = Uri.parse('https://localhost:${silent.port}/');
      final outcomes = List.generate(2, (_) => transport.get(target).then<Object?>(
        (response) => response, onError: (Object error) => error));
      final packet = await initial.future.timeout(const Duration(seconds: 1));
      expect(packet.data, isNotEmpty);
      await expectLater(RawDatagramSocket.bind(InternetAddress.loopbackIPv4,
        packet.port, reuseAddress: false), throwsA(isA<SocketException>()));
      transport.close();
      Future<void> checkSocketRelease() async {
        final elapsed = Stopwatch()..start();
        SocketException? occupied;
        // Dart dispatches close to its event handler; actual descriptor release is asynchronous.
        while (elapsed.elapsed < const Duration(milliseconds: 500)) {
          try {
            final released = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4,
              packet.port, reuseAddress: false);
            released.close();
            return;
          } on SocketException catch (error) {
            if (error.osError?.errorCode != 48) rethrow; // Darwin EADDRINUSE only.
            occupied = error;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail('Client UDP port ${packet.port} stayed bound for 500ms: $occupied');
      }
      final callers = Future.wait(outcomes).timeout(const Duration(milliseconds: 500))
        .then<void>((results) => expect(results,
          everyElement(isA<http.ClientException>().having((error) => error.message,
            'close', contains('closed')))));
      await Future.wait([callers, checkSocketRelease()]);
    });

    test('Client close interrupts initial setup and an unfinished body without egress', () async {
      final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(silent.close);
      var packets = 0;
      final subscription = silent.listen((event) {
        if (event != RawSocketEvent.read) return;
        while (silent.receive() != null) { packets++; }
      });
      addTearDown(subscription.cancel);
      for (final unfinishedBody in [false, true]) {
        final transport = client();
        final target = Uri.parse('https://localhost:${silent.port}/');
        final request = unfinishedBody ? http.StreamedRequest('POST', target) : http.Request('GET', target);
        final result = transport.send(request);
        if (unfinishedBody) await Future<void>.delayed(Duration.zero);
        transport.close();
        try {
          await expectLater(result.timeout(const Duration(milliseconds: 500)),
            throwsA(isA<http.ClientException>().having((error) => error.message,
              'close', contains('closed'))));
        } finally {
          if (request is http.StreamedRequest) unawaited(request.sink.close());
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(packets, 0);
    });

    test('A closed peer connection is evicted before the next request', () async {
      final transport = client();
      final before = jsonDecode((await transport.get(url('/close'))).body) as Map;
      await Future<void>.delayed(const Duration(seconds: 1));
      final after = jsonDecode((await transport.get(url('/'))).body) as Map;
      expect(after['connectionId'], isNot(before['connectionId']));
    });

    test('An early response stops its upload without failing concurrent streams', () async {
      final transport = client();
      final before = jsonDecode((await transport.get(url('/'))).body) as Map;
      final request = http.Request('POST', url('/early-response'))..bodyBytes = Uint8List(3000000);
      final responses = await Future.wait([
        transport.send(request).then(http.Response.fromStream), transport.get(url('/')),
      ]);
      expect(responses[0].statusCode, 413);
      expect(responses[0].bodyBytes, isEmpty);
      expect((jsonDecode(responses[1].body) as Map)['connectionId'], before['connectionId']);
      final after = jsonDecode((await transport.get(url('/'))).body) as Map;
      expect(after['connectionId'], before['connectionId']);
    });

    test('Malformed and mismatched response lengths fail only their stream', () async {
      final transport = client();
      final before = jsonDecode((await transport.get(url('/'))).body) as Map;
      for (final path in ['truncated', 'excess', 'invalid', 'conflicting']) {
        await expectLater(transport.get(url('/length/$path')), throwsA(isA<http.ClientException>()
          .having((error) => error.message, 'response integrity', contains('content-length'))));
        final after = jsonDecode((await transport.get(url('/'))).body) as Map;
        expect(after['connectionId'], before['connectionId']);
      }
      final repeated = await transport.send(http.Request('GET', url('/length/repeated')));
      expect(repeated.contentLength, 1);
      expect((await http.Response.fromStream(repeated)).body, 'x');
    });

    test('Representation lengths on HEAD and 304 do not require response content', () async {
      final transport = client();
      for (final (method, path, status) in [
        ('HEAD', '/representation-length', 200), ('GET', '/not-modified', 304),
        ('GET', '/no-content', 204),
      ]) {
        final streamed = await transport.send(http.Request(method, url(path)));
        expect(streamed.contentLength, status == 204 ? isNull : 37);
        final response = await http.Response.fromStream(streamed);
        expect(response.statusCode, status);
        expect(response.bodyBytes, isEmpty);
      }
      await expectLater(transport.get(url('/forbidden-body')), throwsA(isA<http.ClientException>()));
    });

    test('A peer that never responds reaches the request deadline', () async {
      await expectLater(client(timeout: const Duration(milliseconds: 100)).get(url('/hang')),
        throwsA(isA<http.ClientException>().having((error) => error.message,
          'deadline', equals('HTTP/3 request timed out'))));
    });

    test('An HTTP/3 stream reset completes the caller with an error', () async {
      await expectLater(client().get(url('/reset')),
        throwsA(isA<http.ClientException>().having((error) => error.message,
          'reset', equals('HTTP/3 stream reset'))));
    });

    test('Remote origins are rejected before the request is finalized', () async {
      for (final target in ['https://api-partner.spotify.com/pathfinder/v2/query',
        'https://127.0.0.1:$port/']) {
        final request = http.Request('POST', Uri.parse(target));
        await expectLater(client().send(request), throwsA(isA<http.ClientException>()
          .having((error) => error.message, 'admission', startsWith('Remote HTTP/3 transport is unverified'))));
        expect(request.finalized, isFalse);
      }
    });
  }, skip: Abi.current() != Abi.macosArm64);
}
