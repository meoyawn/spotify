import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'audio_source.dart';
import 'engine.dart';
import 'file_audio_output.dart';
import 'standard_streaming_audio.dart';

/// Dart owns the audible item, two-item preparation, pause/seek/buffering and
/// exact PCM boundaries. Core Audio sees a continuous bounded byte queue only.
class PcmFileOutput {
  PcmFileOutput(StandardStreamingAudio api) : _sink = StandardPcmSink(api);
  final StandardPcmSink _sink;
  final _events = StreamController<PcmAudioOutputEvent>.broadcast();
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposal;
  Timer? _timer;
  _PcmItem? _current, _next;
  int _timelineBase = 0, _generation = 0, _nextRevision = 0, _lastPositionMs = -1;
  int _lastPositionNoticeUs = 0;
  bool _disposed = false, _pumpQueued = false, _playRequested = false;
  bool _started = false, _completed = false, _failed = false;
  String? _state;
  CancellationToken? _lifetimeCancellation, _loadCancellation, _nextCancellation;
  CancellationToken get _lifetime => _lifetimeCancellation ??= CancellationToken();

  Stream<PcmAudioOutputEvent> get events => _events.stream;
  int? get currentId => _current?.item.id;
  bool get hasNext => _next != null;
  bool get playing => _playRequested;
  int get _position => _timelineBase + _sink.positionFrames;
  int get _enqueued => _timelineBase + _sink.enqueuedFrames;

