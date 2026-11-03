import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import 'audio_source.dart';
import 'engine.dart';
import 'ffmpeg_audio_decoder.dart';
import 'ffmpeg_streaming_decoder.dart';
import 'gapless_file_output.dart';
import 'native_playback_id.dart';

class _AudioLoad {
  _AudioLoad(this.id, this.uri, {required this.playbackId, required this.play,
    required this.seekPosition, this.prefetch = false});
  final int id;
  final String uri;
  final List<int> playbackId;
  final bool prefetch;
  final cancellation = CancellationToken();
  PreparedAudioFile? source;
  Future<void>? preparation, disposal;
  bool play, ready = false, retired = false, queued = false;
  int position = 0, seekPosition;
  int? duration;
  FileAudioOutputItem get output => FileAudioOutputItem(id: id, path: source!.path, source: source);
}

/// Dart owns current/next source selection, account checks, playback IDs and
/// state. Standard device output receives only decrypted transient file paths,
/// never a Spotify URL or credential, and reports actual decoder events.
class DartAudioEngine implements QueuePreparingPlaybackEngine, AudioSourceOwner {
  DartAudioEngine._(this._volume, this._resolveSpotifySource) {
    _events = StreamController<PlayerJson>.broadcast(onListen: () {
      if (_initialized) return;
      _initialized = true;
      scheduleMicrotask(() => _emit({'type': 'engine', 'event': 'initialized',
        'backend': 'dart_audio', 'network_enabled': false}));
    });
    _output = GaplessFileOutput();
    _outputEvents = _output.events.listen(_outputEvent);
  }

  static Future<DartAudioEngine> open({double volume = 1,
      SpotifyAudioSourceResolver? resolveSpotifySource,
      SpotifyAudioRequestResolver? resolveSpotifyRequest}) async {
    if (!volume.isFinite || volume < 0 || volume > 1) throw ArgumentError.value(volume, 'volume');
    return DartAudioEngine._(volume, resolveSpotifySource).._resolveSpotifyRequest = resolveSpotifyRequest;
  }

  late final StreamController<PlayerJson> _events;
  late final GaplessFileOutput _output;
  late final StreamSubscription<FileAudioOutputEvent> _outputEvents;
  _AudioLoad? _current, _prepared;
  final _loads = <_AudioLoad>{};
  final _loadCommands = <int, _AudioLoad>{};
  final _sourceChanges = StreamController<void>.broadcast(sync: true);
  final SpotifyAudioSourceResolver? _resolveSpotifySource;
  SpotifyAudioRequestResolver? _resolveSpotifyRequest;
  double _volume;
  int _request = 0;
  bool _closed = false, _initialized = false;
  Future<void>? _closing;
  Future<void>? _outputRefresh;

  void bindSpotifyRequestResolver(SpotifyAudioRequestResolver resolver) {
    _resolveSpotifyRequest = resolver;
    unawaited(_refreshOutputTiming());
    for (final load in _loads.toList()) {
      if (!_wanted(load) && load.source == null) unawaited(_retire(load));
    }
  }

  Future<void> _refreshOutputTiming() {
    if (_outputRefresh != null) return _outputRefresh!;
    late final Future<void> pending;
    pending = _refreshPreparedOutput().whenComplete(() {
      if (identical(_outputRefresh, pending)) _outputRefresh = null;
    });
    return _outputRefresh = pending;
  }

  Future<void> _upgradePrepared(_AudioLoad load) async {
    final source = load.source;
    if (!_wanted(load) || !load.ready || source == null ||
        source.encoding == PreparedAudioEncoding.pcmS16leStereo48000) return;
    final converted = await const FfmpegStreamingDecoder().prepareFile(source.retain(),
      directory: Directory.systemTemp, cancellationToken: load.cancellation);
    if (!_wanted(load) || !identical(load.source, source)) { await converted.close(); return; }
    // Keep the old output's lease pinned until its replacement is relinquished.
    // Native decoding has its own retained lease until the worker finishes.
    load.source = PreparedAudioFile(path: converted.path, metadata: converted.metadata,
      encoding: converted.encoding, progress: converted.progress, release: () async {
        try { await converted.close(); }
        finally { await source.close(); }
      });
  }

