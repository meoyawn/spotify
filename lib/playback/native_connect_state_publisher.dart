import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:fixnum/fixnum.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../content/advertising.dart';
import '../protocol/generated/connect.pb.dart' as connect;
import '../protocol/generated/player.pb.dart' as player;
import '../protocol/generated/es_context_player_state.pb.dart' as local;
import '../protocol/generated/es_provided_track.pb.dart' as local;
import '../protocol/generated/es_restrictions.pb.dart' as local;
import '../protocol/native_connect_state_request.dart';
import '../protocol/native_pusher_connection.dart';
import '../protocol/request_builder.dart';
import 'context_player_backend.dart';
import 'native_playback_id.dart';

/// Publishes the real local player's state through Spotify's captured native
/// Connect PUT contract. Last.fm's existing Spotify connection consumes that
/// account state; this owner sends no direct Last.fm submissions.
class NativeConnectStatePublisher {
  NativeConnectStatePublisher({required this.backend, required this.deviceId,
    required this.deviceInfo, required this.origin, required this.template,
    required this.openPush, required this.send, required this.isReady,
    required this.onError}) {
    _states = backend.states.listen(_observe, onError: onError);
    final state = backend.currentState;
    if (state != null) _observe(state);
  }
  final ContextPlayerBackend backend;
  final String deviceId;
  final connect.DeviceInfo Function() deviceInfo;
  final String Function() origin;
  final RequestEnvelope Function() template;
  final Future<NativePusherConnection> Function() openPush;
  final Future<connect.Cluster> Function(RequestEnvelope request) send;
  final bool Function() isReady;
  final void Function(Object error) onError;
  late final StreamSubscription<local.ContextPlayerState> _states;
  Timer? _timer;
  Future<void>? _sending;
  local.ContextPlayerState? _pending;
  String? _lastKey, _registeredConnection;
  int? _lastPosition, _lastTimestamp;
  int _startedAt = 0, _revision = 0;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  bool get _closed => _token.isCancelled;
  bool _hasPlayed = false, _needsStateUpdates = true;
  // An app-owned context session, kept distinct from authentication, account
  // and per-track playback IDs. No original account/device identity is copied.
  final _sessionId = _newSessionId();

  void _observe(local.ContextPlayerState state) {
    if (_closed) return;
    final track = state.track.contextTrack;
    if (isAdvertisement(track.uri, track.metadata)) return;
    final playing = state.isPlaying && !state.isPaused && !state.isBuffering;
    if (playing && !_hasPlayed) {
      _hasPlayed = true;
      _startedAt = DateTime.now().millisecondsSinceEpoch;
    }
    // Restoring a paused bookmark is not a play and opens no reporting socket.
    if (!_hasPlayed) return;
    final position = state.positionAsOfTimestamp.value.toInt(), timestamp = state.timestamp.toInt();
    final delta = _lastPosition == null ? 0 : position - _lastPosition!;
    final elapsed = _lastTimestamp == null ? 0 : max(0, timestamp - _lastTimestamp!);
    final seek = _lastPosition != null && (delta < -250 || delta > elapsed + 750);
    _lastPosition = position; _lastTimestamp = timestamp;
    final key = jsonEncode([state.playbackId, track.uri, track.uid,
      state.isPlaying, state.isPaused, state.isBuffering, state.duration.value.toInt(),
      state.contextUri, state.queueRevision.toString(), state.options.toProto3Json(),
      track.metadata['title'], track.metadata['artist_name'], track.metadata['album_title']]);
    if (key == _lastKey && !seek) return;
    _lastKey = key;
    _pending = state;
    ++_revision;
    // Original manager has a 300 ms coalescing path. Keep one latest state and
    // one actual request; position notifications alone never produce traffic.
    _timer ??= Timer(const Duration(milliseconds: 300), () {
      _timer = null;
      unawaited(_flush());
    });
  }

  void deviceChanged() {
    if (_closed || !_hasPlayed) return;
    _lastKey = null;
    final state = backend.currentState;
    if (state != null) _observe(state);
  }

