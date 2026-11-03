import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/client.dart';
import 'package:spotify_flutter/playback/controller.dart';
import 'package:spotify_flutter/protocol/generated/es_restrictions.pb.dart';
import 'package:spotify_flutter/protocol/generated/es_response_with_reasons.pb.dart';
import 'package:spotify_flutter/playback/models.dart';
import 'package:spotify_flutter/playback/requests.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';

List<int> _unhex(String value) => [for (var i = 0; i < value.length; i += 2)
  int.parse(value.substring(i, i + 2), radix: 16)];
String _hex(List<int> value) => value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Future<void> _command(ContextPlayerClient client, String name) => switch (name) {
  'pause with origin' => client.pause(const PlaybackOrigin(featureIdentifier: 'fixture', viewURI: 'spotify:fixture')),
  'resume without origin' => client.resume(),
  'skip previous permits seeking' => client.skipPrevious(),
  'skip next without a specific track' || 'skip next missing queue match omits track' => client.skipNext(),
  'skip next uses matching queued track metadata' => client.skipTo(const PlaybackItemReference(
    'spotify:track:fixture', uid: 'uid-2', metadata: {'title': '雪'})),
  'seek floors positive milliseconds and binds playback id' => client.seekTo(1234.9, onlyForPlaybackId: [0, 127, 255]),
  'seek zero restarts the reported playback' => client.seekTo(0, onlyForPlaybackId: [0, 127, 255]),
  'relative seek floors negative milliseconds' => client.seekBy(-1234.1),
  'shuffle false omits the scalar and retains logging' => client.setShuffle(false),
  'shuffle true' => client.setShuffle(true),
  'repeat none includes false wrappers' => client.setRepeat(PlaybackRepeat.none),
  'repeat context' => client.setRepeat(PlaybackRepeat.context),
  'repeat track' => client.setRepeat(PlaybackRepeat.track),
  'speed is a protobuf float' => client.setSpeed(1.25),
  'play lazy album context and origin' => client.play(const PlaybackContext('spotify:album:fixture', metadata: {'fixture': '雪'}),
    const PlaybackOrigin(featureIdentifier: 'search', viewURI: 'spotify:search:fixture')),
  'play explicit pages, skip, overrides and logging' => client.play(
    const PlaybackContext('spotify:album:fixture', pages: [PlaybackPage(uri: 'spotify:page:fixture',
      items: [PlaybackItemReference('spotify:track:fixture', uid: 'uid-1', metadata: {'fixture': '雪'})], metadata: {'page': 'one'})]),
    const PlaybackOrigin(featureIdentifier: 'fixture', featureVersion: 'v1', referrerIdentifier: 'ref',
      externalReferrer: 'ext', restrictionIdentifier: 'restriction'),
    options: const PlaybackOptions(skipTo: PlaybackSkipTarget(pageURL: 'page://fixture', pageIndex: 0,
      index: 2, uid: 'uid-1', uri: 'spotify:track:fixture'), seekTo: 33, shuffle: false,
      repeat: PlaybackRepeat.track, playbackSpeed: 1.5, modes: {'context_enhancement': 'NONE'},
      paused: true, alwaysPlaySomething: true, sessionId: 'session-fixture', playbackId: [65, 81, 73, 68],
      loggingParams: PlaybackLogging(interactionId: 'interaction', pageInstanceId: 'page-instance', commandId: 'command'))),
  'show defaults disable shuffle and repeat while URL pages replace page_uri' => client.play(
    PlaybackContext('spotify:show:HHHHHHHHHHHHHHHHHHHHHH', pages: const [PlaybackPage(url: 'fixture://page',
      metadata: {'page_uri': 'stale', 'keep': 'yes'})], restrictions: Restrictions(
        disallowPausingReasons: ['ad_disallow'], disallowTransferringPlaybackReasons: ['ignored'])),
    const PlaybackOrigin()),
  'already paused is an accepted response' || 'other forbidden reason rejects' ||
  'combined already paused reasons still reject' || 'future command error codes reject' => client.pause(),
  _ => throw StateError('Unmapped original oracle scenario: $name'),
};

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/playback-oracle.json').readAsStringSync()) as Map<String, dynamic>;
  group('Original ContextPlayer command boundary', () {
    for (final scenario in (fixture['commandScenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () async {
        final calls = <Map<String, Object?>>[];
        final dispatcher = EsperantoDispatcher();
        final expectedCalls = (scenario['calls'] as List).cast<Map<String, dynamic>>();
        dispatcher.register(ContextPlayerClient.serviceId, EsperantoService(single: {
          for (final call in expectedCalls) call['method'] as String: (request) {
            calls.add({'service': ContextPlayerClient.serviceId, 'method': call['method'], 'payloadHex': _hex(request)});
            return [8, scenario['error'] as int? ?? 0,
              if ((scenario['reasons'] as String?)?.isNotEmpty == true) ...[
                18, utf8.encode(scenario['reasons'] as String).length, ...utf8.encode(scenario['reasons'] as String)]];
          },
        }));
        final client = ContextPlayerClient(dispatcher, nowMilliseconds: () => fixture['nowMilliseconds'] as int);
        if (scenario['errorMessage'] == null) {
          await _command(client, scenario['name'] as String);
        } else {
          await expectLater(_command(client, scenario['name'] as String),
            throwsA(isA<PlaybackCommandException>().having((error) => error.message, 'original message', scenario['errorMessage'])));
        }
        expect(calls, expectedCalls);
      });
    }
  });

  group('Original ContextPlayer streams', () {
    test('matches original subscription bytes, projections, errors and event order', () async {
      final dispatcher = EsperantoDispatcher();
      final frames = StreamController<List<int>>(sync: true);
      final failures = StreamController<List<int>>(sync: true);
      final subscriptions = <Map<String, Object?>>[];
      dispatcher.register(ContextPlayerClient.serviceId, EsperantoService(streaming: {
        'GetState': (payload) {
          subscriptions.add({'service': ContextPlayerClient.serviceId, 'method': 'GetState', 'payloadHex': _hex(payload)});
          return frames.stream;
        },
        'GetError': (payload) {
          subscriptions.add({'service': ContextPlayerClient.serviceId, 'method': 'GetError', 'payloadHex': _hex(payload)});
          return failures.stream;
        },
      }));
      final controller = PlaybackController(ContextPlayerClient(dispatcher));
      final events = <Map<String, Object?>>[];
      controller.states.listen((state) => events.add({'type': 'update', 'state': state.toJson()}));
      controller.wraparounds.listen((data) => events.add({'type': 'context_wraparound', 'data': data}));
      controller.errors.listen((error) => events.add({'type': 'error', 'error': (error as PlaybackServiceException).toJson()}));
      controller.start();
      expect(subscriptions, fixture['subscriptions']);
      for (final scenario in (fixture['stateScenarios'] as List).cast<Map<String, dynamic>>()) {
        events.clear();
        frames.add(_unhex(scenario['payloadHex'] as String));
        expect(events, scenario['immediateEvents'], reason: scenario['name'] as String);
        await Future<void>.delayed(Duration.zero);
        expect(events, scenario['beforeTimers'], reason: scenario['name'] as String);
        if (scenario['flushTimers'] == true) {
          expect(scenario['timerMilliseconds'], [500]);
          await Future<void>.delayed(const Duration(milliseconds: 520));
        }
        expect(events, scenario['events'], reason: scenario['name'] as String);
      }
      for (final scenario in (fixture['errorScenarios'] as List).cast<Map<String, dynamic>>()) {
        events.clear();
        failures.add(_unhex(scenario['payloadHex'] as String));
        expect(events, scenario['immediateEvents']);
        await Future<void>.delayed(Duration.zero);
        expect(events, scenario['events']);
      }
      await controller.close();
      await frames.close();
      await failures.close();
    });

    test('fresh state cancels initial delay; close cancels services and pending state', () async {
      final cancelled = <String>[];
      final frames = StreamController<List<int>>(sync: true, onCancel: () => cancelled.add('state'));
      final failures = StreamController<List<int>>(sync: true, onCancel: () => cancelled.add('error'));
      var requests = 0;
      final dispatcher = EsperantoDispatcher();
      dispatcher.register(ContextPlayerClient.serviceId, EsperantoService(
        single: {'Pause': (_) { requests++; return ResponseWithReasons().writeToBuffer(); }},
        streaming: {'GetState': (_) => frames.stream, 'GetError': (_) => failures.stream},
      ));
      final controller = PlaybackController(ContextPlayerClient(dispatcher));
      final states = <PlaybackState>[];
      final errors = <Object>[];
      controller.states.listen(states.add);
      controller.errors.listen(errors.add);
      controller.start();
      controller.start();
      expect(controller.state, isNull);
      await controller.pause();
      expect(requests, 1);
      expect(controller.state, isNull);
      frames.add([]);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final nonzero = fixture['stateScenarios'][1] as Map<String, dynamic>;
      frames.add(_unhex(nonzero['payloadHex'] as String));
      await Future<void>.delayed(const Duration(milliseconds: 520));
      expect(states.map((state) => state.timestamp), [10000]);
      frames.add([255]);
      await Future<void>.delayed(Duration.zero);
      expect(errors, hasLength(1));
      frames.add([]);
      await controller.close();
      await Future<void>.delayed(const Duration(milliseconds: 520));
      expect(states, hasLength(1));
      expect(cancelled, ['state', 'error']);
      frames.add(_unhex(nonzero['payloadHex'] as String));
      expect(states, hasLength(1));
      await frames.close();
      await failures.close();
    });
  });
}
