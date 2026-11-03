import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fixnum/fixnum.dart';

import '../content/advertising.dart';

import '../protocol/esperanto.dart';
import '../protocol/generated/es_context.pb.dart';
import '../protocol/generated/es_context_player_error.pb.dart';
import '../protocol/generated/es_context_player_options.pb.dart';
import '../protocol/generated/es_context_player_state.pb.dart';
import '../protocol/generated/es_context_track.pb.dart';
import '../protocol/generated/es_get_state_request.pb.dart';
import '../protocol/generated/es_optional.pb.dart';
import '../protocol/generated/es_play.pb.dart';
import '../protocol/generated/es_prepare_play.pb.dart';
import '../protocol/generated/es_provided_track.pb.dart';
import '../protocol/generated/es_response_with_reasons.pb.dart';
import '../protocol/generated/es_seek_to.pb.dart';
import '../protocol/generated/es_set_options.pb.dart';
import '../protocol/generated/es_set_shuffling_context.pb.dart';
import '../protocol/generated/es_skip_next.pb.dart';
import '../protocol/generated/es_skip_prev.pb.dart';
import 'client.dart';
import 'engine.dart';
import 'native_playback_id.dart';
import 'requests.dart';

/// Real local ContextPlayer owner: queue decisions submit native load commands;
/// only native Player events change playing/paused/buffering/position state.
class ContextPlayerBackend {
  ContextPlayerBackend(this.engine, {Random? random}) : _random = random ?? Random() {
    _subscription = engine.events.listen(_event, onError: _report);
  }
  final PlaybackEngine engine;
  final Random _random;
  final _states = StreamController<ContextPlayerState>.broadcast(sync: true);
  final _errors = StreamController<ContextPlayerError>.broadcast(sync: true);
  late final StreamSubscription<PlayerJson> _subscription;
  ContextPlayerState? _state;
  ContextPlayerState? get currentState => _state;
  Stream<ContextPlayerState> get states => _states.stream;
  Context _context = Context();
  List<ContextTrack> _queue = [];
  List<int> _order = [];
  int _cursor = 0;
  int _loadId = 0;
  int? _deferredPosition;
  int? _preparedIndex;
  String? _preparationPlaybackId;
  PlayerJson _nativeRestrictions = {};
  bool _closed = false;
  var _options = ContextPlayerOptions(playbackSpeed: 1);
  final _pendingConnections = <int, Completer<void>>{};
  String get _uri => _queue.isEmpty ? '' : _queue[_order[_cursor]].uri;

  void register(EsperantoDispatcher dispatcher) {
    dispatcher.register(ContextPlayerClient.serviceId, EsperantoService(single: {
      'Play': (bytes) => _reply(() => _play(PlayRequest.fromBuffer(bytes))),
      'Pause': (_) => _reply(() async {
        _guard(_state?.restrictions.disallowPausingReasons ?? []);
        await engine.command('pause');
      }),
      'Resume': (_) => _reply(() async {
        _guard(_state?.restrictions.disallowResumingReasons ?? []);
        if (_queue.isNotEmpty && _state?.isPlaying == false && _state?.isBuffering != true) {
          await _loadAt(_cursor, position: _deferredPosition ?? 0);
        } else {
          await engine.command('play');
        }
      }),
      'SkipNext': (bytes) => _reply(() => _next(SkipNextRequest.fromBuffer(bytes))),
      'SkipPrev': (bytes) => _reply(() => _previous(SkipPrevRequest.fromBuffer(bytes))),
      'SeekTo': (bytes) => _reply(() => _seek(SeekToRequest.fromBuffer(bytes))),
      'SetShufflingContext': (bytes) => _reply(() async {
        _guard(_state?.restrictions.disallowTogglingShuffleReasons ?? []);
        _shuffle(SetShufflingContextRequest.fromBuffer(bytes).shufflingContext);
        _publishOptions();
      }),
      'SetOptions': (bytes) => _reply(() async => _setOptions(SetOptionsRequest.fromBuffer(bytes))),
    }, streaming: {
      'GetState': (bytes) {
        final request = GetStateRequest.fromBuffer(bytes);
        return Stream<ContextPlayerState>.multi((sink) {
          void send(ContextPlayerState frame) {
            final result = frame.deepCopy();
            final previous = max(0, request.prevTracksCap.value.toInt());
            final next = max(0, request.nextTracksCap.value.toInt());
            if (result.prevTracks.length > previous) result.prevTracks.removeRange(0, result.prevTracks.length - previous);
            if (result.nextTracks.length > next) result.nextTracks.removeRange(next, result.nextTracks.length);
            sink.addSync(result);
          }
          final subscription = _states.stream.listen(send, onError: sink.addErrorSync, onDone: sink.closeSync);
          if (_state case final frame?) send(frame);
          sink.onCancel = subscription.cancel;
        }).map((state) => state.writeToBuffer());
      },
      'GetError': (_) => _errors.stream.map((error) => error.writeToBuffer()),
    }));
  }