  Future<void> _flush() {
    if (_closed || !isReady() || _pending == null) return Future.value();
    if (_sending != null) return _sending!;
    late final Future<void> work;
    work = (() async {
      try {
        // The runtime owns the shared socket; this token owns only our wait.
        final push = await openPush().asCancellable(_token);
        if (_closed || !isReady() || push.isClosed) return;
        while (!_closed && isReady() && _pending != null) {
          final connection = push.connectionId;
          final fresh = _registeredConnection != connection;
          if (!fresh && !_needsStateUpdates) return;
          final state = _pending!, revision = _revision;
          final selected = state.hasTrack() && state.track.contextTrack.uri.isNotEmpty;
          final active = selected && _hasPlayed;
          final model = connect.PutStateRequest(
            device: connect.Device(deviceInfo: deviceInfo(), playerState: _project(state)),
            memberType: connect.MemberType.CONNECT_STATE, isActive: active,
            putStateReason: fresh ? connect.PutStateReason.NEW_CONNECTION : connect.PutStateReason.PLAYER_STATE_CHANGED,
            startedPlayingAt: Int64(active ? _startedAt : 0),
            clientSideTimestamp: Int64(DateTime.now().millisecondsSinceEpoch));
          final plan = NativeConnectStatePutRequestPlan(origin: origin(), deviceId: deviceId,
            request: model, template: template().withCancellation(_token), connectionId: connection);
          final cluster = await send(plan.request);
          if (_closed || !isReady() || push.isClosed) return;
          _registeredConnection = connection;
          if (cluster.hasNeedsStateUpdates()) _needsStateUpdates = cluster.needsStateUpdates;
          if (_revision == revision) _pending = null;
          if (_pending != null && _timer != null) return;
        }
      } catch (error) {
        // Reporting failure does not stop audio or create background retries.
        // The latest real transition remains available for the next event.
        if (!_closed) onError(error);
      }
    })().whenComplete(() { if (identical(_sending, work)) _sending = null; });
    return _sending = work;
  }

  player.PlayerState _project(local.ContextPlayerState state) {
    player.ProvidedTrack track(local.ProvidedTrack value) => player.ProvidedTrack(
      uri: value.contextTrack.uri, uid: value.contextTrack.uid,
      metadata: value.contextTrack.metadata.entries,
      removed: value.removed, blocked: value.blocked,
      // These entries are supplied by the local Context queue.
      provider: value.provider == 'dart' ? 'context' : value.provider);
    final playing = state.isPlaying && !state.isPaused && !state.isBuffering;
    return player.PlayerState(timestamp: state.timestamp,
      contextUri: state.contextUri, contextUrl: state.contextUrl,
      contextRestrictions: _restrictions(state.contextRestrictions),
      playOrigin: player.PlayOrigin.fromBuffer(state.playOrigin.writeToBuffer()),
      index: state.hasIndex() ? player.ContextIndex(page: state.index.page.toInt(), track: state.index.track.toInt()) : null,
      track: state.hasTrack() ? track(state.track) : null,
      playbackId: state.playbackId.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      playbackSpeed: playing ? (state.hasPlaybackSpeed() ? state.playbackSpeed.value : 1) : 0,
      positionAsOfTimestamp: state.positionAsOfTimestamp.value,
      duration: state.duration.value, isPlaying: state.isPlaying,
      isPaused: state.isPaused, isBuffering: state.isBuffering,
      isSystemInitiated: state.isSystemInitiated,
      options: player.ContextPlayerOptions.fromBuffer(state.options.writeToBuffer()),
      restrictions: _restrictions(state.restrictions),
      suppressions: player.Suppressions(providers: state.suppressions),
      // The app does not advertise full remote queue/transfer support.
      prevTracks: state.prevTracks.reversed.take(1).map(track).toList().reversed,
      nextTracks: state.nextTracks.take(1).map(track),
      contextMetadata: state.contextMetadata.entries, pageMetadata: state.pageMetadata.entries,
      sessionId: state.hasTrack() && state.sessionId.isEmpty ? _sessionId : state.sessionId,
      queueRevision: state.queueRevision.toString(),
      playbackQuality: state.hasPlaybackQuality()
        ? (player.PlaybackQuality.fromBuffer(state.playbackQuality.writeToBuffer())..unknownFields.clear()) : null,
      signals: state.signals, sessionCommandId: state.sessionCommandId);
  }

  Future<void> close() async {
    _token.cancel();
    _timer?.cancel(); _timer = null;
    _pending = null;
    await _states.cancel();
  }
}

