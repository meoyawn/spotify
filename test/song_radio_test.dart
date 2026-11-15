import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/app/app.dart';
import 'package:spotify_flutter/app/navigation.dart';
import 'package:spotify_flutter/entities/models.dart';
import 'package:spotify_flutter/entities/repository.dart';
import 'package:spotify_flutter/entities/song_radio.dart';
import 'package:spotify_flutter/protocol/native_renderer_http_request.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  group('Song radio', () {
    test('Original-executed permission, GET, preflight and first-playlist contract', () async {
      final fixture = jsonDecode(File('reverse-engineering/fixtures/native-song-radio.json').readAsStringSync()) as Map;
      for (final item in fixture['cases'] as List) {
        final input = item['input'] as Map;
        expect(songRadioAllowed((input['product'] as Map? ?? {}).cast<String, String>()), item['allowed'],
          reason: input['name'] as String);
        if (item['application'] == null) continue;
        final profile = NativeRendererSearchProfile(locale: input['locale'] as String);
        final cancellation = CancellationToken();
        var sends = 0;
        final playlist = await resolveSongRadioPlaylist(input['uri'] as String,
          builder: SpotifyRequestBuilder(locale: input['locale'] as String, market: 'from_token',
            accessToken: 'fixture-access-token', globalHeaders: NativeRendererSearchProfile.globalHeaders),
          cancellationToken: cancellation,
          send: (request) async {
            sends++;
            expect(request.cancellationToken, same(cancellation));
            expect(request.toJson(), item['application']);
            final plan = profile.prepareSongRadio(request, clientToken: 'fixture-client-token');
            final fields = {':method': plan.method, ':authority': plan.authority,
              ':scheme': 'https', ':path': plan.rawTarget, ...plan.headers};
            expect(fields, item['expected']);
            expect(fields.keys.toList(), (item['expected'] as Map).keys.toList());
            final preflight = profile.preparePreflight(plan);
            final preflightFields = {':method': preflight.method, ':authority': preflight.authority,
              ':scheme': 'https', ':path': preflight.rawTarget, ...preflight.headers};
            expect(preflightFields, item['expectedPreflight']);
            expect(preflightFields.keys.toList(), (item['expectedPreflight'] as Map).keys.toList());
            expect(plan.body, isEmpty);
            return (status: 200, body: item['response']);
          });
        expect(sends, 1);
        expect(DesktopRoute.content(playlist).location, (item['navigations'] as List).single);
        cancellation.cancel();
      }
    });

    test('Unavailable, throttled and invalid responses never produce a playable destination', () async {
      for (final response in <({int status, Object? body})>[
        (status: 403, body: null), (status: 404, body: null), (status: 429, body: null),
        (status: 200, body: {'mediaItems': []}),
        (status: 200, body: {'mediaItems': [{'uri': 'spotify:ad:0000000000000000000001'}]}),
      ]) {
        await expectLater(resolveSongRadioPlaylist('spotify:track:0000000000000000000001',
          builder: SpotifyRequestBuilder(), send: (_) async => response),
          throwsA(response.status == 200 ? isA<FormatException>() : isA<StateError>()));
      }
      var sends = 0;
      await expectLater(resolveSongRadioPlaylist('spotify:ad:0000000000000000000001',
        builder: SpotifyRequestBuilder(), send: (_) async { sends++; return (status: 200, body: null); }),
        throwsFormatException);
      expect(sends, 0);
    });

    testWidgets('Song menu cancels abandoned radio, opens the resolved playlist and leaves playback to Play', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _RadioEntities();
      final requests = <({String uri, CancellationToken token, Completer<String> result})>[];
      var plays = 0;
      await tester.pumpWidget(SpotifyDesktopApp(initialLocation: '/track/0000000000000000000001',
        entityRepository: repository, onEntityPlay: (_) => plays++,
        playbackBuilder: (_, _, _) => const SizedBox.shrink(),
        songRadioResolver: (uri, {cancellationToken}) {
          final result = Completer<String>();
          requests.add((uri: uri, token: cancellationToken!, result: result));
          return result.future;
        }));
      await tester.pumpAndSettle();
      final router = tester.widget<MaterialApp>(find.byType(MaterialApp)).routerDelegate! as DesktopRouter;
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go to song radio'));
      await tester.pumpAndSettle();
      expect(requests.single.uri, 'spotify:track:0000000000000000000001');
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(tester.widget<PopupMenuItem<String>>(find.ancestor(of: find.text('Opening song radio…'),
        matching: find.byType(PopupMenuItem<String>))).enabled, isFalse);
      await tester.tapAt(const Offset(1300, 800));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      router.go(DesktopRoute.content('spotify:track:0000000000000000000002'));
      await tester.pumpAndSettle();
      expect(requests.first.token.isCancelled, isTrue);
      requests.first.result.complete('spotify:playlist:0000000000000000000001');
      await tester.pumpAndSettle();
      expect(router.route.location, '/track/0000000000000000000002');
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Go to song radio'));
      await tester.pumpAndSettle();
      requests.last.result.complete('spotify:playlist:0000000000000000000002');
      await tester.pumpAndSettle();
      expect(router.route.location, '/playlist/0000000000000000000002');
      expect(find.text('Radio playlist'), findsOneWidget);
      expect(plays, 0);
      await tester.tap(find.byTooltip('Play Radio playlist'));
      await tester.pumpAndSettle();
      expect(plays, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, semanticsEnabled: false);
  });
}

class _RadioEntities implements EntityRepository {
  @override Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async => EntityPage(
    details: EntityDetails.fromJson({'uri': uri, 'type': uri.split(':')[1],
      'name': uri.startsWith('spotify:playlist:') ? 'Radio playlist' : 'Seed song',
      'nrTracks': 1, 'canRequestPlayback': true}),
    tracks: EntityTrackPage(offset: 0, limit: 50, totalLength: 1, rows: [EntityRow.fromJson({
      'type': 'track', 'uri': 'spotify:track:0000000000000000000001',
      'name': 'Seed song', 'canRequestPlayback': true,
    })]));

  @override Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit,
      CancellationToken? cancellationToken}) async => EntityTrackPage(offset: offset, limit: limit ?? 50, totalLength: 1);
}