  Future<void> _refreshPreparedOutput() async {
    final load = _current;
    if (load == null || !load.ready || load.source == null) return;
    try {
      final upgrade = FfmpegStreamingDecoder.available &&
        load.source!.encoding != PreparedAudioEncoding.pcmS16leStereo48000;
      if (!upgrade && _output.hasPreciseTiming) return;
      if (upgrade) {
        await _upgradePrepared(load);
        final next = _prepared;
        if (next?.ready == true) await _upgradePrepared(next!);
        if (!_active(load)) return;
      }
      await _output.pause(cancellationToken: load.cancellation);
      if (!_active(load)) return;
      await _output.load(load.output, play: load.play,
        position: Duration(milliseconds: load.position), cancellationToken: load.cancellation);
      final next = _prepared;
      if (_active(load) && next?.ready == true && next?.source != null) {
        await _output.setNext(next!.output, cancellationToken: next.cancellation);
      }
    } catch (error) {
      if (_active(load)) { load.ready = false; _error(load.id, error); }
    }
  }

  @override Stream<PlayerJson> get events => _events.stream;
  bool _active(_AudioLoad load) => !_closed && !load.retired && !load.cancellation.isCancelled && identical(load, _current);
  bool _wanted(_AudioLoad load) => !_closed && !load.retired && !load.cancellation.isCancelled &&
    (identical(load, _current) || identical(load, _prepared));
  void _sourcesChanged() {
    for (final load in _loads) {
      if (!_wanted(load)) load.cancellation.cancel();
    }
    if (!_sourceChanges.isClosed) _sourceChanges.add(null);
  }
  @override bool wantsAudioSource(String uri, {required bool prefetch}) =>
    _loads.any((load) => _wanted(load) && load.uri == uri && load.prefetch == prefetch);
  @override bool isCurrentAudioSourceEvent(PlayerJson event) {
    final load = _current;
    return load != null && _active(load) && event['play_request_id'] == load.id && event['uri'] == load.uri;
  }
  @override Stream<void> get audioSourceChanges => _sourceChanges.stream;
  void _emit(PlayerJson event) { if (!_closed) _events.add(event); }

  void _playerEvent(_AudioLoad load, String event) {
    if (!_active(load)) return;
    _emit({'type': 'player', 'event': event, 'uri': load.uri,
      'playback_id': load.playbackId, 'play_request_id': load.id,
      'position_ms': load.position, 'duration_ms': ?load.duration});
  }

  void _metadata(_AudioLoad load) {
    if (!_active(load) || load.source == null) return;
    final metadata = {...load.source!.metadata}..remove('duration')..remove('duration_ms');
    _emit({'type': 'player', 'event': 'track_changed', 'uri': load.uri,
      'playback_id': load.playbackId, 'play_request_id': load.id,
      'duration_ms': ?load.duration,
      'metadata': {...metadata, 'is_local': false, 'duration_ms': ?load.duration}});
  }

  void _error(int id, Object error) {
    final network = error is SocketException || error is HttpException || error is HandshakeException;
    final timeout = error is TimeoutException;
    _emit({'type': 'error', 'request_id': id,
      'code': network ? 'stream_connection' : timeout ? 'stream_timeout'
        : error is PlaybackEngineException ? error.code : 'audio_output',
      'message': network ? 'The music connection was interrupted.'
        : timeout ? 'The music server took too long to respond.'
        : error is PlaybackEngineException ? error.message : 'This track could not start playing.'});
  }

  _AudioLoad _newLoad(int id, String uri, PlayerJson arguments, {bool prefetch = false}) {
    if (!RegExp(r'^spotify:(track|episode):[A-Za-z0-9]{22}$').hasMatch(uri)) {
      throw const PlaybackEngineException('spotify_uri_required', 'Choose a Spotify track or episode.');
    }
    if (_resolveSpotifySource == null && _resolveSpotifyRequest == null) {
      throw const PlaybackEngineException('spotify_playback_unavailable', 'Spotify streaming is not connected.');
    }
    final position = (arguments['position_ms'] as num?)?.toInt() ?? 0;
    if (position < 0) throw ArgumentError.value(position, 'position_ms');
    final load = _AudioLoad(id, uri,
      playbackId: NativePlaybackId(given: (arguments['playback_id'] as List?)?.cast<int>()).bytes,
      play: arguments['play'] != false, seekPosition: position, prefetch: prefetch);
    _loads.add(load);
    return load;
  }

