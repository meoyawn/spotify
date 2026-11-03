typedef PlayerJson = Map<String, Object?>;

class PlaybackEngineException implements Exception {
  const PlaybackEngineException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

/// Dart owns playback commands, state, and lifecycle. Decoder/output adapters
/// report real device events; accepting a command does not assert playback.
abstract interface class PlaybackEngine {
  Stream<PlayerJson> get events;
  Future<PlayerJson> command(String command, [PlayerJson arguments = const {}]);
  Future<void> close();
}

/// Internal queue preparation; selected items and all protocol stay in Dart.
abstract interface class QueuePreparingPlaybackEngine implements PlaybackEngine {}

/// A request owner can withdraw a current/upcoming source while its key job
/// waits. A shared URI/purpose remains wanted if another load still owns it.
abstract interface class AudioSourceOwner implements PlaybackEngine {
  bool wantsAudioSource(String uri, {required bool prefetch});
  bool isCurrentAudioSourceEvent(PlayerJson event);
  Stream<void> get audioSourceChanges;
}