  Future<void> load(PcmAudioOutputItem item, {required bool play,
      Duration position = Duration.zero, CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    _lifetime.throwIfCancelled();
    _loadCancellation?.cancel(); _nextCancellation?.cancel();
    final owner = _loadCancellation = CancellationToken();
    final token = MergedCancellationToken([_lifetime, owner, ?cancellationToken]);
    final generation = ++_generation;
    ++_nextRevision;
    return _serialize(() async {
      token.throwIfCancelled();
      Timeline.timeSync('audio.device.reset', _sink.reset); _timelineBase = 0; _started = false;
      await _closeItems();
      token.throwIfCancelled();
      final slot = await _PcmItem.open(item, position, cancellationToken: token);
      if (token.isCancelled || generation != _generation) {
        await slot.close(); token.throwIfCancelled(); return;
      }
      slot.timelineStart = 0;
      _current = slot; _playRequested = play;
      _completed = false; _failed = false; _state = null;
      _lastPositionMs = -1;
      _emit(PcmAudioOutputEvent(id: item.id, type: 'current'));
      _duration(slot);
      _noticePosition(force: true);
      try { await _pump(cancellationToken: token); }
      catch (_) {
        if (token.isCancelled) {
          _playRequested = false; _started = false;
          _sink.reset(); _current = null;
          await slot.close();
        }
        rethrow;
      }
      if (!play) _setState('paused');
    }, cancellationToken: token);
  }

  Future<void> setNext(PcmAudioOutputItem? item, {CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    _lifetime.throwIfCancelled();
    _nextCancellation?.cancel();
    final owner = _nextCancellation = CancellationToken();
    final token = MergedCancellationToken([_lifetime, owner, ?cancellationToken]);
    final generation = _generation, revision = ++_nextRevision, expectedId = currentId;
    return _serialize(() async {
    if (generation != _generation || revision != _nextRevision || currentId != expectedId || _current == null) return;
    if (item?.id == _next?.item.id && item?.path == _next?.item.path) return;
    final old = _next;
    // Already enqueued bytes cannot be recalled by releasing their file. A
    // queue replacement rebases from the real audible sample before refilling.
    if (old?.timelineStart != null) await _rebaseCurrent();
    _next = null;
    await old?.close();
    token.throwIfCancelled();
    if (item != null) {
      final next = await _PcmItem.open(item, Duration.zero, cancellationToken: token);
      if (token.isCancelled || generation != _generation || revision != _nextRevision) {
        await next.close(); token.throwIfCancelled(); return;
      }
      _next = next;
    }
    await _pump(cancellationToken: token);
  }, cancellationToken: token);
  }

  Future<void> play({CancellationToken? cancellationToken}) => _serialize(() async {
    if (_completed && _current != null) await _seek(Duration.zero, cancellationToken);
    cancellationToken?.throwIfCancelled();
    _playRequested = true;
    await _pump(cancellationToken: cancellationToken);
  }, cancellationToken: cancellationToken);

  Future<void> pause({CancellationToken? cancellationToken}) => _serialize(() async {
    _playRequested = false;
    _sink.pause(); _started = false;
    _noticePosition(force: true);
    _setState('paused');
  }, cancellationToken: cancellationToken);

  Future<void> seek(Duration position, {CancellationToken? cancellationToken}) =>
    _serialize(() => _seek(position, cancellationToken), cancellationToken: cancellationToken);

  Future<void> _seek(Duration position, CancellationToken? cancellationToken) async {
    cancellationToken?.throwIfCancelled();
    if (position < Duration.zero) throw ArgumentError.value(position, 'position');
    final slot = _current;
    if (slot == null) return;
    _sink.reset(); _timelineBase = 0; _started = false;
    final frames = position.inMicroseconds * 48000 ~/ Duration.microsecondsPerSecond;
    await slot.rewind(frames);
    cancellationToken?.throwIfCancelled();
    slot.timelineStart = 0;
    await _next?.rewind(0);
    cancellationToken?.throwIfCancelled();
    _next?.timelineStart = null;
    _completed = false; _failed = false;
    _lastPositionMs = -1;
    _noticePosition(force: true);
    await _pump(cancellationToken: cancellationToken);
  }

  Future<void> advance({CancellationToken? cancellationToken}) => _serialize(() async {
    final slot = _next;
    if (slot == null) return;
    final previous = _current;
    _sink.reset(); _timelineBase = 0; _started = false;
    _current = slot; _next = null;
    await slot.rewind(0); slot.timelineStart = 0;
    await previous?.close();
    cancellationToken?.throwIfCancelled();
    _completed = false; _failed = false; _state = null;
    _lastPositionMs = -1;
    _emit(PcmAudioOutputEvent(id: slot.item.id, type: 'current'));
    _duration(slot); _noticePosition(force: true);
    await _pump(cancellationToken: cancellationToken);
  }, cancellationToken: cancellationToken);

  Future<void> setVolume(double volume, {CancellationToken? cancellationToken}) => _serialize(() async {
    if (!volume.isFinite || volume < 0 || volume > 1) throw ArgumentError.value(volume, 'volume');
    _sink.setVolume(volume);
  }, cancellationToken: cancellationToken);

  Future<void> stop({CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    _loadCancellation?.cancel(); _nextCancellation?.cancel();
    ++_generation;
    ++_nextRevision;
    return _serialize(() async {
      _playRequested = false;
      _sink.reset(); _timelineBase = 0; _started = false;
      await _closeItems();
      _completed = false; _failed = false; _state = null;
      _emit(const PcmAudioOutputEvent(type: 'current'));
      _emit(const PcmAudioOutputEvent(type: 'paused'));
    }, cancellationToken: cancellationToken);
  }

  void _schedulePump() {
    _updatePumpClock();
    if (_disposed || _pumpQueued || !_playRequested || _current == null || _failed) return;
    _pumpQueued = true;
    unawaited(_serialize(() async {
      try { await _pump(); }
      finally { _pumpQueued = false; }
    }).catchError((Object _) {}));
  }

  void _updatePumpClock() {
    if (_disposed || !_playRequested || _current == null || _failed || _completed) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(milliseconds: 10), (_) => _schedulePump());
    }
  }

  Future<void> _pump({CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_disposed || _failed || _current == null) return;
    final current = _current!;
    if (current.progress?.error case final error?) throw error;
    _duration(current);
    // Fill only the device's bounded capacity. A growing file with no new
    // frames never blocks the serialized control queue or the UI isolate.
    for (var attempt = 0; attempt < 8 && _sink.writableBytes >= 4; attempt++) {
      final slot = current.fedAll ? _next : current;
      if (slot == null) break;
      if (slot.progress?.error case final error?) {
        if (identical(slot, current)) throw error;
        if (slot.timelineStart != null) await _rebaseCurrent();
        _next = null; await slot.close();
        _emit(PcmAudioOutputEvent(id: slot.item.id, type: 'error', error: error));
        break;
      }
      if (slot.fedAll) break;
      if (!await _feed(slot, cancellationToken)) break;
    }
    final position = _position;
    final upcoming = _next;
    if (upcoming != null && upcoming.timelineStart != null && position >= upcoming.timelineStart!) {
      _current = upcoming; _next = null;
      await current.close();
      _lastPositionMs = -1;
      _state = null;
      _emit(PcmAudioOutputEvent(id: upcoming.item.id, type: 'current'));
      _duration(upcoming);
    }
    _noticePosition();
    cancellationToken?.throwIfCancelled();
    final remaining = _enqueued - _position;
    final active = _current!;
    if (_playRequested) {
      if (!_started && remaining > 0) {
        _sink.start(); _started = true;
      }
      if (_started && remaining > 0) _setState('playing');
      else if (active.fedAll && _next == null && remaining == 0) {
        if (!_completed) {
          _completed = true; _playRequested = false; _started = false;
          _noticePosition(force: true);
          _setState('completed');
        }
      } else if (remaining == 0) {
        if (_started) {
          // Rebase the actual queue clock after underrun, keeping the Dart
          // source/sample positions. No wall-clock advancement is fabricated.
          _timelineBase = _enqueued;
          _sink.reset(); _started = false;
        }
        _setState('loading');
      }
    }
  }

  Future<bool> _feed(_PcmItem slot, CancellationToken? cancellationToken) async {
    cancellationToken?.throwIfCancelled();
    if (slot.pending == null) {
      var count = math.min(slot.available - slot.readPosition, _sink.writableBytes);
      count = math.min(count, 128 * 1024);
      count -= count % 4;
      if (count <= 0) return false;
      final bytes = await slot.file.read(count);
      if (_disposed) return false;
      if (bytes.isEmpty || bytes.length % 4 != 0) {
        cancellationToken?.throwIfCancelled();
        throw const PlaybackEngineException('audio_decode', 'The PCM buffer ended before its published samples.');
      }
      slot.readPosition += bytes.length;
      slot.pending = bytes; slot.pendingOffset = 0;
    }
    // Preserve the completed read's cursor/pending bytes before cancellation:
    // another owner can still need this current slot after a queued control ends.
    cancellationToken?.throwIfCancelled();
    final accepted = _sink.write(slot.pending!, slot.pendingOffset);
    if (accepted == 0) return false;
    slot.timelineStart ??= _enqueued - accepted ~/ 4;
    slot.queuedPosition += accepted;
    slot.pendingOffset += accepted;
    if (slot.pendingOffset == slot.pending!.length) { slot.pending = null; slot.pendingOffset = 0; }
    return true;
  }

  Future<void> _rebaseCurrent() async {
    final current = _current!;
    final frames = current.positionBase + math.max(0, _position - (current.timelineStart ?? 0)).toInt();
    _sink.reset(); _timelineBase = 0; _started = false;
    await current.rewind(frames); current.timelineStart = 0;
  }

  void _duration(_PcmItem slot) {
    final duration = slot.complete ? _framesDuration(slot.available ~/ 4)
      : slot.item.source?.metadata['duration_ms'] is num
        ? Duration(milliseconds: (slot.item.source!.metadata['duration_ms'] as num).toInt()) : null;
    if (duration == null || duration == slot.lastDuration) return;
    slot.lastDuration = duration;
    _emit(PcmAudioOutputEvent(id: slot.item.id, type: 'duration', duration: duration));
  }

  void _noticePosition({bool force = false}) {
    final slot = _current;
    if (slot == null) return;
    var frames = slot.positionBase + math.max(0, _position - (slot.timelineStart ?? 0)).toInt();
    if (slot.complete) frames = math.min(frames, slot.available ~/ 4);
    final position = _framesDuration(frames);
    final now = DateTime.now().microsecondsSinceEpoch;
    if (!force && (position.inMilliseconds == _lastPositionMs || now - _lastPositionNoticeUs < 100000)) return;
    _lastPositionMs = position.inMilliseconds; _lastPositionNoticeUs = now;
    _emit(PcmAudioOutputEvent(id: slot.item.id, type: 'position', position: position));
  }

  void _setState(String value) {
    if (_state == value) return;
    _state = value;
    _emit(PcmAudioOutputEvent(id: currentId, type: value));
  }

  void _emit(PcmAudioOutputEvent event) { if (!_disposed) _events.add(event); }

  Future<void> _serialize(Future<void> Function() operation, {CancellationToken? cancellationToken}) {
    if (_disposed) return Future.error(StateError('PCM output is disposed'));
    final token = MergedCancellationToken([_lifetime, ?cancellationToken]);
    final result = _tail.then((_) async {
      if (_disposed) return;
      try { token.throwIfCancelled(); await operation(); token.throwIfCancelled(); }
      catch (error) {
        token.throwIfCancelled();
        if (error is CancelledException) rethrow;
        if (!_failed) {
          _failed = true; _playRequested = false;
          try { _sink.pause(); } catch (_) { /* Preserve the original output failure. */ }
          _started = false;
          _setState('paused');
          _emit(PcmAudioOutputEvent(id: currentId, type: 'error', error: error));
        }
        rethrow;
      } finally { _updatePumpClock(); }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _closeItems() async {
    final current = _current, next = _next;
    _current = null; _next = null;
    await current?.close(); await next?.close();
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true; ++_generation;
    _lifetime.cancel(); _loadCancellation?.cancel(); _nextCancellation?.cancel();
    _timer?.cancel();
    _timer = null;
    return _disposal = _tail.then((_) async {
      _sink.close();
      await _closeItems();
      await _events.close();
    });
  }

  static Duration _framesDuration(int frames) =>
    Duration(microseconds: frames * Duration.microsecondsPerSecond ~/ 48000);
}

class _PcmItem {
  _PcmItem(this.item, this.file, this.length, int frames)
    : readPosition = frames * 4, queuedPosition = frames * 4, positionBase = frames;
  final PcmAudioOutputItem item;
  final RandomAccessFile file;
  final int length;
  int readPosition, queuedPosition, positionBase;
  int? timelineStart;
  Uint8List? pending;
  int pendingOffset = 0;
  Duration? lastDuration;
  bool _closed = false;
  PreparedAudioProgress? get progress => item.source?.progress;
  int get available => progress?.availableBytes ?? length;
  bool get complete => progress?.isComplete ?? true;
  bool get fedAll => complete && pending == null && queuedPosition >= available;

  static Future<_PcmItem> open(PcmAudioOutputItem item, Duration position,
      {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (!item.path.startsWith('/') || item.path.contains('\u0000') ||
        item.source?.encoding != PreparedAudioEncoding.pcmS16leStereo48000) {
      throw ArgumentError('PCM output requires a prepared48kHz stereo PCM buffer');
    }
    final file = await File(item.path).open();
    try {
      cancellationToken?.throwIfCancelled();
      final length = await file.length();
      cancellationToken?.throwIfCancelled();
      final frames = position.inMicroseconds * 48000 ~/ Duration.microsecondsPerSecond;
      await file.setPosition(frames * 4);
      cancellationToken?.throwIfCancelled();
      return _PcmItem(item, file, length, frames);
    } catch (_) { await file.close(); rethrow; }
  }

  Future<void> rewind(int frames) async {
    pending = null; pendingOffset = 0;
    readPosition = queuedPosition = frames * 4; positionBase = frames;
    await file.setPosition(readPosition);
  }

  Future<void> close() async { if (!_closed) { _closed = true; await file.close(); } }
}
