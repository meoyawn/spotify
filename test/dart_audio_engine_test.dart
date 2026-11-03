import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/audio_source.dart';
import 'package:spotify_flutter/playback/dart_audio_engine.dart';
import 'package:spotify_flutter/playback/engine.dart';

const _methods = MethodChannel('xyz.luan/audioplayers');
const _global = MethodChannel('xyz.luan/audioplayers.global');
const _globalEvents = MethodChannel('xyz.luan/audioplayers.global/events');

/// Independent platform boundary: records device calls, acknowledges them only
/// when instructed, and supplies explicit decoder events/position readings.
/// It does not implement player state, source identity, leases or engine JSON.
class _AudioDevice {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <(String, String, Map)>[];
  final trace = <String>[];
  final positions = <String, int>{};
  final gates = <(String, String), Completer<void>>{};
  final eventChannels = <MethodChannel>[];

  void install() {
    messenger.setMockMethodCallHandler(_global, (_) async => null);
    messenger.setMockMethodCallHandler(_globalEvents, (_) async => null);
    messenger.setMockMethodCallHandler(_methods, (call) async {
      final arguments = call.arguments as Map;
      final id = arguments['playerId'] as String;
      calls.add((call.method, id, arguments));
      trace.add('${call.method}:$id');
      if (call.method == 'create') {
        final events = MethodChannel('xyz.luan/audioplayers/events/$id');
        eventChannels.add(events);
        messenger.setMockMethodCallHandler(events, (_) async => null);
      }
      if (call.method == 'getCurrentPosition') return positions[id] ?? 0;
      if (!const {'create', 'setReleaseMode', 'setVolume', 'setSourceUrl',
          'resume', 'pause', 'seek', 'stop', 'release', 'dispose'}.contains(call.method)) {
        throw StateError('Unexpected platform call: ${call.method}');
      }
      await gates[(call.method, id)]?.future;
      if (call.method == 'dispose') trace.add('disposed:$id');
      return null;
    });
  }

  Future<void> event(String id, String name, [Object? value]) => messenger.handlePlatformMessage(
    'xyz.luan/audioplayers/events/$id',
    const StandardMethodCodec().encodeSuccessEnvelope({'event': name, 'value': value}), (_) {});