  @override Future<PlayerJson> command(String command, [PlayerJson arguments = const {}]) async {
    if (_closed) throw const PlaybackEngineException('engine_closed', 'Playback engine is closed.');
    if (command == 'connect') throw const PlaybackEngineException('spotify_playback_unavailable', 'Spotify streaming is not connected.');
    final id = ++_request;
    if (command == 'load') {
      final uri = arguments['uri']?.toString() ?? '';
      final previous = _current, upcoming = _prepared;
      // A user can select the next song while it is still downloading or
      // decoding. Promote that owned load and await its shared preparation;
      // discarding it here would restart the same source and license work.
      final reuse = upcoming != null && !upcoming.retired && upcoming.uri == uri &&
        ((arguments['position_ms'] as num?)?.toInt() ?? 0) == 0;
      final load = reuse ? upcoming : _newLoad(id, uri, arguments);
      load.play = arguments['play'] != false;
      load.seekPosition = (arguments['position_ms'] as num?)?.toInt() ?? 0;
      _current = load;
      _prepared = null;
      _sourcesChanged();
      _loadCommands[id] = load;
      Timer.run(() => unawaited(_run(id, command, () async {
        try { await _load(load, previous, reuse: reuse); }
        finally {
          if (!reuse && upcoming != null && !identical(upcoming, _current)) await _retire(upcoming);
        }
      })));
    } else if (command == 'prepare_next') {
      final previous = _prepared, owner = _current;
      final uri = arguments['uri']?.toString();
      final load = uri == null || owner == null ? null : _newLoad(id, uri, arguments, prefetch: true);
      _prepared = load;
      _sourcesChanged();
      Timer.run(() => unawaited(_run(id, command, () async {
        try {
          if (previous != null && !identical(previous, _current)) await _retire(previous);
          if (!identical(_current, owner) || !identical(_prepared, load)) return;
          await _output.setNext(null, cancellationToken: load?.cancellation ?? owner?.cancellation);
          if (load != null) await _prepare(load, owner!);
        } finally { if (load != null && !_wanted(load)) await _retire(load); }
      })));
    } else if (command == 'unload') {
      final loads = _loads.toList();
      _current = null; _prepared = null;
      _sourcesChanged();
      for (final load in loads) { load.retired = true; }
      Timer.run(() => unawaited(_run(id, command, () async {
        await _output.stop();
        await Future.wait(loads.map(_retire));
        if (_current == null) _emit({'type': 'session', 'event': 'disconnected'});
      })));
    } else {
      if (!const {'play', 'pause', 'stop', 'seek', 'volume', 'disconnect'}.contains(command)) {
        throw PlaybackEngineException('unsupported_command', 'Unsupported playback command: $command');
      }
      final load = _current;
      Timer.run(() => unawaited(_run(id, command, () => _control(command, arguments, load))));
    }
    return {'ok': true, 'accepted': true, 'request_id': id};
  }

  Future<void> _resolve(_AudioLoad load) => load.preparation ??= () async {
    if (!_wanted(load)) return;
    final resolve = _resolveSpotifyRequest;
    final source = await (resolve == null ? _resolveSpotifySource!(load.uri, cancellationToken: load.cancellation) :
      resolve(SpotifyAudioSourceRequest(uri: load.uri, playbackId: load.playbackId,
        prefetch: load.prefetch, cancellationToken: load.cancellation)));
    if (!_wanted(load)) { await source.close(); return; }
    load.source = source;
    load.duration = (source.metadata['duration_ms'] as num?)?.toInt();
    if (!await File(source.path).exists()) {
      throw const PlaybackEngineException('file_not_found', 'The prepared audio file does not exist.');
    }
  }();

  Future<void> _decodeFallback(_AudioLoad load) async {
    final source = load.source!;
    load.source = null;
    final decoded = await const FfmpegAudioDecoder().prepare(source, cancellationToken: load.cancellation);
    if (!_wanted(load)) { await decoded.close(); return; }
    load.source = decoded;
  }

