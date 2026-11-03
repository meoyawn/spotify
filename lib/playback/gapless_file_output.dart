import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart' as ja;
import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';
import 'audio_source.dart';
import 'file_audio_output.dart' as pcm;
import 'pcm_file_output.dart';
import 'standard_streaming_audio.dart';

class FileAudioOutputItem {
  const FileAudioOutputItem({required this.id, required this.path, this.source});
  final int id;
  final String path;
  final PreparedAudioFile? source;
}

class FileAudioOutputEvent {
  const FileAudioOutputEvent({this.id, required this.type,
    this.position, this.duration, this.error});
  final int? id;
  final String type;
  final Duration? position, duration;
  final Object? error;
}

/// Standard file decoding/output only. The caller owns transient-file cleanup,
/// source IDs, Spotify requests and the decision about which item comes next.
class GaplessFileOutput {
  GaplessFileOutput() : _player = ja.AudioPlayer(
      useProxyForRequestHeaders: false, useLazyPreparation: false) {
    _subscriptions.add(_player.playerEventStream.listen(_onPlayerEvent));
    _subscriptions.add(_player.sequenceStateStream.listen((_) => _onPlayerEvent(_player.playerEvent)));
    _subscriptions.add(_player.positionStream.listen((position) {
      if (!_usingPcm && _acceptEvents && !_mutating && !_disposed && _currentSource != null &&
          identical(_player.sequenceState.currentSource, _currentSource) &&
          _player.playbackEvent.currentIndex == _player.sequenceState.currentIndex) {
        _emit(FileAudioOutputEvent(id: _currentId, type: 'position', position: position));
      }
    }));
    _subscriptions.add(_player.errorStream.listen((error) {
      if (_usingPcm || _disposed || !_acceptEvents || _mutating) return;
      final index = error.index, sequence = _player.sequenceState.sequence;
      final tag = index != null && index >= 0 && index < sequence.length
        ? sequence[index].tag : _currentId;
      _emit(FileAudioOutputEvent(id: tag is int ? tag : null, type: 'error', error: error));
    }));
  }

  final ja.AudioPlayer _player;
  final _events = StreamController<FileAudioOutputEvent>.broadcast();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposal;
  ja.IndexedAudioSource? _currentSource;
  int? _requestedId;
  int _loadGeneration = 0, _nextRevision = 0;
  bool _acceptEvents = false, _mutating = false, _disposed = false;
  String? _lastState;
  Duration? _lastDuration;
  bool _hasDuration = false;
  PcmFileOutput? _pcm;
  bool _usingPcm = false;
  FileAudioOutputItem? _mixedNext;
  double _volume = 1;
  CancellationToken? _lifetimeCancellation, _loadCancellation, _nextCancellation;
  CancellationToken? _mixedNextCancellation;
  CancellationToken get _lifetime => _lifetimeCancellation ??= CancellationToken();

  Stream<FileAudioOutputEvent> get events => _events.stream;
  int? get _currentId => _currentSource?.tag is int ? _currentSource!.tag as int : null;
  int? get currentId => _disposed ? null : _usingPcm ? _pcm?.currentId : _currentId;
  bool get hasNext => !_disposed && (_mixedNext != null || (_usingPcm
    ? _pcm?.hasNext == true : _acceptEvents && !_mutating && _player.hasNext));
  bool get hasPreciseTiming => _usingPcm || _currentSource is ja.ProgressiveAudioSource &&
    (_currentSource as ja.ProgressiveAudioSource).options?.darwinAssetOptions?.preferPreciseDurationAndTiming == true;

  static ja.ProgressiveAudioSource _fileSource(String path, int id) =>
    ja.ProgressiveAudioSource(Uri.file(path), tag: id,
      options: const ja.ProgressiveAudioSourceOptions(darwinAssetOptions:
        ja.DarwinAssetOptions(preferPreciseDurationAndTiming: true)));

