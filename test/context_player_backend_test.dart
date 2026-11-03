import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/client.dart';
import 'package:spotify_flutter/playback/controller.dart';
import 'package:spotify_flutter/playback/context_player_backend.dart';
import 'package:spotify_flutter/playback/engine.dart';
import 'package:spotify_flutter/playback/models.dart';
import 'package:spotify_flutter/playback/requests.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';

const first = 'spotify:track:0000000000000000000001';
const second = 'spotify:track:0000000000000000000002';

class _Engine implements PlaybackEngine {
  final source = StreamController<PlayerJson>.broadcast(sync: true);
  final commands = <PlayerJson>[];
  bool closed = false;
  @override
  Stream<PlayerJson> get events => source.stream;
  @override
  Future<PlayerJson> command(String command, [PlayerJson arguments = const {}]) async {
    commands.add({'command': command, ...arguments});
    return {'ok': true, 'accepted': true, 'request_id': commands.length};
  }
  void event(String event, String uri, {int position = 0, PlayerJson metadata = const {}, PlayerJson? restrictions}) {
    source.add({'type': 'player', 'event': event, 'uri': uri, 'position_ms': position,
      'duration_ms': 10000, 'metadata': metadata, 'restrictions': ?restrictions});
  }
  @override
  Future<void> close() async { closed = true; await source.close(); }
}

class _Harness {
  _Harness() {
    final dispatcher = EsperantoDispatcher();
    backend = ContextPlayerBackend(engine, random: Random(7))..register(dispatcher);
    client = ContextPlayerClient(dispatcher);
    controller = PlaybackController(client)..start();
    controller.states.listen(states.add);
    controller.errors.listen(errors.add);
  }
  final engine = _Engine();
  late final ContextPlayerBackend backend;
  late final ContextPlayerClient client;
  late final PlaybackController controller;
  final states = <PlaybackState>[];
  final errors = <Object>[];
  Future<void> close() async { await controller.close(); await backend.close(); }
}

PlaybackContext context([List<String> tracks = const [first, second]]) => PlaybackContext(
  'spotify:playlist:0000000000000000000003', pages: [PlaybackPage(items: [
    for (final uri in tracks) PlaybackItemReference(uri)])]);
Future<void> drain() => Future<void>.delayed(Duration.zero);