  Future<List<int>> _reply(Future<void> Function() operation) async {
    try {
      if (_closed) throw const PlaybackEngineException('engine_closed', 'Playback engine is closed.');
      await operation();
      return ResponseWithReasons(error: ResponseWithReasons_Error.OK).writeToBuffer();
    } catch (error) {
      _report(error);
      return ResponseWithReasons(error: ResponseWithReasons_Error.FORBIDDEN, reasons: error.toString()).writeToBuffer();
    }
  }

  Future<void> connect({String? accessToken, String? username, int? authenticationType, List<int>? data}) async {
    if (accessToken?.isNotEmpty != true && (username?.isNotEmpty != true || authenticationType == null || data == null)) {
      throw const PlaybackEngineException('credentials_required', 'Provide an access token or stored credentials.');
    }
    final receipt = await engine.command('connect', {'allow_network': true,
      if (accessToken?.isNotEmpty == true) 'access_token': accessToken,
      if (accessToken?.isNotEmpty != true) ...{'username': username,
        'authentication_type': authenticationType, 'auth_data': base64Encode(data!)}});
    final id = (receipt['request_id'] as num?)?.toInt();
    if (id == null) throw const PlaybackEngineException('missing_completion_id', 'Connection returned no completion identifier.');
    final completion = Completer<void>();
    _pendingConnections[id] = completion;
    try { await completion.future.timeout(const Duration(seconds: 45)); }
    finally { _pendingConnections.remove(id); }
  }

  Future<void> disconnect() async { await engine.command('disconnect'); }
  /// Logging out drops the local account queue as well as its current source.
  Future<void> clearSession() async {
    _context = Context(); _queue = []; _order = []; _cursor = 0;
    _deferredPosition = null; _preparedIndex = null; _preparationPlaybackId = null;
    _nativeRestrictions = {};
    _options = ContextPlayerOptions(playbackSpeed: 1);
    final frame = ContextPlayerState(timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
      isPaused: true, options: _options.deepCopy());
    _state = frame;
    await engine.command('unload');
    if (!_closed) _states.add(frame.deepCopy()..freeze());
  }
  Future<void> setVolume(double value) async {
    if (!value.isFinite || value < 0 || value > 1) throw ArgumentError.value(value, 'volume', 'Must be between0 and1');
    await engine.command('volume', {'volume': (value * 65535).round()});
  }

  /// App-owned resume data contains only context/queue/options, never keys or
  /// URLs for media. Restore the paused queue without opening a streaming source;
  /// an explicit Resume resolves that source at the saved position.
  Map<String, Object?>? resumeBookmark() {
    final state = _state;
    if (_queue.isEmpty || state == null || !state.hasTrack()) return null;
    final queue = _queue.map((track) => track.deepCopy()).toList();
    queue[_order[_cursor]] = state.track.contextTrack.deepCopy();
    return {'version': 1, 'context': base64Encode(_context.writeToBuffer()),
      'queue': queue.map((track) => base64Encode(track.writeToBuffer())).toList(),
      'order': _order.toList(), 'cursor': _cursor,
      'options': base64Encode(_options.writeToBuffer()),
      'position': state.positionAsOfTimestamp.value.toInt()};
  }

