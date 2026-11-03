import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';
import 'audio_source.dart';
import 'engine.dart';
import 'standard_streaming_audio.dart';

/// FFmpeg consumes decrypted bytes on a worker while Dart owns the stream,
/// backpressure, cancellation and transient files. Native code has no network.
class FfmpegStreamingDecoder {
  const FfmpegStreamingDecoder();

  static bool get available => StandardStreamingAudio.available() != null;

  Future<PreparedAudioFile> prepareStream(Stream<List<int>> decrypted, {
    required Directory directory, Map<String, Object?> metadata = const {},
    CancellationToken? cancellationToken,
  }) => _prepare(directory: directory, metadata: metadata, input: decrypted,
    cancellationToken: cancellationToken);

  /// Other containers can use their normal seekable demuxer after staging.
  /// The returned PCM still becomes playable before full-file decoding ends.
  Future<PreparedAudioFile> prepareFile(PreparedAudioFile source, {required Directory directory,
      CancellationToken? cancellationToken}) =>
    _prepare(directory: directory, metadata: source.metadata, inputFile: source,
      cancellationToken: cancellationToken);

  Future<PreparedAudioFile> _prepare({required Directory directory,
    required Map<String, Object?> metadata, Stream<List<int>>? input,
    PreparedAudioFile? inputFile, CancellationToken? cancellationToken}) async {
    Directory? owned;
    _PcmDecodeProgress? progress;
    try {
      cancellationToken?.throwIfCancelled();
      final api = StandardStreamingAudio.available();
      if (api == null) throw const PlaybackEngineException('audio_decoder_unavailable',
        'The standard streaming decoder has not been built.');
      await directory.create(recursive: true);
      cancellationToken?.throwIfCancelled();
      final folder = owned = await directory.createTemp('spotify-pcm-stream-');
      cancellationToken?.throwIfCancelled();
      final path = '${folder.path}/audio.pcm';
      final handle = api.createDecoder(path, inputPath: inputFile?.path);
      final duration = metadata['duration_ms'];
      final estimated = duration is num && duration.isFinite && duration > 0
        ? (duration * 192).ceil() : 256 * 1024 * 1024;
      progress = _PcmDecodeProgress(api, handle, expectedBytes: estimated, inputFile: inputFile,
        cancellationToken: cancellationToken);
      progress.start(input);
      await progress.ready;
      cancellationToken?.throwIfCancelled();
      return PreparedAudioFile(path: path, metadata: metadata,
        encoding: PreparedAudioEncoding.pcmS16leStereo48000, progress: progress,
        release: () async {
          await progress!.close();
          if (await folder.exists()) await folder.delete(recursive: true);
        });
    } catch (_) {
      if (progress != null) await progress.close();
      else await inputFile?.close();
      if (owned != null && await owned.exists()) await owned.delete(recursive: true);
      rethrow;
    }
  }
}

Future<int> _runDecoder(String libraryPath, int address) =>
  Isolate.run(() => StandardStreamingAudio.worker(libraryPath).runDecoder(Pointer<Void>.fromAddress(address)));

class _PcmDecodeProgress implements PreparedAudioProgress {
  _PcmDecodeProgress(this._api, this._handle, {required this.expectedBytes, this.inputFile,
      CancellationToken? cancellationToken}) {
    // The owner may receive an error after first audio became ready. Retain it
    // for output/cache consumers without an unhandled background future.
    unawaited(_complete.future.catchError((Object _) {}));
    unawaited(_ready.future.catchError((Object _) {}));
    _parentCancellation = CancellationRegistration(cancellationToken, onCancel: (error) {
      _cancellation.cancel(error);
      // The prepared-file owner joins this same close future. Observe errors
      // immediately while cancellation unwinds the input/worker callbacks.
      close().ignore();
    });
  }
  final StandardStreamingAudio _api;
  Pointer<Void> _handle;
  final PreparedAudioFile? inputFile;
  @override final int expectedBytes;
  final _ready = Completer<void>(), _complete = Completer<void>();
  final _changes = StreamController<void>.broadcast();
  Completer<void> _pulse = Completer<void>();
  Timer? _timer;
  StreamIterator<List<int>>? _input;
  Future<void>? _feeding, _worker, _closing;
  Object? _inputError;
  int _available = 0;
  final _cancellation = CancellationToken();
  CancellationRegistration? _parentCancellation;
  bool get _closed => _cancellation.isCancelled;
  bool _finished = false;
  Object? _error;

