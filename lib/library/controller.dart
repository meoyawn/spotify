import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'models.dart';
import 'repository.dart';

enum LibraryPhase { idle, loading, ready, failed }

class LibraryState {
  LibraryState({this.query = const LibraryQuery(), this.phase = LibraryPhase.idle,
    this.page, List<LibraryItem> items = const [], this.itemsView = LibraryItemsView.list,
    this.isLoadingMore = false, this.hasMore = false, this.error}) : items = List.unmodifiable(items);
  final LibraryQuery query;
  final LibraryPhase phase;
  final LibraryPage? page;
  final List<LibraryItem> items;
  final LibraryItemsView itemsView;
  final bool isLoadingMore;
  final bool hasMore;
  final Object? error;
}

/// In-memory sidebar state. The owner supplies any restored initial state.
class LibraryController extends ChangeNotifier {
  LibraryController(this.repository, {LibraryQuery initialQuery = const LibraryQuery(),
    LibraryItemsView initialView = LibraryItemsView.list})
      : _state = LibraryState(query: initialQuery, itemsView: initialView) {
    _filters[initialQuery.folderUri ?? ''] = [...initialQuery.filters];
    _sorts[_sortKey(initialQuery)] = (initialQuery.sortOrder, initialQuery.sortDirection);
  }
  final LibraryRepository repository;
  LibraryState _state;
  LibraryState get state => _state;
  final _filters = <String, List<String>>{};
  final _sorts = <String, (String?, LibrarySortDirection?)>{};
  int _revision = 0;
  int _nextOffset = 0;
  bool _initialized = false;
  bool _disposed = false;
  CancellationToken? _debounce;
  CancellationToken _request = CancellationToken();