  Future<void> restoreBookmark(Map<String, Object?> value) async {
    if (_state != null || value['version'] != 1) return;
    final context = Context.fromBuffer(base64Decode(value['context'] as String));
    final queue = (value['queue'] as List).map((item) =>
      ContextTrack.fromBuffer(base64Decode(item as String))).toList();
    final order = (value['order'] as List).cast<int>();
    final cursor = value['cursor'] as int;
    if (queue.isEmpty || queue.length > 10000 || queue.any((item) => !_audioUri(item.uri) ||
        isAdvertisement(item.uri, item.metadata)) ||
        order.length != queue.length || order.toSet().length != queue.length ||
        order.any((index) => index < 0 || index >= queue.length) || cursor < 0 || cursor >= order.length) {
      throw const FormatException('Invalid playback resume queue');
    }
    final options = ContextPlayerOptions.fromBuffer(base64Decode(value['options'] as String));
    final position = max(0, (value['position'] as num).toInt());
    _context = context; _queue = queue; _order = order.toList(); _cursor = cursor; _options = options;
    _deferredPosition = position;
    _nativeRestrictions = {};
    final track = queue[order[cursor]].deepCopy();
    final duration = int.tryParse(track.metadata['duration'] ?? '');
    final frame = ContextPlayerState(timestamp: Int64(DateTime.now().millisecondsSinceEpoch),
      contextUri: context.uri, contextUrl: context.url, contextMetadata: context.metadata.entries,
      track: ProvidedTrack(contextTrack: track, provider: 'dart'), options: options.deepCopy(),
      positionAsOfTimestamp: OptionalInt64(value: Int64(position)),
      isPlaying: false, isPaused: true, isBuffering: false,
      duration: duration != null && duration >= 0 ? OptionalInt64(value: Int64(duration)) : null);
    _applyRestrictions(frame);
    _queueFields(frame);
    _state = frame;
    _states.add(frame.deepCopy()..freeze());
  }
  Future<void> playUri(String uri) => _play(PlayRequest(preparePlayRequest: PreparePlayRequest(context:
    PlaybackContext(uri, pages: [PlaybackPage(items: [PlaybackItemReference(uri)])]).toMessage())));
  Future<void> loadLocalFile(String path) => playUri(Uri.file(File(path).absolute.path).toString());

  static bool _audioUri(String uri) => uri.startsWith('file:') ||
    const {'track', 'episode', 'local'}.contains(playbackUriType(uri));
  void _guard(Iterable<String> reasons) {
    if (reasons.isNotEmpty) throw PlaybackEngineException('restricted', reasons.join(', '));
  }

