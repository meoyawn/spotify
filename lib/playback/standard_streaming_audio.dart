import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'engine.dart';

typedef _CreateDecoderN = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CreateDecoder = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _HandleIntN = Int32 Function(Pointer<Void>);
typedef _HandleInt = int Function(Pointer<Void>);
typedef _HandleVoidN = Void Function(Pointer<Void>);
typedef _HandleVoid = void Function(Pointer<Void>);
typedef _HandleCountN = Uint64 Function(Pointer<Void>);
typedef _HandleCount = int Function(Pointer<Void>);
typedef _HandleSizeN = UintPtr Function(Pointer<Void>);
typedef _HandleSize = int Function(Pointer<Void>);
typedef _WriteN = UintPtr Function(Pointer<Void>, Pointer<Uint8>, UintPtr);
typedef _Write = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _ErrorN = Int32 Function(Pointer<Void>, Pointer<Utf8>, UintPtr);
typedef _Error = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _CreateSinkN = Int32 Function(Pointer<Pointer<Void>>);
typedef _CreateSink = int Function(Pointer<Pointer<Void>>);
typedef _VolumeN = Int32 Function(Pointer<Void>, Float);
typedef _Volume = int Function(Pointer<Void>, double);

/// Standard FFmpeg and Core Audio primitives. This ABI has no track identities,
/// queue decisions, URLs, credentials or Spotify request construction.
class StandardStreamingAudio {
  StandardStreamingAudio._(this.path) : _library = DynamicLibrary.open(path);
  final String path;
  final DynamicLibrary _library;
  static StandardStreamingAudio? _shared;

  static StandardStreamingAudio? available() {
    if (!Platform.isMacOS) return null;
    if (_shared != null) return _shared;
    final bundled = '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libspotify_streaming.dylib';
    String? path = File(bundled).existsSync() ? bundled : null;
    // macOS changes a sandboxed app's cwd to its container. Development
    // libraries belong to the actual Flutter checkout, not that container.
    if (path == null) {
      final roots = <String>{Directory.current.path,
        if (Platform.environment['PWD'] case final String cwd) cwd};
      var ancestor = File(Platform.resolvedExecutable).parent;
      for (var depth = 0; depth < 12; depth++) {
        roots.add(ancestor.path);
        if (ancestor.parent.path == ancestor.path) break;
        ancestor = ancestor.parent;
      }
      for (final root in roots) {
        if (!File('$root/pubspec.yaml').existsSync() ||
            !File('$root/native/ffmpeg/streaming.h').existsSync()) continue;
        final development = '$root/.local/native/libspotify_streaming.dylib';
        if (File(development).existsSync()) { path = development; break; }
      }
    }
    if (path == null) return null;
    try { return _shared = StandardStreamingAudio._(path); }
    on ArgumentError {
      // A sandbox can inspect a development file but cannot map its code.
      // Bundled build failures remain visible; an unembedded development
      // primitive leaves the existing finite decoder available until built.
      if (path == bundled) rethrow;
      return null;
    }
  }

  factory StandardStreamingAudio.worker(String path) => StandardStreamingAudio._(path);

  late final _createDecoder = _library.lookupFunction<_CreateDecoderN, _CreateDecoder>('spotify_stream_decoder_create');
  late final runDecoder = _library.lookupFunction<_HandleIntN, _HandleInt>('spotify_stream_decoder_run');
  late final feedDecoder = _library.lookupFunction<_WriteN, _Write>('spotify_stream_decoder_feed');
  late final endDecoder = _library.lookupFunction<_HandleIntN, _HandleInt>('spotify_stream_decoder_end_input');
  late final cancelDecoder = _library.lookupFunction<_HandleVoidN, _HandleVoid>('spotify_stream_decoder_cancel');
  late final decoderAvailableBytes = _library.lookupFunction<_HandleCountN, _HandleCount>('spotify_stream_decoder_available_bytes');
  late final decoderStatus = _library.lookupFunction<_HandleIntN, _HandleInt>('spotify_stream_decoder_status');
  late final _decoderError = _library.lookupFunction<_ErrorN, _Error>('spotify_stream_decoder_error');
  late final destroyDecoder = _library.lookupFunction<_HandleVoidN, _HandleVoid>('spotify_stream_decoder_destroy');