  Future<void> _load(_AudioLoad load, _AudioLoad? previous, {required bool reuse}) async {
    if (!_active(load)) return;
    _playerEvent(load, 'loading');
    await _output.pause(cancellationToken: load.cancellation);
    await _resolve(load);
    if (!_active(load)) return;
    await _output.setVolume(_volume, cancellationToken: load.cancellation);
    if (reuse && load.queued && _output.hasNext && _output.currentId == previous?.id) {
      await _output.advance(cancellationToken: load.cancellation);
      await _output.setNext(null, cancellationToken: load.cancellation);
    } else if (_output.currentId != load.id) {
      Future<void> install() => _output.load(load.output, play: false,
        position: Duration(milliseconds: load.seekPosition), cancellationToken: load.cancellation);
      try { await install(); }
      catch (_) {
        if (!_active(load)) return;
        if (load.source?.encoding == PreparedAudioEncoding.pcmS16leStereo48000) rethrow;
        await _decodeFallback(load);
        if (!_active(load)) return;
        await install();
      }
    }
    if (!_active(load)) return;
    load.ready = true;
    _metadata(load);
    if (load.seekPosition != 0) await _output.seek(Duration(milliseconds: load.seekPosition),
      cancellationToken: load.cancellation);
    if (_output.currentId == load.id) {
      // Rapid A → loading B → C can leave A outside the immediate predecessor.
      // Once output owns C, release every abandoned lease without delaying play.
      for (final stale in _loads.toList()) {
        if (!_wanted(stale)) {
          unawaited(_retire(stale).catchError((Object _, StackTrace _) {}));
        }
      }
    }
    if (!_active(load)) return;
    if (load.play) { await _output.play(cancellationToken: load.cancellation); }
    else { await _output.pause(cancellationToken: load.cancellation); _playerEvent(load, 'paused'); }
  }

  Future<void> _prepare(_AudioLoad load, _AudioLoad owner) async {
    if (!identical(_prepared, load) || !_active(owner)) return;
    await _resolve(load);
    if (!identical(_prepared, load) || !_active(owner)) return;
    try { await _output.setNext(load.output, cancellationToken: load.cancellation); }
    catch (_) {
      if (!identical(_prepared, load) || !_active(owner)) return;
      if (load.source?.encoding == PreparedAudioEncoding.pcmS16leStereo48000) rethrow;
      await _decodeFallback(load);
      if (!identical(_prepared, load) || !_active(owner)) return;
      await _output.setNext(load.output, cancellationToken: load.cancellation);
    }
    if (identical(_prepared, load) && _active(owner)) {
      load.ready = true; load.queued = true;
      _emit({'type': 'prefetch', 'event': 'ready', 'uri': load.uri,
        'play_request_id': load.id, 'owner_request_id': owner.id});
    }
  }

  void _outputEvent(FileAudioOutputEvent event) {
    final upcoming = _prepared;
    if (event.type == 'error' && upcoming != null && event.id == upcoming.id) {
      // Preparation can fail after first PCM was admitted. Retire only the
      // speculative source; its failure must not pause or poison current audio.
      _prepared = null;
      upcoming.ready = false; upcoming.queued = false;
      _sourcesChanged();
      unawaited(_retire(upcoming).catchError((Object _) {}));
      _emit({'type': 'prefetch', 'event': 'failed', 'request_id': upcoming.id});
      return;
    }
    if (event.type == 'current' && upcoming != null && event.id == upcoming.id &&
        !upcoming.retired && upcoming.source != null) {
      final previous = _current;
      _current = upcoming; _prepared = null;
      _sourcesChanged();
      upcoming.ready = true; upcoming.play = previous?.play ?? true;
      if (previous != null) previous.retired = true;
      // Remove the ended prefix before releasing its file. This is queued
      // before the Dart context can append another upcoming source.
      final cleanup = _output.setNext(null);
      _emit({'type': 'player', 'event': 'transition', 'uri': upcoming.uri,
        'play_request_id': upcoming.id, 'playback_id': upcoming.playbackId,
        'previous_play_request_id': previous?.id,
        'previous_playback_id': previous?.playbackId, 'position_ms': 0,
        'duration_ms': ?upcoming.duration});
      _metadata(upcoming);
      unawaited(cleanup.then((_) async { if (previous != null) await _retire(previous); },
        onError: (Object error, StackTrace stack) { _error(upcoming.id, error); }));
    }
    final load = _current;
    if (load == null || !_active(load) || event.id != load.id) return;
    switch (event.type) {
      case 'position':
        load.position = event.position?.inMilliseconds ?? load.position;
        _playerEvent(load, 'position');
      case 'duration':
        // Keep actual catalog duration when AVFoundation estimates Ogg poorly.
        // The device decoder remains authoritative for completion.
        load.duration = load.source?.encoding == PreparedAudioEncoding.pcmS16leStereo48000
          ? event.duration?.inMilliseconds ?? load.duration
          : (load.source?.metadata['duration_ms'] as num?)?.toInt() ?? event.duration?.inMilliseconds;
        _metadata(load);
      case 'playing': _playerEvent(load, 'playing');
      case 'paused': if (load.ready) _playerEvent(load, 'paused');
      case 'loading': _playerEvent(load, 'loading');
      case 'completed': load.play = false; _playerEvent(load, 'end_of_track');
      case 'error':
        if (load.ready && event.error != null) {
          load.ready = false; load.play = false;
          _playerEvent(load, 'unavailable');
          _error(load.id, event.error!);
          // Stop is submitted before another user load can install its output.
          // Release the failed buffer only after the device relinquishes it.
          unawaited(_output.stop().then((_) => _retire(load))
            .catchError((Object _) {}));
        }
    }
  }