  Future<void> _play(PlayRequest request) async {
    final prepare = request.preparePlayRequest;
    final context = prepare.context.deepCopy();
    _guard(context.restrictions.disallowResumingReasons);
    final supplied = [for (final page in context.pages) ...page.tracks.map((track) => track.deepCopy())];
    final sourceIndexes = <int>[];
    final queue = <ContextTrack>[];
    for (final (index, track) in supplied.indexed) {
      if (isAdvertisement(track.uri, track.metadata)) continue;
      sourceIndexes.add(index); queue.add(track);
    }
    if (queue.isEmpty && supplied.isEmpty && _audioUri(context.uri) &&
        !isAdvertisement(context.uri, context.metadata)) {
      sourceIndexes.add(0); queue.add(ContextTrack(uri: context.uri));
    }
    if (queue.isEmpty) throw const PlaybackEngineException('context_unresolved', 'This context needs a supplied track list.');
    if (queue.any((track) => !_audioUri(track.uri))) throw const PlaybackEngineException('unsupported_uri', 'The context contains an unsupported audio URI.');
    final overrides = prepare.options.playerOptionsOverride;
    if (overrides.hasPlaybackSpeed() && overrides.playbackSpeed != 1) {
      throw const PlaybackEngineException('speed_unsupported', 'This playback engine supports normal speed.');
    }
    var selected = 0;
    final target = prepare.options.skipTo;
    if (target.trackUri.isNotEmpty || target.trackUid.isNotEmpty) {
      final sourceIndex = supplied.indexWhere((track) => target.trackUid.isNotEmpty
        ? track.uid == target.trackUid : track.uri == target.trackUri);
      selected = sourceIndex < 0 ? queue.indexWhere((track) => target.trackUid.isNotEmpty
        ? track.uid == target.trackUid : track.uri == target.trackUri)
        : sourceIndexes.indexWhere((index) => index >= sourceIndex);
    } else if (target.hasTrackIndex()) {
      var sourceIndex = target.trackIndex.value.toInt();
      if (target.hasPageIndex()) {
        final page = target.pageIndex.value.toInt();
        if (page < 0 || page >= context.pages.length) { sourceIndex = -1; }
        else { sourceIndex += context.pages.take(page).fold(0, (count, item) => count + item.tracks.length); }
      }
      selected = sourceIndex < 0 ? -1 : sourceIndexes.indexWhere((index) => index >= sourceIndex);
    }
    if (selected < 0 || selected >= queue.length) throw const PlaybackEngineException('track_not_found', 'The selected track is not in the supplied context.');
    final playbackId = NativePlaybackId(given: prepare.options.playbackId.isEmpty
      ? null : prepare.options.playbackId).bytes;
    final receipt = await engine.command('load', {'uri': queue[selected].uri,
      'playback_id': playbackId,
      'play': !prepare.options.initiallyPaused,
      'position_ms': max(0, prepare.options.seekTo.value.toInt())});
    _context = context;
    _deferredPosition = null;
    _queue = queue;
    _order = List.generate(queue.length, (index) => index);
    _cursor = selected;
    _loadId = (receipt['request_id'] as num?)?.toInt() ?? _loadId + 1;
    _nativeRestrictions = {};
    if (overrides.hasRepeatingContext()) _options.repeatingContext = overrides.repeatingContext.value;
    if (overrides.hasRepeatingTrack()) _options.repeatingTrack = overrides.repeatingTrack.value;
    _shuffle(overrides.hasShufflingContext() ? overrides.shufflingContext.value : _options.shufflingContext);
  }

  void _shuffle(bool enabled) {
    final current = _queue.isEmpty ? 0 : _order[_cursor];
    _options.shufflingContext = enabled;
    if (_queue.isEmpty) return;
    if (enabled) {
      final remaining = _order.sublist(_cursor + 1)..shuffle(_random);
      _order = [..._order.take(_cursor + 1), ...remaining];
    } else {
      _order = List.generate(_queue.length, (index) => index);
      _cursor = current;
    }
  }

