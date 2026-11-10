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
  EntityController(this.repository, {required String uri, this.onLibraryChanged}) : _state = EntityState(uri: uri);
  final EntityRepository repository;
  final VoidCallback? onLibraryChanged;
  final _saveCancellation = CancellationToken();
  int _saveRevision = 0;
  bool _saving = false;
  bool get saving => _saving;
  bool get canSave => repository is SavedPlaylistsRepository && _state.phase == EntityPhase.ready &&
    _state.details?.type == 'playlist' && _state.details?.data['isSaved'] is bool &&
    _state.details?.data['isOwnedBySelf'] != true &&
    _state.uri != 'spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ';

  Future<void> toggleSaved() async {
    if (_disposed || _saving || !canSave) return;
    final details = _state.details!, uri = _state.uri;
    final saved = details.data['isSaved'] != true;
    _saving = true;
    notifyListeners();
    try {
      await (repository as SavedPlaylistsRepository).setPlaylistSaved(uri, saved,
        cancellationToken: _saveCancellation);
      if (_disposed) return;
      if (_state.uri == uri && _state.details != null) {
        _saveRevision++;
        final current = _state.details!;
        _state = EntityState(uri: uri, phase: _state.phase,
          details: EntityDetails.fromJson({...current.data, 'isSaved': saved},
            source: current.source, unsupportedFeatures: current.unsupportedFeatures),
          rows: _state.rows, hasMore: _state.hasMore, isLoadingMore: _state.isLoadingMore, error: _state.error);
      }
      onLibraryChanged?.call();
    } finally {
      _saving = false;
      if (!_disposed) notifyListeners();
    }
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
    _state = EntityState(uri: uri);
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _request.cancel();
    final token = _request = CancellationToken();
    final revision = ++_revision;
    final saveRevision = _saveRevision;
    _state = EntityState(uri: _state.uri, phase: EntityPhase.loading,
      details: _state.details, rows: _state.rows);
    notifyListeners();
    try {
      final page = await repository.open(_state.uri, cancellationToken: token);
      if (_disposed || revision != _revision) return;
      _cursor = page.tracks.nextOffset ?? page.tracks.rows.length;
      final saved = _state.details?.data['isSaved'];
      final details = saveRevision != _saveRevision && saved is bool
        ? EntityDetails.fromJson({...page.details.data, 'isSaved': saved},
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
    _saveCancellation.cancel();
    _request.cancel();
    _revision++;
    super.dispose();
  }
}