  bool called(String method, String id) => calls.any((call) => call.$1 == method && call.$2 == id);
  List<String> get players => [for (final call in calls) if (call.$1 == 'create') call.$2];
  void uninstall() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_global, null);
    messenger.setMockMethodCallHandler(_globalEvents, null);
    for (final channel in eventChannels) { messenger.setMockMethodCallHandler(channel, null); }
  }
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Expected platform/engine transition did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('decoder events own state while superseded and closed source leases release after device disposal', () async {
    final device = _AudioDevice()..install();
    addTearDown(device.uninstall);
    final directory = await Directory.systemTemp.createTemp('dart-audio-engine-');
    addTearDown(() => directory.delete(recursive: true));
    final files = [for (final name in ['a', 'b', 'late']) File('${directory.path}/$name.container')];
    for (final file in files) { await file.writeAsBytes(const [0, 1, 2]); }
    const uris = ['spotify:track:0000000000000000000001',
      'spotify:episode:0000000000000000000002', 'spotify:track:0000000000000000000003'];
    final resolving = <String>{};
    final sources = {for (final uri in uris) uri: Completer<PreparedAudioFile>()};
    final released = <String, int>{};
    PreparedAudioFile lease(int index) => PreparedAudioFile(path: files[index].path,
      metadata: {'title': 'Descriptor ${index + 1}', 'artist': 'Source artist', 'duration_ms': 999999},
      release: () async {
        final uri = uris[index];
        released[uri] = (released[uri] ?? 0) + 1;
        device.trace.add('lease:$uri');
      });
    final engine = await DartAudioEngine.open(resolveSpotifySource: (uri, {cancellationToken}) {
      resolving.add(uri);
      return sources[uri]!.future;
    });
    addTearDown(() async {
      for (final gate in device.gates.values) { if (!gate.isCompleted) gate.complete(); }
      await engine.close();
    });
    final events = <PlayerJson>[];
    final subscription = engine.events.listen(events.add);
    addTearDown(subscription.cancel);
    bool playerEvent(String event, String uri) => events.any((value) =>
      value['type'] == 'player' && value['event'] == event && value['uri'] == uri);

    final accepted = await engine.command('load', {'uri': uris[0], 'play': true});
    expect(accepted['accepted'], isTrue);
    expect(playerEvent('playing', uris[0]), isFalse);
    await _until(() => resolving.contains(uris[0]) && device.players.length == 1);
    final a = device.players[0];
    final resume = Completer<void>();
    device.gates[('resume', a)] = resume;
    sources[uris[0]]!.complete(lease(0));
    await _until(() => device.called('setSourceUrl', a));
    expect(playerEvent('playing', uris[0]), isFalse);
    await device.event(a, 'audio.onDuration', 7000);
    await device.event(a, 'audio.onPrepared', true);
    await _until(() => device.called('resume', a));
    expect(playerEvent('playing', uris[0]), isFalse);
    resume.complete();
    await _until(() => playerEvent('playing', uris[0]));
    final metadata = events.lastWhere((event) => event['event'] == 'track_changed');
    expect((metadata['metadata'] as Map)['title'], 'Descriptor 1');
    expect(metadata['duration_ms'], 7000);

    final pause = Completer<void>();
    device.gates[('pause', a)] = pause;
    await engine.command('pause');
    await _until(() => device.called('pause', a));
    expect(playerEvent('paused', uris[0]), isFalse);
    device.positions[a] = 333;
    pause.complete();
    await _until(() => playerEvent('paused', uris[0]) && events.any((event) => event['position_ms'] == 333));
    await engine.command('seek', {'position_ms': 2000});
    await _until(() => device.called('seek', a));
    device.positions[a] = 1996;
    await device.event(a, 'audio.onSeekComplete');
    await _until(() => playerEvent('seeked', uris[0]));
    expect(events.lastWhere((event) => event['event'] == 'seeked')['position_ms'], 1996);

    final disposal = Completer<void>();
    device.gates[('dispose', a)] = disposal;
    final checkpoint = events.length;
    final staleDuration = device.event(a, 'audio.onDuration', 123456);
    final staleCompletion = device.event(a, 'audio.onComplete');
    await engine.command('load', {'uri': uris[1], 'play': true});
    await Future.wait([staleDuration, staleCompletion]);
    await _until(() => device.called('dispose', a));
    expect(released[uris[0]], isNull);
    disposal.complete();
    await _until(() => released[uris[0]] == 1 && resolving.contains(uris[1]));
    expect(events.skip(checkpoint).where((event) => event['type'] == 'player' && event['uri'] == uris[0]), isEmpty);
    expect(device.trace.indexOf('disposed:$a'), lessThan(device.trace.indexOf('lease:${uris[0]}')));
    sources[uris[1]]!.complete(lease(1));
    await _until(() => device.players.length == 2 && device.called('setSourceUrl', device.players[1]));
    final b = device.players[1];
    await device.event(b, 'audio.onDuration', 8000);
    await device.event(b, 'audio.onPrepared', true);
    await _until(() => playerEvent('playing', uris[1]));

    final unloadDisposal = Completer<void>();
    device.gates[('dispose', b)] = unloadDisposal;
    final unloaded = await engine.command('unload');
    await _until(() => device.called('dispose', b));
    expect(released[uris[1]], isNull);
    expect(events.any((event) => event['type'] == 'command_completed' && event['request_id'] == unloaded['request_id']), isFalse);
    unloadDisposal.complete();
    await _until(() => events.any((event) => event['type'] == 'command_completed' && event['request_id'] == unloaded['request_id']));
    expect(released[uris[1]], 1);

    await engine.command('load', {'uri': uris[2], 'play': true});
    await _until(() => resolving.contains(uris[2]));
    final latePlayer = device.players[2];
    await engine.close();
    final closedEventCount = events.length;
    final lateLease = lease(2);
    sources[uris[2]]!.complete(lateLease);
    await _until(() => released[uris[2]] == 1);
    await lateLease.close();
    await engine.close();
    expect(released, {for (final uri in uris) uri: 1});
    expect(events.length, closedEventCount);
    expect(device.called('setSourceUrl', latePlayer), isFalse);
    expect(device.called('resume', latePlayer), isFalse);
    expect(device.trace.indexOf('disposed:$b'), lessThan(device.trace.indexOf('lease:${uris[1]}')));
    expect(device.trace.indexOf('disposed:$latePlayer'), lessThan(device.trace.indexOf('lease:${uris[2]}')));
    expect(device.calls.where((call) => call.$1 == 'setSourceUrl').map((call) => call.$3['isLocal']), everyElement(isTrue));
  });

  test('failed output retirement reports unload failure and retains the issued media file', () async {
    final device = _AudioDevice()..install();
    addTearDown(device.uninstall);
    final directory = await Directory.systemTemp.createTemp('dart-audio-disposal-');
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/issued.container').writeAsBytes(const [0, 1, 2]);
    final engine = await DartAudioEngine.open(resolveSpotifySource: (_, {cancellationToken}) async =>
      PreparedAudioFile(path: file.path, release: () async { await file.delete(); }));
    addTearDown(() async {
      try { await engine.close(); } on PlatformException { /* Failed output remains owned. */ }
    });
    final events = <PlayerJson>[];
    final subscription = engine.events.listen(events.add);
    addTearDown(subscription.cancel);
    final loaded = await engine.command('load', {
      'uri': 'spotify:track:0000000000000000000001', 'play': false});
    await _until(() => device.players.length == 1 && device.called('setSourceUrl', device.players.single));
    final player = device.players.single;
    await device.event(player, 'audio.onPrepared', true);
    await _until(() => events.any((event) => event['type'] == 'command_completed' &&
      event['request_id'] == loaded['request_id'] && event['ok'] == true));

    final stop = Completer<void>();
    device.gates[('stop', player)] = stop;
    final unloaded = await engine.command('unload');
    await _until(() => device.called('stop', player));
    stop.completeError(PlatformException(code: 'device_stop_failed', message: 'Output retirement failed'));
    await _until(() => events.any((event) => event['type'] == 'command_completed' &&
      event['request_id'] == unloaded['request_id']));
    expect(events.lastWhere((event) => event['type'] == 'command_completed' &&
      event['request_id'] == unloaded['request_id'])['ok'], isFalse);
    expect(events.where((event) => event['type'] == 'session' && event['event'] == 'disconnected'), isEmpty);
    expect(device.called('release', player), isFalse);
    expect(device.called('dispose', player), isFalse);
    expect(await file.exists(), isTrue, reason: 'A failed stop never relinquished the decoder source');
    await expectLater(engine.close(), throwsA(isA<PlatformException>()
      .having((error) => error.code, 'code', 'device_stop_failed')));
    expect(await file.exists(), isTrue);
  });
}