  Future<void> _loadAt(int index, {int position = 0}) async {
    final receipt = await engine.command('load', {'uri': _queue[_order[index]].uri,
      'playback_id': NativePlaybackId().bytes, 'play': true, 'position_ms': position});
    _deferredPosition = null;
    _cursor = index;
    _loadId = (receipt['request_id'] as num?)?.toInt() ?? _loadId + 1;
    _nativeRestrictions = {};
  }
  Future<void> _next(SkipNextRequest request) async {
    _guard((_state?.restrictions.disallowSkippingNextReasons ?? <String>[]).where(
      (reason) => !request.hasTrack() || reason != 'no_next_track'));
    var index = _cursor + 1;
    if (request.hasTrack()) {
      index = _order.indexWhere((index) => request.track.uid.isNotEmpty ?
        _queue[index].uid == request.track.uid : _queue[index].uri == request.track.uri);
    }
    if (index >= _order.length && _options.repeatingContext) index = 0;
    if (index < 0 || index >= _order.length) throw const PlaybackEngineException('no_next_track', 'No next track is available.');
    await _loadAt(index);
  }
  Future<void> _previous(SkipPrevRequest request) async {
    if (request.allowSeeking && (_state?.restrictions.disallowSeekingReasons.isEmpty ?? false) &&
        (_state?.positionAsOfTimestamp.value.toInt() ?? 0) > 3000) {
      if (_deferredPosition != null) { _seekDeferred(0); return; }
      await engine.command('seek', {'position_ms': 0});
      return;
    }
    _guard(_state?.restrictions.disallowSkippingPrevReasons ?? []);
    var index = _cursor - 1;
    if (index < 0 && _options.repeatingContext) index = _order.length - 1;
    if (index < 0 || index >= _order.length) throw const PlaybackEngineException('no_prev_track', 'No previous track is available.');
    await _loadAt(index);
  }
  Future<void> _seek(SeekToRequest request) async {
    _guard(_state?.restrictions.disallowSeekingReasons ?? []);
    if (request.options.onlyForPlaybackId.isNotEmpty &&
        base64Encode(request.options.onlyForPlaybackId) != base64Encode(_state?.playbackId ?? [])) {
      throw const PlaybackEngineException('playback_changed', 'The playing item changed before seeking.');
    }
    var position = request.position.toInt();
    if (request.relative == SeekToRequest_Relative.CURRENT) position += _state?.positionAsOfTimestamp.value.toInt() ?? 0;
    position = max(0, position);
    if (_state?.hasDuration() == true) position = min(position, _state!.duration.value.toInt());
    if (_deferredPosition != null) { _seekDeferred(position); return; }
    await engine.command('seek', {'position_ms': position});
  }
  void _seekDeferred(int position) {
    _deferredPosition = position;
    final frame = _state!.deepCopy()
      ..timestamp = Int64(DateTime.now().millisecondsSinceEpoch)
      ..positionAsOfTimestamp = OptionalInt64(value: Int64(position));
    _applyRestrictions(frame);
    _queueFields(frame);
    _state = frame;
    _states.add(frame.deepCopy()..freeze());
  }
  void _setOptions(SetOptionsRequest request) {
    if (request.hasPlaybackSpeed() && request.playbackSpeed != 1) throw const PlaybackEngineException('speed_unsupported', 'This playback engine supports normal speed.');
    if (request.hasRepeatingContext()) {
      _guard(_state?.restrictions.disallowTogglingRepeatContextReasons ?? []);
      _options.repeatingContext = request.repeatingContext.value;
    }
    if (request.hasRepeatingTrack()) {
      _guard(_state?.restrictions.disallowTogglingRepeatTrackReasons ?? []);
      _options.repeatingTrack = request.repeatingTrack.value;
    }
    if (request.hasShufflingContext()) {
      _guard(_state?.restrictions.disallowTogglingShuffleReasons ?? []);
      _shuffle(request.shufflingContext.value);
    }
    _publishOptions();
  }
  void _publishOptions() {
    if (_state == null || _closed) return;
    final frame = _state!.deepCopy()..options = _options.deepCopy();
    _applyRestrictions(frame);
    _queueFields(frame);
    _state = frame;
    _states.add(frame.deepCopy()..freeze());
    _prepareNext();
  }

  void _prepareNext() {
    final state = _state;
    if (engine is! QueuePreparingPlaybackEngine || _closed || _queue.isEmpty ||
        state == null || !state.isPlaying || state.isPaused || state.isBuffering || state.playbackId.isEmpty) return;
    final owner = base64Encode(state.playbackId);
    var next = _options.repeatingTrack ? _cursor : _cursor + 1 < _order.length
      ? _cursor + 1 : _options.repeatingContext ? 0 : -1;
    if (state.restrictions.disallowSkippingNextReasons.any((reason) => reason != 'no_next_track') ||
        state.restrictions.disallowResumingReasons.isNotEmpty) next = -1;
    if (_preparationPlaybackId == owner && _preparedIndex == next) return;
    _preparationPlaybackId = owner;
    _preparedIndex = next;
    unawaited(engine.command('prepare_next', {
      if (next >= 0) 'uri': _queue[_order[next]].uri,
      if (next >= 0) 'playback_id': NativePlaybackId().bytes,
      'position_ms': 0, 'play': false,
    }).then<void>((_) {}, onError: (Object error, StackTrace stack) {
      // A speculative preparation failure must not stop the current song.
    }));
  }