  Future<void> _run(int id, String command, Future<void> Function() work) async {
    if (_closed) return;
    try {
      await work();
      _emit({'type': 'command_completed', 'request_id': id, 'command': command, 'ok': true});
    } on CancelledException {
      _emit({'type': 'command_completed', 'request_id': id, 'command': command,
        'ok': false, 'cancelled': true});
    } catch (error) {
      if (command == 'prepare_next') {
        final load = _prepared;
        if (load?.id == id) { _prepared = null; await _retire(load!); }
        _emit({'type': 'prefetch', 'event': 'failed', 'request_id': id});
      } else {
        final load = _loadCommands[id];
        if (command != 'load' || load != null && _active(load)) {
          if (load != null) {
            _playerEvent(load, 'unavailable');
            await _output.stop();
            await _retire(load);
            for (final stale in _loads.toList()) {
              if (!_wanted(stale)) await _retire(stale);
            }
          }
          _error(id, error);
        }
      }
      _emit({'type': 'command_completed', 'request_id': id, 'command': command,
        'ok': false, 'error': error.toString()});
    } finally { _loadCommands.remove(id); }
  }

  Future<void> _control(String command, PlayerJson arguments, _AudioLoad? load) async {
    if (command == 'volume') {
      final value = (arguments['volume'] as num?)?.toDouble();
      if (value == null || !value.isFinite || value < 0 || value > 65535) throw ArgumentError.value(value, 'volume');
      _volume = value / 65535;
      await _output.setVolume(_volume);
      _emit({'type': 'player', 'event': 'volume_changed', 'volume': value.round()});
      return;
    }
    if (command == 'disconnect') {
      await _output.stop();
      _emit({'type': 'session', 'event': 'disconnected'});
      return;
    }
    load?.cancellation.throwIfCancelled();
    if (load == null || !_active(load)) throw const PlaybackEngineException('no_audio_loaded', 'Choose a Spotify track first.');
    switch (command) {
      case 'play': load.play = true; if (load.ready) await _output.play(cancellationToken: load.cancellation);
      case 'pause': load.play = false; if (load.ready) await _output.pause(cancellationToken: load.cancellation);
      case 'stop':
        load.play = false;
        await _output.stop(cancellationToken: load.cancellation);
        load.ready = false; load.position = 0;
        _playerEvent(load, 'stopped');
      case 'seek':
        var value = (arguments['position_ms'] as num?)?.toInt();
        if (value == null || value < 0) throw ArgumentError.value(value, 'position_ms');
        if (load.duration != null && value > load.duration!) value = load.duration!;
        load.seekPosition = value;
        if (load.ready) await _output.seek(Duration(milliseconds: value), cancellationToken: load.cancellation);
    }
  }

  Future<void> _retire(_AudioLoad load) => load.disposal ??= () async {
    load.retired = true;
    load.cancellation.cancel();
    _sourcesChanged();
    try { await load.source?.close(); }
    finally { _loads.remove(load); }
  }();

  @override Future<void> close() => _closing ??= () async {
    _closed = true;
    _current = null; _prepared = null;
    _sourcesChanged();
    await _outputEvents.cancel();
    await _output.dispose();
    await Future.wait(_loads.toList().map(_retire));
    await _events.close();
    await _sourceChanges.close();
  }();
}