  Future<void> load(FileAudioOutputItem item, {required bool play,
      Duration position = Duration.zero, CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    _lifetime.throwIfCancelled();
    _loadCancellation?.cancel(); _nextCancellation?.cancel();
    final owner = _loadCancellation = CancellationToken();
    final token = MergedCancellationToken([_lifetime, owner, ?cancellationToken]);
    _mixedNextCancellation = null;
    if (_isPcm(item)) return _loadPcm(item, play: play, position: position, cancellationToken: token);
    final wasPcm = _usingPcm;
    _usingPcm = false; _mixedNext = null;
    final generation = ++_loadGeneration;
    ++_nextRevision;
    _requestedId = item.id;
    _acceptEvents = false;
    return _serialize(() async {
      if (generation != _loadGeneration) return;
      if (wasPcm) await _pcm?.stop();
      if (position < Duration.zero) throw ArgumentError.value(position, 'position');
      final path = await _filePath(item.path, cancellationToken: token);
      if (generation != _loadGeneration) return;
      _emit(FileAudioOutputEvent(id: item.id, type: 'loading'));
      _mutating = true;
      try {
        await _player.pause();
        if (generation != _loadGeneration) return;
        await _loadNative(path, item.id, position, token);
        if (generation != _loadGeneration) return;
        _currentSource = null;
        _lastState = null;
        _hasDuration = false;
        _acceptEvents = true;
      } finally { _mutating = false; }
      if (generation != _loadGeneration) return;
      if (play) _startPlay();
      _onPlayerEvent(_player.playerEvent);
    }, errorId: item.id, cancellationToken: token);
  }

  /// Replaces the single upcoming file without reloading or seeking current.
  /// A later load invalidates this operation before any subsequent mutation.
  Future<void> setNext(FileAudioOutputItem? item, {CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    _lifetime.throwIfCancelled();
    _nextCancellation?.cancel();
    final owner = _nextCancellation = CancellationToken();
    final token = MergedCancellationToken([_lifetime, owner, ?cancellationToken]);
    _mixedNextCancellation = item == null ? null : cancellationToken;
    if (_usingPcm) {
      if (item == null || _isPcm(item)) {
        _mixedNext = null;
        return _pcm!.setNext(item == null ? null : _pcmItem(item), cancellationToken: token);
      }
      _mixedNext = item;
      return _pcm!.setNext(null, cancellationToken: token);
    }
    if (item != null && _isPcm(item)) { _mixedNext = item; item = null; }
    else { _mixedNext = null; }
    final generation = _loadGeneration, revision = ++_nextRevision;
    final expectedId = _requestedId;
    bool stale() => token.isCancelled || generation != _loadGeneration || revision != _nextRevision;
    return _serialize(() async {
      if (stale() || !_acceptEvents) return;
      final path = item == null ? null : await _filePath(item.path, cancellationToken: token);
      if (stale()) return;
      var state = _player.sequenceState;
      if (state.currentSource == null || state.currentSource!.tag != expectedId) return;
      _mutating = true;
      try {
        // With current + at most one upcoming source, an automatic promotion
        // leaves only an ended prefix. Removing that prefix cannot remove the
        // current item, even if playback advances while the call is pending.
        final prefix = state.currentIndex!;
        if (prefix > 0) {
          await _player.removeAudioSourceRange(0, prefix);
          if (stale()) return;
        }
        state = _player.sequenceState;
        final index = state.currentIndex;
        if (index == null || state.currentSource?.tag != expectedId) return;
        final sequence = state.sequence;
        if (item != null && sequence.length == index + 2) {
          final next = sequence[index + 1];
          if (next.tag == item.id && next is ja.UriAudioSource && next.uri == Uri.file(path!)) return;
        }
        if (sequence.length > index + 1) {
          await _player.removeAudioSourceRange(index + 1, sequence.length);
          if (stale()) return;
        }
        if (item != null) {
          await _player.addAudioSource(_fileSource(path!, item.id));
          if (token.isCancelled) {
            final sequence = _player.sequenceState;
            final index = sequence.sequence.indexWhere((source) => source.tag == item!.id);
            if (index >= 0 && index != sequence.currentIndex) await _player.removeAudioSourceAt(index);
            token.throwIfCancelled();
          }
        }
      } finally {
        _mutating = false;
        if (!stale()) _onPlayerEvent(_player.playerEvent);
      }
    }, errorId: item?.id ?? expectedId, cancellationToken: token);
  }

  Future<void> play({CancellationToken? cancellationToken}) => _usingPcm
    ? _pcm!.play(cancellationToken: cancellationToken)
    : _serialize(() async { _startPlay(); }, cancellationToken: cancellationToken);
  Future<void> pause({CancellationToken? cancellationToken}) => _usingPcm
    ? _pcm!.pause(cancellationToken: cancellationToken)
    : _serialize(_player.pause, cancellationToken: cancellationToken);
  Future<void> advance({CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (_mixedNext case final next?) {
      final play = _usingPcm ? _pcm!.playing : _player.playing;
      final token = MergedCancellationToken([_lifetime, ?_mixedNextCancellation, ?cancellationToken]);
      _mixedNext = null;
      _mixedNextCancellation = null;
      return load(next, play: play, cancellationToken: token);
    }
    if (_usingPcm) return _pcm!.advance(cancellationToken: cancellationToken);
    final generation = _loadGeneration;
    return _serialize(() async {
      if (generation != _loadGeneration || !_acceptEvents || !_player.hasNext) return;
      final index = _player.sequenceState.currentIndex;
      if (index != null) await _player.seek(Duration.zero, index: index + 1);
    }, cancellationToken: cancellationToken);
  }
  Future<void> seek(Duration position, {CancellationToken? cancellationToken}) => _usingPcm
    ? _pcm!.seek(position, cancellationToken: cancellationToken) : _serialize(() async {
    if (position < Duration.zero) throw ArgumentError.value(position, 'position');
    await _player.seek(position);
  }, cancellationToken: cancellationToken);
  Future<void> setVolume(double volume, {CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (!volume.isFinite || volume < 0 || volume > 1) throw ArgumentError.value(volume, 'volume');
    _volume = volume;
    return _usingPcm ? _pcm!.setVolume(volume, cancellationToken: cancellationToken)
      : _serialize(() => _player.setVolume(volume), cancellationToken: cancellationToken);
  }

  Future<void> stop({CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    _loadCancellation?.cancel(); _nextCancellation?.cancel();
    _mixedNextCancellation = null;
    _mixedNext = null;
    if (_usingPcm) {
      ++_loadGeneration; ++_nextRevision;
      return _pcm!.stop(cancellationToken: cancellationToken);
    }
    final generation = ++_loadGeneration;
    ++_nextRevision;
    _acceptEvents = false;
    _requestedId = null;
    return _serialize(() async {
      if (generation != _loadGeneration) return;
      _mutating = true;
      try {
        await _player.stop();
        if (generation != _loadGeneration) return;
        await _player.clearAudioSources();
        _currentSource = null;
        _lastState = null;
        _hasDuration = false;
        _emit(const FileAudioOutputEvent(type: 'current'));
        _emit(const FileAudioOutputEvent(type: 'paused'));
      } finally { _mutating = false; }
    }, cancellationToken: cancellationToken);
  }

  void _startPlay() {
    final generation = _loadGeneration;
    // just_audio.play completes when playback stops/ends, not when it starts.
    // Keep that lifetime future out of the serialized command queue.
    unawaited(_player.play().catchError((Object error, StackTrace stack) {
      if (!_disposed && generation == _loadGeneration) {
        _emit(FileAudioOutputEvent(id: _currentId, type: 'error', error: error));
      }
    }));
  }

  void _onPlayerEvent(ja.PlayerEvent event) {
    if (_usingPcm || _disposed || _mutating || !_acceptEvents) return;
    final playback = event.playbackEvent, sequence = _player.sequenceState.sequence;
    final index = playback.currentIndex;
    if (index == null || index < 0 || index >= sequence.length) return;
    // Playlist edits may publish a changed sequence before the platform's
    // adjusted index arrives. Do not turn that transient index into a tag
    // promotion; the matching native event/sequence update will report it.
    if (index != _player.sequenceState.currentIndex) return;
    final source = sequence[index];
    if (!identical(source, _currentSource)) {
      _currentSource = source;
      _requestedId = _currentId;
      _lastState = null;
      _hasDuration = false;
      _emit(FileAudioOutputEvent(id: _currentId, type: 'current'));
      _emit(FileAudioOutputEvent(id: _currentId, type: 'position', position: playback.updatePosition));
    }
    if (!_hasDuration || playback.duration != _lastDuration) {
      _hasDuration = true;
      _lastDuration = playback.duration;
      _emit(FileAudioOutputEvent(id: _currentId, type: 'duration', duration: playback.duration));
    }
    final state = switch (playback.processingState) {
      ja.ProcessingState.loading || ja.ProcessingState.buffering => 'loading',
      ja.ProcessingState.completed => 'completed',
      ja.ProcessingState.ready => event.playing ? 'playing' : 'paused',
      ja.ProcessingState.idle => 'paused',
    };
    if (state == 'completed' && _mixedNext != null) {
      final token = _mixedNextCancellation; _mixedNextCancellation = null;
      final next = _mixedNext!; _mixedNext = null;
      unawaited(Future<void>.sync(() => load(next, play: event.playing, cancellationToken: token))
        .catchError((Object _) {}));
      return;
    }
    if (state != _lastState) {
      _lastState = state;
      _emit(FileAudioOutputEvent(id: _currentId, type: state));
    }
  }

  static bool _isPcm(FileAudioOutputItem item) =>
    item.source?.encoding == PreparedAudioEncoding.pcmS16leStereo48000;

  static pcm.PcmAudioOutputItem _pcmItem(FileAudioOutputItem item) =>
    pcm.PcmAudioOutputItem(id: item.id, path: item.path, source: item.source);

  PcmFileOutput _ensurePcm() {
    if (_pcm != null) return _pcm!;
    final api = StandardStreamingAudio.available();
    if (api == null) throw StateError('The standard PCM output has not been built');
    final output = PcmFileOutput(api);
    _subscriptions.add(output.events.listen((event) {
      if (!_usingPcm || _disposed) return;
      if (event.type == 'completed' && _mixedNext != null) {
        final token = _mixedNextCancellation; _mixedNextCancellation = null;
        final next = _mixedNext!; _mixedNext = null;
        unawaited(Future<void>.sync(() => load(next, play: true, cancellationToken: token))
          .catchError((Object _) {}));
        return;
      }
      _emit(FileAudioOutputEvent(id: event.id, type: event.type,
        position: event.position, duration: event.duration, error: event.error));
    }));
    return _pcm = output;
  }

  Future<void> _loadPcm(FileAudioOutputItem item, {required bool play, required Duration position,
      required CancellationToken cancellationToken}) {
    final generation = ++_loadGeneration;
    ++_nextRevision;
    _usingPcm = true; _mixedNext = null; _acceptEvents = false;
    _requestedId = item.id;
    return _serialize(() async {
      cancellationToken.throwIfCancelled();
      if (generation != _loadGeneration) return;
      await _player.pause();
      cancellationToken.throwIfCancelled();
      if (generation != _loadGeneration) return;
      await _player.clearAudioSources();
      cancellationToken.throwIfCancelled();
      if (generation != _loadGeneration) return;
      _currentSource = null;
      final output = _ensurePcm();
      await output.setVolume(_volume, cancellationToken: cancellationToken);
      if (generation != _loadGeneration) return;
      await output.load(_pcmItem(item), play: play, position: position, cancellationToken: cancellationToken);
    }, errorId: item.id, cancellationToken: cancellationToken);
  }

  Future<void> _loadNative(String path, int id, Duration position, CancellationToken token) async {
    token.throwIfCancelled();
    Future<void>? stopped;
    final cleanup = CancellationRegistration(token, onCancel: (_) {
      stopped = _player.stop().then<void>((_) {}, onError: (Object _, StackTrace __) {});
    });
    try {
      await _player.setAudioSources([_fileSource(path, id)],
        initialIndex: 0, initialPosition: position, preload: true);
      token.throwIfCancelled();
    } catch (_) { token.throwIfCancelled(); rethrow; }
    finally { cleanup.dispose(); await stopped; }
  }

  Future<void> _serialize(Future<void> Function() operation, {int? errorId,
      CancellationToken? cancellationToken}) {
    if (_disposed) return Future<void>.error(StateError('File audio output is disposed'));
    final token = MergedCancellationToken([_lifetime, ?cancellationToken]);
    final result = _tail.then((_) async {
      if (_disposed) return;
      try { token.throwIfCancelled(); await operation(); token.throwIfCancelled(); }
      catch (error) {
        token.throwIfCancelled();
        if (error is CancelledException) rethrow;
        _emit(FileAudioOutputEvent(id: errorId ?? _currentId, type: 'error', error: error));
        rethrow;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  static Future<String> _filePath(String path, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (!path.startsWith('/') || path.contains('\u0000')) {
      throw ArgumentError('Audio output accepts an existing absolute file path');
    }
    final file = File(path);
    if (await FileSystemEntity.type(path, followLinks: true) != FileSystemEntityType.file) {
      throw FileSystemException('Prepared audio file does not exist', path);
    }
    cancellationToken?.throwIfCancelled();
    final resolved = await file.resolveSymbolicLinks();
    cancellationToken?.throwIfCancelled();
    return resolved;
  }

  void _emit(FileAudioOutputEvent event) {
    if (!_disposed) _events.add(event);
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    _lifetime.cancel(); _loadCancellation?.cancel(); _nextCancellation?.cancel();
    ++_loadGeneration;
    ++_nextRevision;
    _acceptEvents = false;
    return _disposal = _tail.then((_) async {
      for (final subscription in _subscriptions) { await subscription.cancel(); }
      await _pcm?.dispose();
      await _player.dispose();
      await _events.close();
    });
  }
}
