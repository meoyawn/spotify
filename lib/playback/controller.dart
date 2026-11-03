import 'dart:async';

import 'client.dart';
import '../protocol/generated/es_context_player_state.pb.dart';
import '../protocol/generated/es_context_track.pb.dart';
import 'models.dart';
import 'requests.dart';

/// Owns local subscriptions; successful commands never manufacture player state.
class PlaybackController {
  PlaybackController(this.client);
  final ContextPlayerClient client;
  final _states = StreamController<PlaybackState>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  final _wraparounds = StreamController<PlaybackJson>.broadcast();
  StreamSubscription<ContextPlayerState>? _stateSubscription;
  StreamSubscription<Object>? _errorSubscription;
  Timer? _initialTimer;
  ContextPlayerState? _previous;
  ContextTrack? _savedMetadata;
  PlaybackState? _state;
  bool _playedInContext = false;
  bool _started = false;
  bool _closed = false;
  Future<void>? _closing;

  PlaybackState? get state => _state;
  Stream<PlaybackState> get states => _states.stream;
  Stream<Object> get errors => _errors.stream;
  Stream<PlaybackJson> get wraparounds => _wraparounds.stream;

  void start() {
    if (_closed) throw StateError('Playback controller is closed');
    if (_started) return;
    _started = true;
    _stateSubscription = client.watchState().listen(_receive, onError: _errors.add);
    _errorSubscription = client.watchErrors().listen(
      (error) => _errors.add(PlaybackServiceException.fromMessage(error)), onError: _errors.add);
  }

  void _publish(PlaybackState next) {
    if (_closed) return;
    _state = next;
    _states.add(next);
  }

  static ContextTrack? _track(ContextPlayerState? state) => state != null &&
      state.hasTrack() && state.track.hasContextTrack() ? state.track.contextTrack : null;
  static bool _isSavedTrack(ContextTrack? current, ContextTrack? previous) {
    final savedUri = current?.metadata['save_track.uri'];
    return savedUri?.isNotEmpty == true && previous?.uri.isNotEmpty == true &&
      current!.uid.isNotEmpty && previous!.uid.isNotEmpty && savedUri == previous.uri && current.uid == previous.uid;
  }

  void _receive(ContextPlayerState frame) {
    if (_closed) return;
    var projected = PlaybackState.fromMessage(frame);
    if (_isSavedTrack(_track(frame), _track(_previous))) _savedMetadata = _track(_previous);
    if (projected.item != null && _savedMetadata != null && _isSavedTrack(_track(frame), _savedMetadata)) {
      projected = projected.withItemMetadata({
        for (final key in const ['provider', 'smart-shuffle-signals'])
          if (_savedMetadata!.metadata.containsKey(key)) key: _savedMetadata!.metadata[key]!,
        ...projected.item!.metadata,
      });
    } else {
      _savedMetadata = null;
    }
    if (frame.timestamp.isZero) {
      _initialTimer ??= Timer(const Duration(milliseconds: 500), () => _publish(projected));
      return;
    }
    _initialTimer?.cancel();
    _initialTimer = null;
    _publish(projected);
    final previous = _previous;
    if (previous != null) {
      final sameContext = previous.contextUri == frame.contextUri && previous.sessionId == frame.sessionId;
      if (sameContext) {
        if (!frame.isPaused) _playedInContext = true;
        final samePlayback = previous.playbackId.length == frame.playbackId.length &&
          List.generate(frame.playbackId.length, (index) => previous.playbackId[index] == frame.playbackId[index]).every((same) => same);
        if (!samePlayback && _playedInContext && frame.isPaused &&
            frame.hasPositionAsOfTimestamp() && frame.positionAsOfTimestamp.value.isZero) {
          _wraparounds.add({'contextURI': frame.contextUri, 'previousItemURI': _track(previous)?.uri});
        }
      } else {
        _playedInContext = false;
      }
    }
    _previous = frame;
  }

  Future<void> play(PlaybackContext context, PlaybackOrigin origin,
      {PlaybackOptions options = const PlaybackOptions()}) => client.play(context, origin, options: options);
  Future<void> pause([PlaybackOrigin? origin]) => client.pause(origin);
  Future<void> resume([PlaybackOrigin? origin]) => client.resume(origin);
  Future<void> skipNext() => client.skipNext();
  Future<void> skipTo(PlaybackItemReference track) => client.skipTo(track);
  Future<void> skipPrevious() => client.skipPrevious();
  List<int>? get _playbackId {
    final hex = _state?.playbackId;
    return hex == null ? null : [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  }
  Future<void> seekTo(num milliseconds) => client.seekTo(milliseconds, onlyForPlaybackId: _playbackId);
  Future<void> seekBy(num milliseconds) => client.seekBy(milliseconds, onlyForPlaybackId: _playbackId);
  Future<void> setShuffle(bool enabled) => client.setShuffle(enabled);
  Future<void> setRepeat(PlaybackRepeat repeat) => client.setRepeat(repeat);
  Future<void> setSpeed(double speed) => client.setSpeed(speed);

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _initialTimer?.cancel();
    await Future.wait([if (_stateSubscription != null) _stateSubscription!.cancel(),
      if (_errorSubscription != null) _errorSubscription!.cancel()]);
    await Future.wait([_states.close(), _errors.close(), _wraparounds.close()]);
  }
}
