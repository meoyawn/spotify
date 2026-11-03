import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../playback/controller.dart';
import '../playback/models.dart';

/// Dart owns media commands and the actual player-state projection. The macOS
/// bridge only publishes Now Playing fields and receives standard remote events.
class DesktopMediaControls {
  DesktopMediaControls._({required this.controller, required this.toggle,
    required this.onError, this.loadArtwork, CancellationToken? cancellationToken})
    : _owner = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}',
      _parentCancellation = cancellationToken;

  static const _channel = MethodChannel('spotify_flutter/desktop_media_controls');
  static int _sequence = 0;
  static DesktopMediaControls? _active;
  final PlaybackController controller;
  final Future<void> Function() toggle;
  final void Function(Object error) onError;
  final Future<Uint8List?> Function(PlaybackItem item, {CancellationToken? cancellationToken})? loadArtwork;
  final String _owner;
  final CancellationToken? _parentCancellation;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= MergedCancellationToken([?_parentCancellation]);
  StreamSubscription<PlaybackState>? _states;
  Future<void> _writes = Future<void>.value();
  Future<void>? _closing;
  bool _closed = false;
  String? _lastKey;
  int? _lastUpdate;
  double _lastElapsed = 0, _lastRate = 0;
  String? _artworkUri, _artworkSourceKey;
  int _artworkGeneration = 0;
  CancellationToken _artworkCancellation = CancellationToken();
  bool _artworkSuppressed = false;

  /// An older live runner can keep its authenticated session; native support is
  /// installed on the next rebuild and a later root reassemble retries opening.
  static Future<DesktopMediaControls?> open({required PlaybackController controller,
    required Future<void> Function() toggle,
    required void Function(Object error) onError,
    Future<Uint8List?> Function(PlaybackItem item, {CancellationToken? cancellationToken})? loadArtwork,
    CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (!Platform.isMacOS) return null;
    final controls = DesktopMediaControls._(controller: controller, toggle: toggle,
      onError: onError, loadArtwork: loadArtwork, cancellationToken: cancellationToken);
    try {
      await _channel.invokeMethod<void>('initialize', {'owner': controls._owner});
      controls._token.throwIfCancelled();
      _active = controls;
      _bindHandler();
      controls._states = controller.states.listen(controls._update, onError: controls._report);
      controls._update(controller.state, force: true);
      await controls._writes;
      controls._token.throwIfCancelled();
      return controls;
    } on MissingPluginException {
      await controls.close();
      return null;
    } catch (_) {
      await controls.close();
      rethrow;
    }
  }

  static void _bindHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'command') return null;
      final args = (call.arguments as Map).cast<String, Object?>();
      final controls = _active;
      if (controls == null || controls._closed || controls._token.isCancelled || args['owner'] != controls._owner) return false;
      return controls._command(args['action'] as String?);
    });
  }

  Future<bool> _command(String? action) async {
    final state = controller.state;
    if (_closed || _token.isCancelled || state == null || state.item == null) return false;
    final usable = state.hasContext || !state.isBuffering;
    try {
      switch (action) {
        case 'play':
          if (!usable || !state.isPaused || !state.restrictions.canResume) return false;
          await controller.resume();
        case 'pause':
          if (!usable || state.isPaused || !state.restrictions.canPause) return false;
          await controller.pause();
        case 'toggle':
          if (!usable || (state.isPaused ? !state.restrictions.canResume : !state.restrictions.canPause)) return false;
          await toggle();
        case 'previous':
          if (!state.restrictions.canSeek || (state.isPaused && !state.restrictions.canResume)) return false;
          // Hardware Previous explicitly restarts this item; the controller
          // binds the zero seek to the reported playback ID.
          await controller.seekTo(0);
          _token.throwIfCancelled();
          final current = controller.state;
          if (state.isPaused && current?.playbackId == state.playbackId &&
              current?.item?.uri == state.item?.uri && current?.restrictions.canResume == true) {
            await controller.resume();
          }
        case 'next':
          if (!state.restrictions.canSkipNext) return false;
          // The local ContextPlayer's SkipNext loads the selected next item
          // with play=true, including when the old item was paused/loading.
          await controller.skipNext();
        default: return false;
      }
      return true;
    } catch (error) {
      _report(error);
      return false;
    }
  }

  void _report(Object error) { if (!_closed && !_token.isCancelled) onError(error); }

  void _update(PlaybackState? state, {bool force = false}) {
    if (_closed || _token.isCancelled) return;
    final item = state?.item;
    _prepareArtwork(item);
    final artworkGeneration = _artworkGeneration;
    final now = DateTime.now().millisecondsSinceEpoch;
    final usable = state != null && item != null && (state.hasContext || !state.isBuffering);
    final playing = state != null && state.hasContext && !state.isPaused && !state.isBuffering;
    final speed = state?.speed ?? 0;
    final rate = playing && speed.isFinite && speed > 0 ? speed : 0.0;
    final durationMs = state?.durationMs ?? item?.durationMs;
    double elapsed = (state?.positionAsOfTimestamp ?? 0) / 1000;
    if (playing && state != null && state.timestamp > 0 && now > state.timestamp) {
      elapsed += (now - state.timestamp) / 1000 * rate;
    }
    if (elapsed < 0) elapsed = 0;
    if (durationMs != null && durationMs >= 0 && elapsed > durationMs / 1000) elapsed = durationMs / 1000;
    final artists = item?.toJson()['artists'];
    final names = <String>[
      if (artists is List) for (final artist in artists)
        if (artist is Map && artist['name'] is String && (artist['name'] as String).isNotEmpty)
          artist['name'] as String,
    ];
    final data = <String, Object?>{'owner': _owner, 'hasItem': item != null,
      'artworkGeneration': artworkGeneration,
      'uri': item?.uri, 'title': item?.name,
      'artist': names.isEmpty ? item?.metadata['artist_name'] : names.join(', '),
      'album': item?.metadata['album_title'], 'mediaType': item?.mediaType,
      'playbackState': playing ? 'playing' : (state?.hasContext == true || state?.isBuffering == true)
        ? 'paused' : 'stopped',
      'playbackRate': rate,
      if (durationMs != null && durationMs >= 0) 'durationSeconds': durationMs / 1000,
      'canPlay': usable && state.isPaused && state.restrictions.canResume,
      'canPause': usable && !state.isPaused && state.restrictions.canPause,
      'canToggle': usable && (state.isPaused ? state.restrictions.canResume : state.restrictions.canPause),
      'canPrevious': item != null && state!.restrictions.canSeek && (!state.isPaused || state.restrictions.canResume),
      'canNext': item != null && state!.restrictions.canSkipNext,
    };
    final key = jsonEncode(data);
    final sinceUpdate = _lastUpdate == null ? 0.0 : (now - _lastUpdate!) / 1000;
    final expectedElapsed = _lastElapsed + sinceUpdate * _lastRate;
    // Now Playing extrapolates elapsed time itself. Publish real transitions,
    // seek/discontinuity corrections and occasional drift refreshes, not frames.
    if (!force && key == _lastKey && sinceUpdate < 15 &&
        (elapsed - expectedElapsed).abs() < 0.75) return;
    _lastKey = key;
    _lastUpdate = now;
    _lastElapsed = elapsed;
    _lastRate = rate;
    data['elapsedSeconds'] = elapsed;
    _writes = _writes.then<void>((_) async {
      if (!_closed && !_token.isCancelled && artworkGeneration == _artworkGeneration) {
        await _channel.invokeMethod<void>('update', data);
      }
    }).catchError(_report);
  }

  void _prepareArtwork(PlaybackItem? item) {
    final uri = item?.uri;
    final key = item == null ? null : jsonEncode({'uri': uri, 'images': item.images});
    if (uri == _artworkUri && key == _artworkSourceKey) return;
    final changedTrack = uri != _artworkUri;
    _artworkUri = uri;
    _artworkSourceKey = key;
    final generation = ++_artworkGeneration;
    _artworkCancellation.cancel(); _artworkCancellation = CancellationToken();
    if (changedTrack) _artworkSuppressed = false;
    if (item != null && loadArtwork != null && !_artworkSuppressed) {
      unawaited(_loadArtwork(item, generation));
    }
  }

  Future<void> _loadArtwork(PlaybackItem item, int generation) async {
    final token = MergedCancellationToken([_token, _artworkCancellation]);
    try {
      token.throwIfCancelled();
      final bytes = await loadArtwork!(item, cancellationToken: token);
      token.throwIfCancelled();
      if (_closed || !identical(_active, this) || generation != _artworkGeneration ||
          item.uri != _artworkUri || bytes == null || bytes.isEmpty) return;
      // Refresh from the current Dart timeline before adding the image. The
      // image-only native method then merges into the newest metadata, rather
      // than restoring the title/position from when this fetch began.
      _update(controller.state, force: true);
      if (generation != _artworkGeneration || item.uri != _artworkUri) return;
      _writes = _writes.then<void>((_) async {
        if (!_closed && !token.isCancelled && identical(_active, this) && generation == _artworkGeneration &&
            item.uri == _artworkUri) {
          await _channel.invokeMethod<void>('artwork', {'owner': _owner, 'uri': item.uri,
            'artworkGeneration': generation, 'bytes': bytes});
        }
      }).catchError((Object error) {
        // A live runner can have media keys but predate the artwork primitive.
        if (error is! MissingPluginException) _report(error);
      });
      await _writes;
      // No Dart byte/future cache is retained: the native bridge owns one
      // current decoded cover, and the verified image pipeline owns its cache.
    } catch (error) {
      if (generation == _artworkGeneration && item.uri == _artworkUri) _report(error);
    }
  }

  /// Release cover state and invalidate an in-flight fetch on sign-out. A new
  /// track can load its real cover; an explicit reload can re-enable this track.
  Future<void> clearArtwork() {
    if (_closed || _token.isCancelled) return Future<void>.value();
    _artworkCancellation.cancel();
    final item = controller.state?.item;
    _artworkUri = item?.uri;
    _artworkSourceKey = item == null ? null : jsonEncode({'uri': item.uri, 'images': item.images});
    _artworkSuppressed = true;
    _artworkGeneration++;
    _update(controller.state, force: true);
    return _writes;
  }

  /// Reinstall the Dart callback after hot reload without adding native targets.
  void refresh({bool reloadArtwork = false}) {
    if (_closed || _token.isCancelled || !identical(_active, this)) return;
    if (reloadArtwork) {
      _artworkSuppressed = false;
      _artworkSourceKey = null;
    }
    _bindHandler();
    _update(controller.state, force: true);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _token.cancel();
    _artworkCancellation.cancel();
    _artworkGeneration++;
    _artworkUri = null;
    _artworkSourceKey = null;
    _artworkSuppressed = true;
    await _states?.cancel();
    await _writes;
    if (identical(_active, this)) {
      _active = null;
      _channel.setMethodCallHandler(null);
    }
    try { await _channel.invokeMethod<void>('clear', {'owner': _owner}); }
    on MissingPluginException { /* The current runner can predate this bridge. */ }
  }
}
