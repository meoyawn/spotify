import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'models.dart';
import 'repository.dart';
import '../library/saved_playlists.dart';

enum EntityPhase { idle, loading, ready, unavailable, failed }

class EntityState {
  EntityState({required this.uri, this.phase = EntityPhase.idle, this.details,
    List<EntityRow> rows = const [], this.hasMore = false, this.isLoadingMore = false, this.error})
      : rows = List.unmodifiable(rows);
  final String uri;
  final EntityPhase phase;
  final EntityDetails? details;
  final List<EntityRow> rows;
  final bool hasMore;
  final bool isLoadingMore;
  final Object? error;
}

/// Owns one selected entity; display-row cursors include album disc separators.
class EntityController extends ChangeNotifier {
  EntityController(this.repository, {required String uri, this.onLibraryChanged}) : _state = EntityState(uri: uri) {
    _observeChanges(uri);
  }
  Listenable? _changes;
  void _observeChanges(String uri) {
    _changes?.removeListener(_changed);
    _changes = repository is UpdatingEntityRepository
      ? (repository as UpdatingEntityRepository).changesFor(uri) : null;
    _changes?.addListener(_changed);
  }
  void _changed() {
    onLibraryChanged?.call();
    if (_initialized && !_disposed) unawaited(refresh());
  }
  final EntityRepository repository;
  final VoidCallback? onLibraryChanged;
  final _saveCancellation = CancellationToken();
  int _saveRevision = 0;
  final _savedPlaylists = <String, ({bool value, int revision})>{};
  final _saveWrites = <String, Future<void>>{};
  bool get saving => _saveWrites.containsKey(_state.uri);
  bool get canSave => repository is SavedPlaylistsRepository && _state.phase == EntityPhase.ready &&
    _state.details?.type == 'playlist' && _state.details?.data['isSaved'] is bool &&
    _state.details?.data['isOwnedBySelf'] != true &&
    _state.uri != 'spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ';

  Future<void> toggleSaved() {
    if (_disposed || !canSave) return Future.value();
    final details = _state.details!, uri = _state.uri;
    final saved = details.data['isSaved'] != true;
    final pending = _saveWrites[uri];
    _setSaved(uri, saved);
    final write = pending ?? (_saveWrites[uri] = Future<void>.microtask(() => _writeSaved(uri, !saved)));
    unawaited(write.catchError((Object _) {}));
    notifyListeners();
    return write;
  }

  Future<void> _writeSaved(String uri, bool acknowledged) async {
    var changed = false;
    try {
      while (_savedPlaylists[uri]!.value != acknowledged) {
        _saveCancellation.throwIfCancelled();
        final desired = _savedPlaylists[uri]!.value;
        await (repository as SavedPlaylistsRepository).setPlaylistSaved(uri, desired,
          cancellationToken: _saveCancellation);
        if (_disposed) return;
        acknowledged = desired;
        changed = true;
      }
    } finally {
      _saveWrites.remove(uri);
      if (!_disposed) {
        _setSaved(uri, acknowledged);
        notifyListeners();
        if (changed) onLibraryChanged?.call();
      }
    }
  }

  void _setSaved(String uri, bool saved) {
    _savedPlaylists.remove(uri);
    _savedPlaylists[uri] = (value: saved, revision: ++_saveRevision);
    while (_savedPlaylists.length > 16) {
      final evict = _savedPlaylists.keys.where((key) => key != _state.uri && !_saveWrites.containsKey(key)).firstOrNull;
      if (evict == null) break;
      _savedPlaylists.remove(evict);
    }
    if (_state.uri != uri || _state.details == null) return;
    final current = _state.details!;
    if (current.data['isSaved'] == saved) return;
    _state = EntityState(uri: uri, phase: _state.phase,
      details: EntityDetails.fromJson({...current.data, 'isSaved': saved},
        source: current.source, unsupportedFeatures: current.unsupportedFeatures),
      rows: _state.rows, hasMore: _state.hasMore, isLoadingMore: _state.isLoadingMore, error: _state.error);
  }
  EntityState _state;
  EntityState get state => _state;
  int _revision = 0;
  CancellationToken _request = CancellationToken();
  int _cursor = 0;
  bool _initialized = false;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;
    if (_state.phase == EntityPhase.idle) await refresh();
  }

  Future<void> setUri(String uri) async {
    if (_disposed || uri == _state.uri) return;
    _observeChanges(uri);
    _state = EntityState(uri: uri);
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _request.cancel();
    final token = _request = CancellationToken();
    final revision = ++_revision;
    final saveRevision = _savedPlaylists[_state.uri]?.revision ?? 0;
    _state = EntityState(uri: _state.uri, phase: EntityPhase.loading,
      details: _state.details, rows: _state.rows);
    notifyListeners();
    try {
      final page = await repository.open(_state.uri, cancellationToken: token);
      if (_disposed || revision != _revision) return;
      _cursor = page.tracks.nextOffset ?? page.tracks.rows.length;
      final saved = _savedPlaylists[_state.uri];
      final details = saved != null && (saving || saveRevision != saved.revision)
        ? EntityDetails.fromJson({...page.details.data, 'isSaved': saved.value},
            source: page.details.source, unsupportedFeatures: page.details.unsupportedFeatures)
        : page.details;
      _state = EntityState(uri: _state.uri,
        phase: details.isAccessible ? EntityPhase.ready : EntityPhase.unavailable,
        details: details, rows: page.tracks.rows,
        hasMore: _cursor > 0 && _cursor < page.tracks.totalLength);
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      _state = EntityState(uri: _state.uri, phase: EntityPhase.failed,
        details: _state.details, rows: _state.rows, error: error);
    }
    notifyListeners();
  }

  Future<void> loadMore() async {
    final details = _state.details;
    if (_disposed || details == null || !_state.hasMore || _state.isLoadingMore || _state.phase != EntityPhase.ready) return;
    final revision = _revision;
    _state = EntityState(uri: _state.uri, phase: _state.phase, details: details,
      rows: _state.rows, hasMore: true, isLoadingMore: true);
    notifyListeners();
    try {
      final page = await repository.tracks(details, offset: _cursor, cancellationToken: _request);
      if (_disposed || revision != _revision) return;
      final previousCursor = _cursor;
      _cursor = page.nextOffset ?? _cursor + page.rows.length;
      _state = EntityState(uri: _state.uri, phase: EntityPhase.ready, details: _state.details,
        rows: [..._state.rows, ...page.rows], hasMore: _cursor > previousCursor && _cursor < page.totalLength);
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      _state = EntityState(uri: _state.uri, phase: EntityPhase.ready, details: _state.details,
        rows: _state.rows, hasMore: true, error: error);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changes?.removeListener(_changed);
    _saveCancellation.cancel();
    _request.cancel();
    _revision++;
    super.dispose();
  }
}