// These two original schemas use different tags after field21. Copy reasons
// by semantic field identity; their serialized message bytes are not aliases.
player.Restrictions _restrictions(local.Restrictions value) => player.Restrictions(
      disallowPausingReasons: value.disallowPausingReasons,
      disallowResumingReasons: value.disallowResumingReasons,
      disallowSeekingReasons: value.disallowSeekingReasons,
      disallowPeekingPrevReasons: value.disallowPeekingPrevReasons,
      disallowPeekingNextReasons: value.disallowPeekingNextReasons,
      disallowSkippingPrevReasons: value.disallowSkippingPrevReasons,
      disallowSkippingNextReasons: value.disallowSkippingNextReasons,
      disallowTogglingRepeatContextReasons: value.disallowTogglingRepeatContextReasons,
      disallowTogglingRepeatTrackReasons: value.disallowTogglingRepeatTrackReasons,
      disallowTogglingShuffleReasons: value.disallowTogglingShuffleReasons,
      disallowSetQueueReasons: value.disallowSetQueueReasons,
      disallowInterruptingPlaybackReasons: value.disallowInterruptingPlaybackReasons,
      disallowTransferringPlaybackReasons: value.disallowTransferringPlaybackReasons,
      disallowRemoteControlReasons: value.disallowRemoteControlReasons,
      disallowInsertingIntoNextTracksReasons: value.disallowInsertingIntoNextTracksReasons,
      disallowInsertingIntoContextTracksReasons: value.disallowInsertingIntoContextTracksReasons,
      disallowReorderingInNextTracksReasons: value.disallowReorderingInNextTracksReasons,
      disallowReorderingInContextTracksReasons: value.disallowReorderingInContextTracksReasons,
      disallowRemovingFromNextTracksReasons: value.disallowRemovingFromNextTracksReasons,
      disallowRemovingFromContextTracksReasons: value.disallowRemovingFromContextTracksReasons,
      disallowUpdatingContextReasons: value.disallowUpdatingContextReasons,
      disallowAddToQueueReasons: value.disallowAddToQueueReasons,
      disallowSettingPlaybackSpeedReasons: value.disallowSettingPlaybackSpeedReasons,
      disallowSettingModes: value.disallowSettingModes.entries.map((e) => MapEntry(e.key, player.ModeRestrictions.fromBuffer(e.value.writeToBuffer()))),
      disallowSignals: value.disallowSignals.entries.map((e) => MapEntry(e.key, player.RestrictionReasons.fromBuffer(e.value.writeToBuffer()))),
      disallowPlayAsNextInQueueReasons: value.disallowPlayAsNextInQueueReasons,
      disallowSleepTimerClearReasons: value.disallowSleepTimerClearReasons,
      disallowSleepTimerDurationReasons: value.disallowSleepTimerDurationReasons,
      disallowSleepTimerEndOfTrackReasons: value.disallowSleepTimerEndOfTrackReasons,
      disallowAddToQueueTrackReasons: value.disallowAddToQueueTrackReasons,
      disallowTapToPlayTrackInNextTracksReasons: value.disallowTapToPlayTrackInNextTracksReasons,
      disallowReorderingTrackInNextTracksReasons: value.disallowReorderingTrackInNextTracksReasons,
      disallowReorderingEpisodeInNextTracksReasons: value.disallowReorderingEpisodeInNextTracksReasons,
      disallowReorderingEnqueuedTrackInNextTracksReasons: value.disallowReorderingEnqueuedTrackInNextTracksReasons,
      disallowReorderingEnqueuedEpisodeInNextTracksReasons: value.disallowReorderingEnqueuedEpisodeInNextTracksReasons,
      disallowViewingQueueReasons: value.disallowViewingQueueReasons,
      disallowViewingOrderedTracksInNextTracksReasons: value.disallowViewingOrderedTracksInNextTracksReasons,
    );

String _newSessionId() {
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var value = BigInt.zero;
  for (final byte in NativePlaybackId().bytes) { value = (value << 8) | BigInt.from(byte); }
  var result = '';
  while (value > BigInt.zero) {
    result = alphabet[(value % BigInt.from(62)).toInt()] + result;
    value ~/= BigInt.from(62);
  }
  return result.padLeft(22, '0');
}
