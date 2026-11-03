import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:convert/convert.dart' show hex;
import 'package:spotify_flutter/home/native_recent_contexts.dart';
import 'package:spotify_flutter/library/native_collection_read_client.dart';
import 'package:spotify_flutter/library/native_metadata_client.dart';
import 'package:spotify_flutter/playback/native_audio_files_request.dart';
import 'package:spotify_flutter/playback/native_playplay_body.dart';
import 'package:spotify_flutter/playback/native_playplay_request.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/playlist_service/native_read_client.dart';
import 'package:spotify_flutter/playlist_service/native_rootlist_read_client.dart';
import 'package:spotify_flutter/protocol/generated/playlist_sync_reason.pb.dart';
import 'package:spotify_flutter/protocol/native_cef_context.dart';
import 'package:spotify_flutter/protocol/native_cef_http2_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('Dart H2 sends original CEF and native app fields target and body', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-cef-h2-loopback.json').readAsStringSync()) as Map;
    final libraryWriteFixture = jsonDecode(File('reverse-engineering/fixtures/native-cef-library-write-h2.json').readAsStringSync()) as Map;
    final nativeContextFixture = jsonDecode(File('reverse-engineering/fixtures/native-cef-native-app-context.json').readAsStringSync()) as Map;
    final playlistFixture = jsonDecode(File('reverse-engineering/fixtures/native-playlist-read.json').readAsStringSync()) as Map;
    final artistPopularFixture = jsonDecode(File('reverse-engineering/fixtures/native-artist-popular.json').readAsStringSync()) as Map;
    final rootlistFixture = jsonDecode(File('reverse-engineering/fixtures/native-rootlist-read.json').readAsStringSync()) as Map;
    final recentFixture = jsonDecode(File('reverse-engineering/fixtures/native-recent-contexts.json').readAsStringSync()) as Map;
    final initialSettings = jsonDecode(File('reverse-engineering/evidence/native-http2-initial-settings.json').readAsStringSync()) as Map;
    final priorityEvidence = jsonDecode(File('reverse-engineering/evidence/native-http2-priority.json').readAsStringSync()) as Map;
    void checkPriority(Map capture) {
      final priority = capture['headersPriority'] as Map?;
      final profile = priorityEvidence['profiles']['native'] as Map;
      expect({'hasPriority': priority != null, 'weight': priority?['weight'], 'exclusive': priority?['exclusive']},
        {for (final name in ['hasPriority', 'weight', 'exclusive']) name: profile[name]},
        reason: 'Original native H2 HEADERS priority section');
    }
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/native_cef_h2_peer.py', '--defer-settings-until-request']);
    final errors = <String>[];
    final stderr = peer.stderr.transform(utf8.decoder).listen(errors.add);
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    NativeCefHttp2Transport? sender;
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map;
      final port = ready['port'] as int, authority = 'localhost:$port';
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ready['certificate'] as String);
      final native = fixture['nativeOptions'] as Map;
      sender = NativeCefHttp2Transport(defaults: const NativeHttpDefaults(userAgent: ''),
        options: NativeCefOptions(adapterOption80: 0),
        adapterUserAgent: (fixture['cases'] as List).first['input']['adapterUserAgent'] as String,
        context: NativeCefContext.fromLocale(selectedLocale: native['selectedLocale'] as String,
          appleLanguages: (native['suppliedAppleLanguages'] as List).cast<String>()), securityContext: trust);
      var initialRequest = true;
      for (final item in [...fixture['cases'] as List, ...libraryWriteFixture['cases'] as List,
          ...nativeContextFixture['cases'] as List]) {
        final input = item['input'] as Map, expected = item['result'] as Map;
        final rawTarget = (expected['headers'] as List).firstWhere((pair) => pair[0] == ':path')[1] as String;
        final response = await sender.send(RequestEnvelope(method: input['method'] as String,
          url: 'https://$authority$rawTarget',
          headers: {for (final pair in input['headers'] as List) pair[0] as String: pair[1] as String},
          body: base64Decode(input['bodyBase64'] as String)));
        expect(response.statusCode, 200);
        expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final actual = (jsonDecode(output.current) as Map)['capture'] as Map;
        checkPriority(actual);
        final expectedHeaders = [for (final pair in expected['headers'] as List)
          [pair[0], pair[0] == ':authority' ? authority : pair[0] == 'origin' ? 'https://$authority' : pair[1]]];
        expect({'alpn': actual['alpn'], 'headers': actual['headers'], 'bodyBase64': actual['bodyBase64']},
          {'alpn': expected['alpn'], 'headers': expectedHeaders, 'bodyBase64': expected['bodyBase64']},
          reason: item['name'] as String);
        // Original fresh H2 sessions send the request before the server's
        // initial SETTINGS. The peer withholds its preface until HEADERS or
        // a short fallback deadline; request bytes still have the same owner.
        if (initialRequest) {
          expect(actual['clientInitialSettings'], initialSettings['settingsSequence'],
            reason: 'Original connection SETTINGS values and order');
          expect(actual['clientInitialConnectionWindowDelta'], initialSettings['initialConnectionWindowDelta'],
            reason: 'Original connection receive window');
          expect(actual['clientStartupOrder'], initialSettings['startupOrder']);
          expect(actual['headersBeforeServerSettings'], isTrue,
            reason: 'The original request does not wait for initial server SETTINGS');
          initialRequest = false;
        }
      }
      sender.close();
      for (final item in [...playlistFixture['cases'] as List, ...rootlistFixture['cases'] as List,
          ...artistPopularFixture['cases'] as List, ...recentFixture['cases'] as List]) {
        final app = item['applicationHeaders'] as Map;
        sender = NativeCefHttp2Transport(defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
          options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
          context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']),
          securityContext: trust);
        final transport = sender;
        final nativeHeaders = NativePlaylistRequestHeaders(locale: app['locale'] as String,
          timeZone: app['timeZone'] as String, userAgent: app['userAgent'] as String);
        final nativeSend = (RequestEnvelope request) => transport.send(RequestEnvelope(method: request.method,
            url: request.url, body: request.body, responseType: request.responseType,
            headers: {...request.headers, 'Authorization': 'Bearer fixture-access-token',
              'client-token': 'fixture-client-token'}));
        // The peer returns empty bytes; no server-content/decoration assertion
        // is made. The request passes through the real read client and sender.
        if (item['recentContexts'] == true) {
          await NativeRecentContextsClient(baseUrl: 'https://$authority',
            inheritedHeaders: (item['inheritedHeaders'] as Map).cast<String, String>(),
            nowMicroseconds: () => 0, send: nativeSend).read();
        } else if (item['username'] is String) {
          await NativeRootlistReadClient(baseUrl: 'https://$authority',
            username: item['username'] as String, headers: nativeHeaders, nativeHttpSend: nativeSend)
              .readReply(from: item['from'] as int, length: item['length'] as int);
        } else {
          final policy = item['policy'] as Map;
          await NativePlaylistReadClient(baseUrl: 'https://$authority', headers: nativeHeaders,
            policy: NativePlaylistReadPolicy(caller: PlaylistSyncCaller.valueOf(policy['caller'] as int)!,
              prioritized: policy['prioritized'] as bool, acceptListItems: policy['acceptListItems'] as bool,
              dsaMode: policy['dsaMode'] as bool, listPlayerEnabled: policy['listPlayerEnabled'] as bool,
              applyAutoLens: policy['applyAutoLens'] as bool), nativeHttpSend: nativeSend)
                .readReply(item['canonicalUri'] as String);
        }
        expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final actual = (jsonDecode(output.current) as Map)['capture'] as Map;
        checkPriority(actual);
        final pairs = actual['headers'] as List;
        final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
        expect(fields.length, pairs.length);
        expect(fields, {...((item['expected'] as Map)['headers'] as Map), ':authority': authority},
          reason: item['name'] as String);
        expect(actual['bodyBase64'], '', reason: item['name'] as String);
        expect(actual['alpn'], 'h2');
        sender.close();
      }
      {
        // Exercise original dependency decisions at the outgoing boundary:
        // keep stream1 half-closed, finish stream3, then stream5 must depend
        // on stream1. After both finish, stream7 must depend on the root.
        // The independent original routine supplies all expected metadata.
        final trace = (priorityEvidence['creationTraceScenarios'] as List)
          .firstWhere((item) => item['name'] == 'native-live')['steps'] as List;
        final creates = trace.where((step) => step['action'] == 'create').toList();
        sender = NativeCefHttp2Transport(defaults: const NativeHttpDefaults(userAgent: ''),
          options: NativeCefOptions(adapterOption80: 0),
          adapterUserAgent: (fixture['cases'] as List).first['input']['adapterUserAgent'] as String,
          context: NativeCefContext.fromLocale(selectedLocale: native['selectedLocale'] as String,
            appleLanguages: (native['suppliedAppleLanguages'] as List).cast<String>()), securityContext: trust);
        final source = (fixture['cases'] as List).first as Map;
        final input = source['input'] as Map, expected = source['result'] as Map;
        final target = (expected['headers'] as List).firstWhere((pair) => pair[0] == ':path')[1] as String;
        final originalRequest = RequestEnvelope(method: input['method'] as String,
          url: 'https://$authority$target',
          headers: {for (final pair in input['headers'] as List) pair[0] as String: pair[1] as String},
          body: base64Decode(input['bodyBase64'] as String));
        final originalHeaders = [for (final pair in expected['headers'] as List)
          [pair[0], pair[0] == ':authority' ? authority : pair[0] == 'origin' ? 'https://$authority' : pair[1]]];
        Future<void> control(String command) async {
          peer.stdin.writeln(command);
          await peer.stdin.flush();
          expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
          expect(jsonDecode(output.current), {'control': command});
        }
        int? connectionId;
        Future<void> checkTraceRequest(int index) async {
          expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
          final capture = (jsonDecode(output.current) as Map)['capture'] as Map;
          expect(capture['headers'], originalHeaders);
          expect(capture['bodyBase64'], expected['bodyBase64']);
          expect(capture['headersPriority'], creates[index]['originalOutput']);
          expect(capture['streamId'], creates[index]['streamId']);
          connectionId ??= capture['connectionId'] as int;
          expect(capture['connectionId'], connectionId);
        }
        await control('hold-next');
        final held = await sender.sendStream(originalRequest);
        expect(held.statusCode, 200);
        await checkTraceRequest(0);
        final heldBody = held.stream.drain<void>();
        expect((await sender.send(originalRequest)).statusCode, 200);
        await checkTraceRequest(1);
        await control('hold-next');
        final last = await sender.sendStream(originalRequest);
        expect(last.statusCode, 200);
        await checkTraceRequest(2);
        final lastBody = last.stream.drain<void>();
        await control('release-responses');
        await Future.wait([heldBody, lastBody]);
        expect((await sender.send(originalRequest)).statusCode, 200);
        await checkTraceRequest(3);
        sender.close();
      }
      // Compose the independent original one-Track prefetch producer bytes
      // with the actual original metadata app-field profile. The latter's
      // caller is replaced explicitly by original prefetch producer output;
      // no captured live prefetch request is claimed.
      final metadataEvidence = jsonDecode(File('reverse-engineering/evidence/native-metadata-netlog-headers.json').readAsStringSync()) as Map;
      final capturedMetadata = (metadataEvidence['profiles'] as List).firstWhere((entry) =>
        entry['headers']['client-feature-id'] == 'track_metadata_loader' &&
        !(entry['headers'] as Map).containsKey('content-encoding')) as Map;
      final appHeaders = (capturedMetadata['headers'] as Map).cast<String, String>();
      final originalPrefetch = (jsonDecode(File('reverse-engineering/fixtures/native-audio-files-requests.json').readAsStringSync()) as Map)['cases'][0] as Map;
      final originalRequest = originalPrefetch['request'] as Map;
      final expectedBody = hex.decode(originalRequest['bodyHex'] as String);
      sender = NativeCefHttp2Transport(defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
        options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
        context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']),
        securityContext: trust);
      final request = NativeAudioFilesRequestPlan.forReadyTrackCacheMiss(
        uri: originalPrefetch['uri'] as String, country: originalPrefetch['country'] as String,
        catalogue: originalPrefetch['catalogue'] as String,
        nativeOwnerFlag51: originalPrefetch['nativeOwnerFlag51'] as bool,
        nativeOwnerFlag52: originalPrefetch['nativeOwnerFlag52'] as bool,
        nativeOwnerFlag53: originalPrefetch['nativeOwnerFlag53'] as bool).envelope(
          SpotifyRequests(baseUrl: 'https://$authority', defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
            inheritedHeaders: {for (final key in ['accept-language', 'app-platform', 'spotify-app-version', 'time-zone', 'user-agent'])
              key: appHeaders[key]!, 'Authorization': 'Bearer fixture-access-token', 'client-token': 'fixture-client-token'}));
      await sender.send(request);
      expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
      final actualMetadata = (jsonDecode(output.current) as Map)['capture'] as Map;
      checkPriority(actualMetadata);
      final pairs = actualMetadata['headers'] as List;
      final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
      expect(fields.length, pairs.length);
      expect(fields, {...appHeaders, ':authority': authority, 'origin': 'https://$authority',
        'client-feature-id': originalRequest['headers']['client-feature-id'], 'content-length': '${expectedBody.length}'});
      expect(actualMetadata['bodyBase64'], base64Encode(expectedBody));
      expect(actualMetadata['alpn'], 'h2');
      expect(actualMetadata['headersBeforeServerSettings'], isTrue);
      sender.close();
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
        sender = NativeCefHttp2Transport(defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
          options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
          context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']),
          securityContext: trust);
        await sender.send(request);
        expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final actual = (jsonDecode(output.current) as Map)['capture'] as Map;
        checkPriority(actual);
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
        expect(actual['alpn'], 'h2');
        sender.close();
      }
      final streaming = jsonDecode(File('reverse-engineering/fixtures/native-streaming-http-fields.json').readAsStringSync()) as Map;
      final originalMusicBody = (jsonDecode(File('reverse-engineering/fixtures/native-playplay-body.json').readAsStringSync()) as Map)['cases'][0] as Map;
      for (final item in streaming['cases'] as List) {
        final expected = (item['expectedHeaders'] as Map).cast<String, String>();
        final fileId = hex.decode(item['fileIdHex'] as String);
        final inherited = {for (final key in ['accept-language', 'app-platform', 'spotify-app-version',
          'time-zone', 'user-agent', 'authorization', 'client-token']) key: expected[key]!};
        final RequestEnvelope request;
        final List<int> expectedBytes;
        if (item['name'] == 'music-key') {
          final body = NativePlayPlayLicenseBody(cacheId: utf8.encode(originalMusicBody['cacheId'] as String),
            timestampSeconds: originalMusicBody['timestampSeconds'] as int,
            nativeInteractivity: originalMusicBody['nativeInteractivity'] as int).encode();
          request = NativePlayPlayRequestPlan.musicKey(template: RequestEnvelope(method: 'GET',
            url: 'https://$authority/', headers: inherited, responseType: 'bytes'),
            fileId20: fileId, serializedBody: body).request;
          expectedBytes = hex.decode(originalMusicBody['bodyHex'] as String);
        } else {
          request = SpotifyRequests(baseUrl: 'https://$authority', inheritedHeaders: inherited,
            defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'))
              .storageResolve(fileId, storageMode: 0, audioFormat: 1);
          expectedBytes = const [];
        }
        sender = NativeCefHttp2Transport(defaults: const NativeHttpDefaults(userAgent: 'inert-fallback-UA'),
          options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: 'inert-adapter-UA',
          context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']),
          securityContext: trust);
        await sender.send(request);
        expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final actual = (jsonDecode(output.current) as Map)['capture'] as Map;
        checkPriority(actual);
        final pairs = actual['headers'] as List;
        final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
        expect(fields.length, pairs.length);
        expect(fields, {...expected, ':authority': authority,
          if (item['name'] == 'music-key') 'origin': 'https://$authority'}, reason: item['name'] as String);
        expect(actual['bodyBase64'], base64Encode(expectedBytes), reason: item['name'] as String);
        expect(actual['alpn'], 'h2');
        sender.close();
      }
    } finally {
      sender?.close();
      peer.stdin.writeln('stop');
      await peer.stdin.close();
      await output.cancel();
      await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () { peer.kill(); return -1; });
      await stderr.cancel();
      expect(errors, isEmpty, reason: 'Independent H2 peer diagnostics');
    }
  });
}
