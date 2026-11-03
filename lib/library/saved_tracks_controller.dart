import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'saved_tracks.dart';

class SavedTrackState {
  const SavedTrackState({this.saved, this.changing = false, this.error});
  final bool? saved;
  final bool changing;
  final Object? error;
}

/// One account-scoped owner for every visible save control. Membership reads
/// from the same event turn are combined; writes occur only on explicit action.
class SavedTracksController extends ChangeNotifier {
  SavedTracksController(this.repository);
  final SavedTracksRepository repository;
  final _states = <String, SavedTrackState>{};
  final _reads = <String, Completer<void>>{};
  final _queued = <String>{};
  final _writes = <String, Future<void>>{};
  CancellationToken? _flushTimer;
  final _cancellation = CancellationToken();
  bool _disposed = false;

  static bool supports(String uri) => RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri);

  SavedTrackState state(String uri) => _states[uri] ?? const SavedTrackState();

  Future<void> load(String uri) {
    if (_disposed) return Future.error(StateError('Spotify session changed'));
    if (!supports(uri)) return Future.error(ArgumentError.value(uri, 'uri', 'Expected a Spotify track'));
    if (state(uri).saved != null) return Future.value();
    final pending = _reads[uri];
    if (pending != null) return pending.future;
    // A single retry refreshes every failed visible control from the same
    // account snapshot, instead of requiring a click on every copy/row.
    for (final entry in _states.entries) {
      if (entry.value.saved != null || entry.value.error == null || _reads.containsKey(entry.key)) continue;
      final read = Completer<void>();
      _reads[entry.key] = read;
      _queued.add(entry.key);
      unawaited(read.future.catchError((Object _) {}));
    }
    final retry = _reads[uri];
    if (retry != null) {
      _scheduleFlush();
      return retry.future;
    }
    final result = Completer<void>();
    _reads[uri] = result;
    _queued.add(uri);
    _scheduleFlush();
    return result.future;
  }

  void _scheduleFlush() {
    if (_flushTimer != null) return;
    final token = _flushTimer = CancellationToken();
    unawaited(CancellableFuture.delayed<void>(Duration.zero, token).then<void>((_) => _flush(),
      onError: (Object error, StackTrace stack) {
        if (error is! CancelledException) Error.throwWithStackTrace(error, stack);
      }));
  }

  void _flush() {
    _flushTimer = null;
    if (_disposed || _queued.isEmpty) return;
    final uris = _queued.toList(growable: false);
    _queued.clear();
    unawaited(_read(uris));
  }

  Future<void> _read(List<String> uris) async {
    try {
      final membership = await repository.contains(uris, cancellationToken: _cancellation);
      if (_disposed) return;
      for (final uri in uris) {
        final saved = membership[uri];
        if (saved == null) throw StateError('Spotify did not return saved status for every track');
      }
      for (final uri in uris) {
        _store(uri, SavedTrackState(saved: membership[uri]));
        _reads.remove(uri)?.complete();
      }
    } catch (error, stack) {
      if (_disposed) return;
      for (final uri in uris) {
        _store(uri, SavedTrackState(saved: state(uri).saved, error: error));
        _reads.remove(uri)?.completeError(error, stack);
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> toggle(String uri) {
    if (_disposed) return Future.error(StateError('Spotify session changed'));
    final pending = _writes[uri];
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _toggle(uri).whenComplete(() {
      if (identical(_writes[uri], operation)) _writes.remove(uri);
    });
    _writes[uri] = operation;
    return operation;
  }

  Future<void> _toggle(String uri) async {
    await load(uri);
    if (_disposed) throw StateError('Spotify session changed');
    final saved = state(uri).saved!;
    _store(uri, SavedTrackState(saved: saved, changing: true));
    notifyListeners();
    try {
      await repository.setSaved(uri, !saved, cancellationToken: _cancellation);
      if (_disposed) return;
      _store(uri, SavedTrackState(saved: !saved));
    } catch (error) {
      if (!_disposed) _store(uri, SavedTrackState(saved: saved, error: error));
      rethrow;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  void _store(String uri, SavedTrackState value) {
    _states.remove(uri);
    _states[uri] = value;
    if (_states.length <= 2048) return;
    final evict = _states.keys.where((key) => !_reads.containsKey(key) && !_writes.containsKey(key)).firstOrNull;
    if (evict != null) _states.remove(evict);
  }

  @override void dispose() {
    _disposed = true;
    _cancellation.cancel();
    _flushTimer?.cancel();
    for (final read in _reads.values) {
      read.completeError(const CancelledException());
    }
    _reads.clear(); _queued.clear(); _states.clear(); _writes.clear();
    super.dispose();
  }
}