  void _queueFields(ContextPlayerState frame) {
    frame.prevTracks.clear(); frame.nextTracks.clear();
    frame.prevTracks.addAll([for (final index in _order.take(_cursor)) ProvidedTrack(contextTrack: _queue[index], provider: 'dart')]);
    frame.nextTracks.addAll([for (final index in _order.skip(_cursor + 1)) ProvidedTrack(contextTrack: _queue[index], provider: 'dart')]);
    frame.index = ContextIndex(track: Int64(_cursor));
    if (!_options.repeatingContext && _cursor == 0 && frame.positionAsOfTimestamp.value.toInt() <= 3000) frame.restrictions.disallowSkippingPrevReasons.add('no_prev_track');
    if (!_options.repeatingContext && _cursor + 1 >= _order.length) frame.restrictions.disallowSkippingNextReasons.add('no_next_track');
  }

  void _event(PlayerJson event) {
    if (_closed) return;
    if (event['type'] == 'command_completed') {
      final id = (event['request_id'] as num?)?.toInt();
      final connection = _pendingConnections.remove(id);
      if (connection != null) {
        if (event['ok'] == true) { connection.complete(); }
        else { connection.completeError(PlaybackEngineException('connect_failed', event['error']?.toString() ?? 'Connection failed.')); }
      }
      return;
    }
    if (event['type'] == 'error') {
      _report(PlaybackEngineException(event['code']?.toString() ?? 'playback_error', event['message']?.toString() ?? 'Playback failed.'));
      return;
    }
    if (event['type'] == 'session') {
      if (event['event'] == 'disconnected' && _state != null) {
        final frame = _state!.deepCopy()..isPlaying = false..isPaused = true..isBuffering = false;
        _state = frame; _states.add(frame.deepCopy()..freeze());
      }
      return;
    }
    if (event['type'] != 'player') return;
    if (!const {'loading', 'playing', 'paused', 'stopped', 'end_of_track', 'position', 'transition',
        'seeked', 'track_changed', 'unavailable'}.contains(event['event'])) { return; }
    final uri = event['uri']?.toString() ?? _state?.track.contextTrack.uri ?? _uri;
    final name = event['event']?.toString();
    if (name == 'transition') {
      final next = _preparedIndex, previous = event['previous_playback_id'];
      if (next == null || next < 0 || next >= _order.length || previous is! List ||
          base64Encode(previous.cast<int>()) != _preparationPlaybackId ||
          _queue[_order[next]].uri != uri) return;
      _cursor = next;
      _loadId = (event['play_request_id'] as num?)?.toInt() ?? _loadId;
      _preparedIndex = null; _preparationPlaybackId = null;
    }
    if (_queue.isNotEmpty && uri.isNotEmpty && uri != _uri) return;
    final frame = _state?.deepCopy() ?? ContextPlayerState(isPaused: true);
    final changedTrack = frame.track.contextTrack.uri != uri || name == 'transition';
    if (changedTrack) {
      frame.clearDuration();
      frame.positionAsOfTimestamp = OptionalInt64(value: Int64.ZERO);
    }
    frame.timestamp = Int64(DateTime.now().millisecondsSinceEpoch);
    frame.contextUri = _context.uri;
    frame.contextUrl = _context.url;
    frame.contextMetadata.addAll(_context.metadata);
    frame.options = _options.deepCopy();
    final playbackId = event['playback_id'];
    if (playbackId is List) {
      frame.playbackId = NativePlaybackId(given: playbackId.cast<int>()).bytes;
    } else if (frame.playbackId.isEmpty || changedTrack) {
      frame.playbackId = NativePlaybackId().bytes;
    }
    if (uri.isNotEmpty) {
      final track = _queue.isEmpty ? ContextTrack(uri: uri) : _queue[_order[_cursor]].deepCopy();
      final metadata = event['metadata'];
      if (metadata is Map) {
        const names = {'title': 'title', 'artist': 'artist_name', 'album': 'album_title', 'duration_ms': 'duration'};
        for (final entry in metadata.entries) {
          if (entry.value != null) track.metadata[names[entry.key] ?? entry.key.toString()] = entry.value.toString();
        }
      } else if (frame.track.contextTrack.uri == uri) { track.metadata.addAll(frame.track.contextTrack.metadata); }
      track.uri = uri;
      frame.track = ProvidedTrack(contextTrack: track, provider: 'dart');
    }
    if (event['position_ms'] case final num value) frame.positionAsOfTimestamp = OptionalInt64(value: Int64(value.toInt()));
    final duration = event['duration_ms'] ?? (event['metadata'] is Map ? (event['metadata'] as Map)['duration_ms'] : null);
    if (duration is num) frame.duration = OptionalInt64(value: Int64(duration.toInt()));
    switch (name) {
      case 'loading': frame.isPlaying = false; frame.isPaused = true; frame.isBuffering = true;
      case 'playing': frame.isPlaying = true; frame.isPaused = false; frame.isBuffering = false;
      case 'paused': frame.isPlaying = true; frame.isPaused = true; frame.isBuffering = false;
      case 'stopped' || 'end_of_track' || 'unavailable': frame.isPlaying = false; frame.isPaused = true; frame.isBuffering = false;
    }
    if (event['restrictions'] case final Map restrictions) { _nativeRestrictions = restrictions.cast<String, Object?>(); }
    _applyRestrictions(frame);
    _queueFields(frame);
    _state = frame;
    _states.add(frame.deepCopy()..freeze());
    if (name == 'playing' || name == 'paused' || name == 'transition') _prepareNext();
    if (name == 'end_of_track' && _queue.isNotEmpty) {
      final next = _options.repeatingTrack ? _cursor : _cursor + 1 < _order.length ? _cursor + 1 : _options.repeatingContext ? 0 : -1;
      if (next >= 0) unawaited(_loadAt(next).catchError((Object error) { _report(error); }));
    }
  }