void main() {
  test('ContextPlayer submits real queue loads and waits for player events before changing playback state', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.controller.play(context(), const PlaybackOrigin());
    await drain();
    expect(h.engine.commands.single, {'command': 'load', 'uri': first, 'play': true, 'position_ms': 0});
    expect(h.states, isEmpty);
    h.engine.source.add({'type': 'player', 'event': 'playing', 'uri': first,
      'play_request_id': 99, 'position_ms': 120, 'metadata': {'title': 'Actual native title', 'artist': 'Native artist'}});
    await drain();
    expect(h.controller.state!.item!.uri, first);
    expect(h.controller.state!.item!.name, 'Actual native title');
    expect(h.controller.state!.isPaused, isFalse);
    final playbackId = h.controller.state!.playbackId;
    h.engine.event('track_changed', first, metadata: {'title': 'Actual native title'});
    await drain();
    expect(h.controller.state!.playbackId, playbackId);
    await h.controller.skipNext();
    expect(h.engine.commands.last['uri'], second);
    expect(h.controller.state!.item!.uri, first);
    h.engine.event('loading', second);
    await drain();
    expect(h.controller.state!.isBuffering, isTrue);
    expect(h.controller.state!.hasContext, isFalse);
    h.engine.event('playing', second, metadata: {'title': 'Second actual title'});
    await drain();
    expect(h.controller.state!.item!.uri, second);
    expect(h.controller.state!.isPaused, isFalse);
    await h.controller.skipTo(const PlaybackItemReference(first));
    expect(h.engine.commands.last['uri'], first);
  });

  test('native restrictions survive position frames and blocked commands never reach the engine', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.controller.play(context(), const PlaybackOrigin());
    h.engine.event('playing', first, restrictions: {'can_seek': false, 'can_skip_next': false});
    await drain();
    h.engine.event('position', first, position: 500);
    await drain();
    expect(h.controller.state!.restrictions.canSeek, isFalse);
    final commands = h.engine.commands.length;
    await expectLater(h.controller.seekTo(4000), throwsA(isA<PlaybackCommandException>()));
    await expectLater(h.controller.skipNext(), throwsA(isA<PlaybackCommandException>()));
    expect(h.engine.commands.length, commands);
    h.engine.source.add({'type': 'error', 'code': 'free_account_restriction', 'message': 'Native account restriction'});
    await drain();
    expect(h.errors.last.toString(), contains('Native account restriction'));
  });

  test('repeat and shuffled queue ownership dispatch native loads on actual end events', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.controller.play(context(), const PlaybackOrigin());
    h.engine.event('playing', first);
    await drain();
    await h.controller.setRepeat(PlaybackRepeat.track);
    h.engine.event('end_of_track', first);
    await drain();
    expect(h.engine.commands.last['uri'], first);
    expect(h.controller.state!.isPaused, isTrue);
    h.engine.event('playing', first);
    await drain();
    await h.controller.setRepeat(PlaybackRepeat.context);
    await h.controller.setShuffle(true);
    h.engine.event('end_of_track', first);
    await drain();
    expect(h.engine.commands.last['uri'], second);
    h.engine.event('playing', second);
    await drain();
    h.engine.event('end_of_track', second);
    await drain();
    expect(h.engine.commands.last['uri'], first);
  });

  test('pause and seek are not optimistic and closing releases the engine', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.backend.loadLocalFile('/tmp/owned-audio.wav');
    expect(h.engine.commands.single['uri'], 'file:///tmp/owned-audio.wav');
    h.engine.event('playing', 'file:///tmp/owned-audio.wav', position: 1000, metadata: {'title': 'Owned audio'});
    await drain();
    await h.controller.pause();
    expect(h.controller.state!.isPaused, isFalse);
    h.engine.event('paused', 'file:///tmp/owned-audio.wav', position: 1000);
    await drain();
    expect(h.controller.state!.isPaused, isTrue);
    await h.controller.seekBy(1200);
    expect(h.engine.commands.last, {'command': 'seek', 'position_ms': 2200});
    expect(h.controller.state!.positionAsOfTimestamp, 1000);
    await h.controller.resume();
    expect(h.engine.commands.last, {'command': 'play'});
    expect(h.controller.state!.isPaused, isTrue);
    for (final ended in ['end_of_track', 'stopped']) {
      h.engine.event('playing', 'file:///tmp/owned-audio.wav', position: 2200);
      await drain();
      h.engine.event(ended, 'file:///tmp/owned-audio.wav', position: 10000);
      await drain();
      await h.controller.resume();
      expect(h.engine.commands.last, {'command': 'load', 'uri': 'file:///tmp/owned-audio.wav',
        'play': true, 'position_ms': 0}, reason: 'Resume after $ended must reload the retained item');
      expect(h.controller.state!.isPaused, isTrue);
      expect(h.controller.state!.hasContext, isFalse);
    }
    await h.close();
    expect(h.engine.closed, isTrue);
  });

  test('connection future waits for native authentication completion and does not publish playback', () async {
    final h = _Harness();
    addTearDown(h.close);
    var connected = false;
    final completion = h.backend.connect(accessToken: 'synthetic-explicit-token').then((_) { connected = true; });
    await drain();
    expect(h.engine.commands.single['command'], 'connect');
    expect(connected, isFalse);
    h.engine.source.add({'type': 'session', 'event': 'connected'});
    await drain();
    expect(connected, isFalse);
    h.engine.source.add({'type': 'command_completed', 'request_id': 1, 'command': 'connect', 'ok': true});
    await completion;
    expect(connected, isTrue);
    expect(h.states, isEmpty);
  });

  test('asynchronous rejected load restores the previous actual queue owner', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.controller.play(context(), const PlaybackOrigin());
    h.engine.event('playing', first);
    await drain();
    h.engine.source.add({'type': 'command_completed', 'request_id': 1, 'command': 'load', 'ok': true});
    await h.controller.play(context([second]), const PlaybackOrigin());
    h.engine.source.add({'type': 'error', 'request_id': 2, 'code': 'command_failed', 'message': 'Cannot load selected item'});
    h.engine.source.add({'type': 'command_completed', 'request_id': 2, 'command': 'load', 'ok': false, 'error': 'Cannot load selected item'});
    h.engine.event('position', first, position: 500);
    await drain();
    expect(h.controller.state!.item!.uri, first);
    expect(h.controller.state!.positionAsOfTimestamp, 500);
    await h.controller.skipNext();
    expect(h.engine.commands.last['uri'], second);
    expect(h.errors.single.toString(), contains('Cannot load selected item'));
  });
}