  Pointer<Void> createDecoder(String outputPath, {String? inputPath}) {
    final output = outputPath.toNativeUtf8();
    final input = inputPath?.toNativeUtf8();
    final result = calloc<Pointer<Void>>();
    try {
      final status = _createDecoder(output, input ?? nullptr, result);
      if (status < 0 || result.value == nullptr) {
        throw PlaybackEngineException('audio_decode', 'Could not open the streaming decoder ($status).');
      }
      return result.value;
    } finally {
      calloc.free(output);
      if (input != null) calloc.free(input);
      calloc.free(result);
    }
  }

  PlaybackEngineException decoderError(Pointer<Void> handle) {
    final buffer = calloc<Uint8>(512).cast<Utf8>();
    try {
      final status = _decoderError(handle, buffer, 512);
      return PlaybackEngineException('audio_decode',
        'Could not decode the audio stream: ${buffer.toDartString()} ($status).');
    } finally { calloc.free(buffer); }
  }

  late final _createSink = _library.lookupFunction<_CreateSinkN, _CreateSink>('spotify_stream_sink_create');
  late final writeSink = _library.lookupFunction<_WriteN, _Write>('spotify_stream_sink_write');
  late final writableSink = _library.lookupFunction<_HandleSizeN, _HandleSize>('spotify_stream_sink_writable_bytes');
  late final startSink = _library.lookupFunction<_HandleIntN, _HandleInt>('spotify_stream_sink_start');
  late final pauseSink = _library.lookupFunction<_HandleIntN, _HandleInt>('spotify_stream_sink_pause');
  late final resetSink = _library.lookupFunction<_HandleIntN, _HandleInt>('spotify_stream_sink_reset');
  late final positionSink = _library.lookupFunction<_HandleCountN, _HandleCount>('spotify_stream_sink_position_frames');
  late final enqueuedSink = _library.lookupFunction<_HandleCountN, _HandleCount>('spotify_stream_sink_enqueued_frames');
  late final volumeSink = _library.lookupFunction<_VolumeN, _Volume>('spotify_stream_sink_set_volume');
  late final errorSink = _library.lookupFunction<_HandleIntN, _HandleInt>('spotify_stream_sink_error');
  late final disposeSink = _library.lookupFunction<_HandleVoidN, _HandleVoid>('spotify_stream_sink_dispose');

  Pointer<Void> createSink() {
    final result = calloc<Pointer<Void>>();
    try {
      final status = _createSink(result);
      if (status != 0 || result.value == nullptr) {
        throw PlaybackEngineException('audio_output', 'Could not open Core Audio output ($status).');
      }
      return result.value;
    } finally { calloc.free(result); }
  }
}

/// One standard PCM device. The Dart output owner serializes calls and chooses
/// the bytes to enqueue. Native callbacks only return consumed buffer capacity.
class StandardPcmSink {
  StandardPcmSink(StandardStreamingAudio api) : _api = api, _handle = api.createSink() {
    _scratch = calloc<Uint8>(_capacity);
  }
  final StandardStreamingAudio _api;
  final Pointer<Void> _handle;
  static const _capacity = 128 * 1024;
  late final Pointer<Uint8> _scratch;
  bool _closed = false;

  int get writableBytes => _closed ? 0 : _api.writableSink(_handle);
  int get positionFrames => _closed ? 0 : _api.positionSink(_handle);
  int get enqueuedFrames => _closed ? 0 : _api.enqueuedSink(_handle);

  int write(Uint8List bytes, [int offset = 0]) {
    if (_closed) throw StateError('PCM output is closed');
    var count = bytes.length - offset;
    if (count > _capacity) count = _capacity;
    count -= count % 4;
    if (count == 0) return 0;
    _scratch.asTypedList(count).setRange(0, count, bytes, offset);
    final accepted = _api.writeSink(_handle, _scratch, count);
    _check(_api.errorSink(_handle));
    return accepted;
  }

  void start() { if (!_closed) _check(_api.startSink(_handle)); }
  void pause() { if (!_closed) _check(_api.pauseSink(_handle)); }
  void reset() { if (!_closed) _check(_api.resetSink(_handle)); }
  void setVolume(double value) { if (!_closed) _check(_api.volumeSink(_handle, value)); }

  void close() {
    if (_closed) return;
    _closed = true;
    _api.disposeSink(_handle);
    calloc.free(_scratch);
  }

  static void _check(int status) {
    if (status != 0) throw PlaybackEngineException('audio_output', 'Core Audio output failed ($status).');
  }
}
