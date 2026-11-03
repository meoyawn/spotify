import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../playback/controller.dart';
import '../playback/models.dart';
import 'repository.dart';

class LyricsController extends ChangeNotifier {
  LyricsController(this.repository, this.player);
  final LyricsRepository repository;
  final PlaybackController player;
  StreamSubscription<PlaybackState>? _subscription;
  Timer? _ticker;
  final _cache = <String, ({TrackLyrics lyrics, DateTime expires})>{};
  PlaybackState? _playback;
  String? _key, _uri, _image;
  int _revision = 0;
  CancellationToken _request = CancellationToken();
  bool _disposed = false;
  int _activeLine = -2, _activePreview = -2;
  TrackLyrics? lyrics;
  Object? error;
  bool loading = false;
  String? get uri => _uri;
  String get title => _playback?.item?.name ?? '';
  bool get canSeek => lyrics?.isTimeSynced == true && lyrics?.capStatus != 'CAPPED' &&
    _playback?.restrictions.canSeek == true;
  int get positionMs {
    final state = _playback;
    if (state == null) return 0;
    final elapsed = state.hasContext && !state.isPaused && !state.isBuffering
      ? (DateTime.now().millisecondsSinceEpoch - state.timestamp).clamp(0, state.durationMs ?? 0x7fffffff) * state.speed : 0;
    return (state.positionAsOfTimestamp + elapsed).round().clamp(0, state.durationMs ?? 0x7fffffff);
  }

  @override
  void addListener(VoidCallback listener) {
    final observed = hasListeners;
    super.addListener(listener);
    if (!observed) {
      _subscription = player.states.listen(_receive);
      scheduleMicrotask(() {
        if (_disposed || !hasListeners) return;
        final previousKey = _key;
        _receive(player.state);
        if (_key == previousKey && !loading && error == null) unawaited(reload());
      });
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _request.cancel(); _revision++; loading = false;
      unawaited(_subscription?.cancel()); _subscription = null;
      _ticker?.cancel(); _ticker = null;
    }
  }

  void _updateTicker() {
    final state = _playback;
    final running = !_disposed && hasListeners && lyrics?.isTimeSynced == true &&
      state?.hasContext == true && state?.isPaused == false && state?.isBuffering == false;
    if (!running) { _ticker?.cancel(); _ticker = null; }
    else { _ticker ??= Timer.periodic(const Duration(milliseconds: 500), (_) => _notifyTiming()); }
  }

  void _notifyTiming({bool force = false}) {
    final position = positionMs;
    int active(List<LyricsLine>? lines) => lyrics?.isTimeSynced == true
      ? lines?.indexWhere((line) => position >= line.startMs && (line.endMs == null || position < line.endMs!)) ?? -1 : -1;
    final full = active(lyrics?.lines), preview = active(lyrics?.previewLines);
    if (force || full != _activeLine || preview != _activePreview) {
      _activeLine = full; _activePreview = preview; notifyListeners();
    }
  }

  void _receive(PlaybackState? state) {
    if (_disposed) return;
    final couldSeek = canSeek;
    _playback = state;
    final item = state?.item;
    final uri = item?.uri;
    final image = item?.metadata['image_large_url'] ?? item?.images.firstOrNull?['url'] as String? ?? '';
    final supported = uri != null && RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri);
    final key = supported ? '$uri\n$image' : null;
    final changed = _key != key;
    if (changed) {
      _request.cancel();
      _revision++;
      _key = key; _uri = supported ? uri : null; _image = image;
      lyrics = null; error = null; loading = false;
      if (key != null) unawaited(reload());
    }
    _updateTicker();
    _notifyTiming(force: changed || couldSeek != canSeek);
  }

  Future<void> reload() async {
    final key = _key, uri = _uri, image = _image;
    if (_disposed || !hasListeners || key == null || uri == null || image == null || loading) return;
    _request.cancel();
    final token = _request = CancellationToken();
    final revision = ++_revision;
    final cached = _cache.remove(key);
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      _cache[key] = cached; lyrics = cached.lyrics; _updateTicker(); _notifyTiming(force: true); return;
    }
    loading = true; error = null; notifyListeners();
    try {
      final value = await repository.load(uri, image, cancellationToken: token);
      if (_disposed || revision != _revision) return;
      lyrics = value;
      _cache[key] = (lyrics: value, expires: DateTime.now().add(const Duration(minutes: 10)));
      while (_cache.length > 24) { _cache.remove(_cache.keys.first); }
    } on CancelledException { return; } catch (failure) {
      if (_disposed || revision != _revision) return;
      error = failure;
    }
    if (_disposed || revision != _revision) return;
    loading = false; _updateTicker(); _notifyTiming(force: true);
  }

  Future<void> seek(LyricsLine line) async {
    if (!canSeek || line.startMs < 0 || (_playback?.durationMs != null && line.startMs > _playback!.durationMs!)) return;
    final selected = player.state;
    await player.seekTo(line.startMs);
    final current = player.state;
    if (!_disposed && current?.playbackId == selected?.playbackId && current?.item?.uri == selected?.item?.uri &&
        current?.isPaused == true && current?.restrictions.canResume == true) await player.resume();
  }

  @override
  void dispose() {
    _disposed = true; _revision++;
    _request.cancel();
    _ticker?.cancel(); unawaited(_subscription?.cancel()); _cache.clear();
    lyrics = null; error = null; loading = false; _uri = null; _key = null; _playback = null;
    notifyListeners();
    super.dispose();
  }
}