  static String _sortKey(LibraryQuery query) => query.folderUri != null ? '2' : query.filters.firstOrNull ?? '';

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    if (_state.phase == LibraryPhase.idle) await refresh();
  }

  Future<void> refresh({bool invalidate = true}) {
    if (invalidate && repository is RefreshableLibraryRepository) {
      (repository as RefreshableLibraryRepository).invalidate();
    }
    return _fetch(_state.query.copyWith(offset: 0));
  }

  Future<void> setTextFilter(String value) async {
    if (_disposed || value == _state.query.textFilter) return;
    _cancelDebounce();
    _request.cancel();
    _revision++;
    if (repository case final LibrarySearchRepository current) current.cancelPendingRead();
    final query = _state.query.copyWith(textFilter: value, offset: 0);
    _publish(query: query, phase: LibraryPhase.loading, items: const [],
      hasMore: false, isLoadingMore: false, clearError: true);
    if (value.isEmpty) { await _fetch(query); return; }
    final token = _debounce = CancellationToken();
    try {
      await CancellableFuture.delayed<void>(const Duration(milliseconds: 200), token);
      if (identical(_debounce, token)) _debounce = null;
      await _fetch(query);
    } on CancelledException { /* A newer query owns the sidebar. */ }
  }

  void _cancelDebounce() {
    _debounce?.cancel(); _debounce = null;
  }

  Future<void> toggleFilter(String id) async {
    final ids = (_state.page?.selectedFilters.map((option) => option.id) ?? _state.query.filters).toSet();
    if (!ids.remove(id)) ids.add(id);
    await _changeFilters(ids.toList());
  }

  Future<void> clearFilters() => _changeFilters([]);

  Future<void> _changeFilters(List<String> ids) async {
    if (_disposed) return;
    _filters[_state.query.folderUri ?? ''] = ids;
    final query = _state.query.copyWith(filters: ids, offset: 0);
    final sort = _sorts[_sortKey(query)];
    await _fetch(query.copyWith(sortOrder: sort?.$1, sortDirection: sort?.$2));
  }

  Future<void> selectSort(String id) async {
    if (_disposed) return;
    final query = _state.query;
    final direction = id == '4' ? null : id != query.sortOrder || query.sortDirection != LibrarySortDirection.forward
        ? LibrarySortDirection.forward : LibrarySortDirection.reverse;
    _sorts[_sortKey(query)] = (id, direction);
    await _fetch(query.copyWith(sortOrder: id, sortDirection: direction, offset: 0));
  }

  void setItemsView(LibraryItemsView value) {
    if (_disposed || value == _state.itemsView) return;
    _publish(itemsView: value);
  }

  Future<void> openFolder(String uri) async {
    if (_disposed || uri == _state.query.folderUri) return;
    _filters[uri] = [..._state.query.filters];
    final query = _state.query.copyWith(folderUri: uri, filters: _filters[uri], offset: 0);
    final sort = _sorts[_sortKey(query)];
    await _fetch(query.copyWith(sortOrder: sort?.$1, sortDirection: sort?.$2));
  }

  Future<void> goToParentFolder() async {
    if (_disposed || _state.query.folderUri == null) return;
    final parent = _state.page?.parentFolderUri;
    final uri = parent == null || parent.isEmpty ? null : parent;
    final query = _state.query.copyWith(folderUri: uri,
      filters: _filters[uri ?? ''] ?? [], offset: 0);
    final sort = _sorts[_sortKey(query)];
    await _fetch(query.copyWith(sortOrder: sort?.$1, sortDirection: sort?.$2));
  }

  Future<void> toggleExpandedFolder(String uri) async {
    if (_disposed) return;
    final folders = _state.query.expandedFolders.toSet();
    if (!folders.remove(uri)) folders.add(uri);
    await _fetch(_state.query.copyWith(expandedFolders: folders.toList(), offset: 0));
  }

  Future<void> loadMore() async {
    if (_disposed || _state.isLoadingMore || !_state.hasMore || _state.phase == LibraryPhase.loading) return;
    final revision = _revision;
    final query = _state.query.copyWith(offset: _nextOffset);
    _publish(isLoadingMore: true, clearError: true);
    try {
      final page = await repository.load(query, cancellationToken: _request);
      if (_disposed || revision != _revision) return;
      _nextOffset += page.items.length;
      _publish(page: page, items: [..._state.items, ...page.items], isLoadingMore: false,
        hasMore: page.items.isNotEmpty && _nextOffset < page.totalLength);
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      _publish(isLoadingMore: false, error: error);
    }
  }

  Future<void> _fetch(LibraryQuery query, {bool recovered = false}) async {
    if (_disposed) return;
    _cancelDebounce();
    _request.cancel();
    final token = _request = CancellationToken();
    if (repository case final LibrarySearchRepository current) current.cancelPendingRead();
    final revision = ++_revision;
    _publish(query: query, phase: LibraryPhase.loading, isLoadingMore: false, clearError: true);
    try {
      final source = query.textFilter.isNotEmpty && repository is LibrarySearchRepository
        ? (repository as LibrarySearchRepository).search(query, cancellationToken: token)
        : Stream.fromFuture(repository.load(query, cancellationToken: token));
      await for (final page in source) {
        if (_disposed || revision != _revision) break;
        _nextOffset = query.offset + page.items.length;
        _publish(phase: page.isSearchComplete ? LibraryPhase.ready : LibraryPhase.loading, page: page, items: page.items,
          hasMore: page.isSearchComplete && page.items.isNotEmpty && _nextOffset < page.totalLength);
      }
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      if (!recovered && error is LibraryQueryError) {
        if ((error.kind == 'folder' || error.kind == 'filter') && query.folderUri != null) {
          await _fetch(query.copyWith(folderUri: null, filters: _filters[''] ?? [], offset: 0), recovered: true);
          return;
        }
        if (error.kind == 'filter' && query.filters.isNotEmpty) {
          _filters[''] = [];
          await _fetch(query.copyWith(filters: [], offset: 0), recovered: true);
          return;
        }
        if (error.kind == 'sort' && query.sortOrder != null) {
          _sorts[_sortKey(query)] = (null, null);
          await _fetch(query.copyWith(sortOrder: null, sortDirection: null, offset: 0), recovered: true);
          return;
        }
      }
      _publish(phase: LibraryPhase.failed, error: error);
    }
  }

  void _publish({LibraryQuery? query, LibraryPhase? phase, LibraryPage? page,
    List<LibraryItem>? items, LibraryItemsView? itemsView, bool? isLoadingMore,
    bool? hasMore, Object? error, bool clearError = false}) {
    _state = LibraryState(query: query ?? _state.query, phase: phase ?? _state.phase,
      page: page ?? _state.page, items: items ?? _state.items,
      itemsView: itemsView ?? _state.itemsView, isLoadingMore: isLoadingMore ?? _state.isLoadingMore,
      hasMore: hasMore ?? _state.hasMore, error: clearError ? null : error ?? _state.error);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request.cancel();
    _revision++;
    _cancelDebounce();
    if (repository case final LibrarySearchRepository current) current.cancelPendingRead();
    super.dispose();
  }
}