  Future<void> get ready => _ready.future;
  @override int get availableBytes => _available;
  @override bool get isComplete => _finished && _error == null;
  @override Object? get error => _error;
  @override Future<void> get completion => _complete.future;
  @override Stream<void> get changes => _changes.stream;

  void start(Stream<List<int>>? input) {
    _timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _poll());
    _worker = _work();
    if (input != null) _feeding = _feed(input);
  }

  void _wake() {
    final old = _pulse;
    _pulse = Completer<void>();
    if (!old.isCompleted) old.complete();
  }

  void _poll() {
    if (_handle == nullptr || _finished) return;
    final bytes = _api.decoderAvailableBytes(_handle);
    if (bytes != _available) {
      _available = bytes;
      if (!_ready.isCompleted && bytes >= 4096) _ready.complete();
      if (!_changes.isClosed) _changes.add(null);
    }
    _wake();
  }

  Future<void> _feed(Stream<List<int>> input) async {
    final iterator = StreamIterator<List<int>>(input);
    _input = iterator;
    final scratch = calloc<Uint8>(64 * 1024);
    try {
      while (!_closed && await iterator.moveNext()) {
        final chunk = iterator.current;
        var offset = 0;
        while (!_closed && offset < chunk.length) {
          final status = _api.decoderStatus(_handle);
          // Some demuxers finish at an explicit end marker. Still consume and
          // validate the remaining finite HTTP/cache stream before completion.
          if (status == 2) break;
          if (status < 0) return;
          final count = (chunk.length - offset).clamp(0, 64 * 1024);
          scratch.asTypedList(count).setRange(0, count, chunk, offset);
          final accepted = _api.feedDecoder(_handle, scratch, count);
          offset += accepted;
          if (accepted == 0) await _pulse.future;
        }
      }
      if (!_closed && _handle != nullptr && _api.decoderStatus(_handle) < 2) {
        _api.endDecoder(_handle);
      }
    } catch (error) {
      if (!_closed) _inputError = error;
      if (_handle != nullptr) _api.cancelDecoder(_handle);
    } finally {
      calloc.free(scratch);
      await iterator.cancel();
      if (identical(_input, iterator)) _input = null;
    }
  }

  Future<void> _work() async {
    Object? failure;
    try {
      final result = await _runDecoder(_api.path, _handle.address);
      if (result < 0) {
        failure = _api.decoderError(_handle);
        _wake();
        await _input?.cancel();
      }
      await _feeding;
      failure = _inputError ?? failure;
      _poll();
      if (_closed) failure = _cancellation.exception;
      if (_available == 0) failure ??= const PlaybackEngineException('audio_decode', 'The audio stream contained no decoded samples.');
    } catch (error) {
      failure = _inputError ?? error;
      if (_handle != nullptr) _api.cancelDecoder(_handle);
      _wake();
      await _input?.cancel();
      await _feeding;
    } finally {
      _parentCancellation?.dispose(); _parentCancellation = null;
      if (_closed) failure = _cancellation.exception;
      _timer?.cancel(); _timer = null;
      // decoder_run has joined before the shared native handle is destroyed.
      if (_handle != nullptr) {
        _available = _api.decoderAvailableBytes(_handle);
        _api.destroyDecoder(_handle);
        _handle = nullptr;
      }
      await inputFile?.close();
      _error = failure;
      _finished = true;
      _wake();
      if (failure == null) {
        if (!_ready.isCompleted) _ready.complete();
        _complete.complete();
      } else {
        if (!_ready.isCompleted) _ready.completeError(failure);
        _complete.completeError(failure);
      }
      if (!_changes.isClosed) { _changes.add(null); unawaited(_changes.close()); }
    }
  }

  Future<void> close() => _closing ??= () async {
    _cancellation.cancel();
    if (_handle != nullptr) _api.cancelDecoder(_handle);
    _wake();
    await _input?.cancel();
    await _worker;
  }();
}
