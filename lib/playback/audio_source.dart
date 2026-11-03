import 'dart:async';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'native_playback_id.dart';

enum PreparedAudioEncoding { container, pcmS16leStereo48000 }

/// A decoder-owned, progressively written PCM file. Bytes below availableBytes
/// are flushed and immutable. Completion reports the actual decoder result;
/// a partial file is never silently treated as a complete song.
abstract interface class PreparedAudioProgress {
  int get availableBytes;
  int get expectedBytes;
  bool get isComplete;
  Object? get error;
  Future<void> get completion;
  Stream<void> get changes;
}

/// A caller-owned streaming buffer ready for the standard device output.
/// Release runs only after the audio output has relinquished this file.
final class PreparedAudioFile {
  PreparedAudioFile({required this.path, Map<String, Object?> metadata = const {},
    this.release, PreparedAudioEncoding encoding = PreparedAudioEncoding.container, this.progress})
    : _encoding = encoding, metadata = Map.unmodifiable(metadata);

  final String path;
  final Map<String, Object?> metadata;
  final Future<void> Function()? release;
  final PreparedAudioEncoding? _encoding;
  PreparedAudioEncoding get encoding => _encoding ?? PreparedAudioEncoding.container;
  final PreparedAudioProgress? progress;
  Future<void>? _closing;
  int? _retainedReferences;

  /// A decoder or output migration can borrow the same buffer without
  /// releasing the player's lease or adopting/copying another cache file.
  PreparedAudioFile retain() {
    if (_closing != null) throw StateError('The audio buffer lease is closed');
    _retainedReferences = (_retainedReferences ?? 1) + 1;
    return PreparedAudioFile(path: path, metadata: metadata, encoding: encoding,
      progress: progress, release: _releaseReference);
  }

  Future<void> _releaseReference() async {
    _retainedReferences = (_retainedReferences ?? 1) - 1;
    if (_retainedReferences == 0) await release?.call();
  }

  Future<void> close() => _closing ??= Future<void>.sync(_releaseReference);
}

/// Resolves an explicitly selected Spotify track/episode into an owned local
/// file. No resolver or remote transport is installed by default.
typedef SpotifyAudioSourceResolver = Future<PreparedAudioFile> Function(String spotifyUri,
  {CancellationToken? cancellationToken});

final class SpotifyAudioSourceRequest {
  SpotifyAudioSourceRequest({required this.uri, required List<int> playbackId, this.prefetch = false,
    this.cancellationToken})
    : playbackId = NativePlaybackId(given: playbackId).bytes;
  final String uri;
  final Uint8List playbackId;
  final bool prefetch;
  final CancellationToken? cancellationToken;
}

typedef SpotifyAudioRequestResolver = Future<PreparedAudioFile> Function(SpotifyAudioSourceRequest request);
