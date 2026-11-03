import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';
import 'audio_source.dart';
import 'ffmpeg_streaming_decoder.dart';
import 'spotify_audio_decrypt.dart';

enum SpotifyAudioContainer { ogg, mp3, mp4, flac }

/// Owns a finite decoded-container file for the standard platform decoder.
/// Requests, account policy, file selection and authorized key acquisition
/// belong to the caller; this owner never opens a socket or invokes a process.
class SpotifyAudioStager {
  const SpotifyAudioStager({required this.directory, this.streamOgg = false, this.cancellationToken});
  final Directory directory;
  final bool streamOgg;
  final CancellationToken? cancellationToken;

  Future<PreparedAudioFile> stage(Stream<List<int>> input, {
    required int encryptedLength,
    required SpotifyAudioDecryptor decryptor,
    required SpotifyAudioContainer container,
    Map<String, Object?> metadata = const {},
    CancellationToken? cancellationToken,
  }) async {
    final token = MergedCancellationToken([?this.cancellationToken, ?cancellationToken]);
    token.throwIfCancelled();
    if (encryptedLength <= 0) throw RangeError.value(encryptedLength, 'encryptedLength');
    if (streamOgg && container == SpotifyAudioContainer.ogg && FfmpegStreamingDecoder.available) {
      return const FfmpegStreamingDecoder().prepareStream(
        decryptor.transform(_checkedLength(input, encryptedLength, token), spotifyOgg: true),
        directory: directory, metadata: metadata, cancellationToken: token);
    }
    await directory.create(recursive: true);
    token.throwIfCancelled();
    final owned = await directory.createTemp('spotify-audio-');
    final file = File('${owned.path}/audio.${container.name}');
    final output = file.openWrite();
    try {
      token.throwIfCancelled();
      await output.addStream(decryptor.transform(_checkedLength(input, encryptedLength, token),
        spotifyOgg: container == SpotifyAudioContainer.ogg));
      await output.close();
      token.throwIfCancelled();
      if (await file.length() == 0) throw const FormatException('Audio container is empty');
      return PreparedAudioFile(path: file.path, metadata: metadata,
        release: () async { if (await owned.exists()) await owned.delete(recursive: true); });
    } catch (_) {
      try { await output.close(); } catch (_) { /* Preserve the source failure. */ }
      if (await owned.exists()) await owned.delete(recursive: true);
      rethrow;
    }
  }

  Stream<List<int>> _checkedLength(Stream<List<int>> input, int expected, CancellationToken token) async* {
    token.throwIfCancelled();
    var received = 0;
    final iterator = StreamIterator(input);
    Future<void>? cancellation;
    Future<void> cancelInput() {
      final pending = cancellation ??= iterator.cancel();
      // Cancellation may make this future fail before the loop reaches its
      // finally block. Observe it now and still join the original future there.
      pending.ignore();
      return pending;
    }
    final cleanup = CancellationRegistration(token, onCancel: (_) { unawaited(cancelInput()); });
    try {
    while (true) {
      token.throwIfCancelled();
      if (!await iterator.moveNext().asCancellable(token)) break;
      token.throwIfCancelled();
      final chunk = iterator.current;
      if (chunk.length > expected - received) throw const FormatException('Audio body exceeds its declared length');
      received += chunk.length;
      yield chunk;
    }
    token.throwIfCancelled();
    if (received != expected) throw const FormatException('Audio body ended before its declared length');
    } finally { cleanup.dispose(); await cancelInput(); }
  }
}
