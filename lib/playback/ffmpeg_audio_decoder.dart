import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';
import 'audio_source.dart';
import 'engine.dart';

typedef _DecodeNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, UintPtr, Pointer<Void>);
typedef _Decode = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Void>);
typedef _CreateNative = Pointer<Void> Function();
typedef _Create = Pointer<Void> Function();
typedef _ControlNative = Void Function(Pointer<Void>);
typedef _Control = void Function(Pointer<Void>);

/// Standard FFmpeg decoding of an already decrypted, caller-owned Spotify
/// container. A Dart isolate keeps the synchronous codec off the UI isolate;
/// it stays in this Flutter process and owns no player/session/queue logic.
class FfmpegAudioDecoder {
  const FfmpegAudioDecoder({this.libraryPath});
  final String? libraryPath;

  /// Takes ownership of [source] and returns a transient PCM WAV lease for the
  /// existing platform audio output. Failure closes the transferred lease.
  Future<PreparedAudioFile> prepare(PreparedAudioFile source, {Directory? directory,
      CancellationToken? cancellationToken}) async {
    Directory? owned;
    CancellationRegistration? cancellation;
    Pointer<Void> control = nullptr;
    _Control? destroy;
    try {
      cancellationToken?.throwIfCancelled();
      if (!Platform.isMacOS) return source;
      final path = libraryPath ?? _libraryPath();
      final library = DynamicLibrary.open(path);
      final create = library.lookupFunction<_CreateNative, _Create>('spotify_ffmpeg_cancellation_create');
      final stop = library.lookupFunction<_ControlNative, _Control>('spotify_ffmpeg_cancellation_request');
      destroy = library.lookupFunction<_ControlNative, _Control>('spotify_ffmpeg_cancellation_destroy');
      control = create();
      if (control == nullptr) throw const PlaybackEngineException('audio_decode', 'Could not allocate the decoder.');
      cancellation = CancellationRegistration(cancellationToken, onCancel: (_) => stop(control));
      final parent = directory ?? Directory.systemTemp;
      await parent.create(recursive: true);
      cancellationToken?.throwIfCancelled();
      owned = await parent.createTemp('spotify-pcm-');
      cancellationToken?.throwIfCancelled();
      final output = File('${owned.path}/audio.wav');
      final inputPath = source.path, outputPath = output.path;
      // Join the native worker after requesting its cooperative interrupt;
      // killing an isolate here could leave file handles and FFmpeg alive.
      await _decodeAsync(path, inputPath, outputPath, control.address);
      cancellationToken?.throwIfCancelled();
      // Decoding has relinquished the compressed input. The output lease only
      // needs the PCM file, so do not retain both containers in the cache.
      await source.close();
      cancellationToken?.throwIfCancelled();
      final folder = owned;
      return PreparedAudioFile(path: outputPath, metadata: source.metadata,
        release: () async {
          if (await folder.exists()) await folder.delete(recursive: true);
        });
    } catch (_) {
      try { if (owned != null && await owned.exists()) await owned.delete(recursive: true); }
      finally { await source.close(); }
      cancellationToken?.throwIfCancelled();
      rethrow;
    } finally {
      cancellation?.dispose();
      if (control != nullptr) destroy?.call(control);
    }
  }
}

// Keep the isolate closure in a scope containing only sendable path strings;
// the prepared source's release callback may capture the Dart player/session.
Future<void> _decodeAsync(String libraryPath, String inputPath, String outputPath, int cancellation) =>
  Isolate.run(() => _decode(libraryPath, inputPath, outputPath, cancellation));

String _libraryPath() {
  final bundled = '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libspotify_ffmpeg.dylib';
  if (File(bundled).existsSync()) return bundled;
  final development = '${Directory.current.path}/.local/native/libspotify_ffmpeg.dylib';
  if (File(development).existsSync()) return development;
  throw const PlaybackEngineException('audio_decoder_unavailable',
    'The in-process FFmpeg decoder has not been built and embedded.');
}

void _decode(String libraryPath, String inputPath, String outputPath, int cancellation) {
  final library = DynamicLibrary.open(libraryPath);
  final decode = library.lookupFunction<_DecodeNative, _Decode>('spotify_ffmpeg_decode_file_cancellable');
  final input = inputPath.toNativeUtf8(), output = outputPath.toNativeUtf8();
  final error = calloc<Uint8>(1024).cast<Utf8>();
  try {
    final status = decode(input, output, error, 1024, Pointer<Void>.fromAddress(cancellation));
    if (status < 0) {
      throw PlaybackEngineException('audio_decode', 'Could not decode Spotify audio: ${error.toDartString()} ($status)');
    }
  } finally { calloc.free(error); calloc.free(input); calloc.free(output); }
}