  void _applyRestrictions(ContextPlayerState frame) {
    frame.restrictions = _context.restrictions.deepCopy();
    void denied(String key, List<String> reasons) { if (_nativeRestrictions[key] == false) reasons.add('disallowed_by_account_manager'); }
    denied('can_pause', frame.restrictions.disallowPausingReasons);
    denied('can_resume', frame.restrictions.disallowResumingReasons);
    denied('can_seek', frame.restrictions.disallowSeekingReasons);
    denied('can_skip_next', frame.restrictions.disallowSkippingNextReasons);
    denied('can_skip_previous', frame.restrictions.disallowSkippingPrevReasons);
    denied('can_shuffle', frame.restrictions.disallowTogglingShuffleReasons);
    denied('can_repeat_context', frame.restrictions.disallowTogglingRepeatContextReasons);
    denied('can_repeat_track', frame.restrictions.disallowTogglingRepeatTrackReasons);
  }

  void _report(Object error) {
    if (_closed) return;
    final code = error is PlaybackEngineException ? error.code : 'playback_error';
    _errors.add(ContextPlayerError(code: ContextPlayerError_ErrorCode.PLAYBACK_ERROR,
      message: error.toString(), data: {'reasons': error.toString(), 'engine_code': code}.entries));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pendingConnections.values) {
      pending.completeError(const PlaybackEngineException('engine_closed', 'Playback engine is closed.'));
    }
    _pendingConnections.clear();
    await _subscription.cancel();
    await engine.close();
    await Future.wait([_states.close(), _errors.close()]);
  }
}
