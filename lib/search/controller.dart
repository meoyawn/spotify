import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'models.dart';
import 'repository.dart';

enum SearchPhase { idle, loading, ready, failed }

class SearchState {
  SearchState({
    this.query = '',
    this.responseQuery = '',
    this.phase = SearchPhase.idle,
    List<SearchItem> items = const [],
    this.isRecent = true,
    this.selectedIndex = -1,
    this.error,
  }) : items = List.unmodifiable(items);

  final String query;
  final String responseQuery;
  final SearchPhase phase;
  final List<SearchItem> items;
  final bool isRecent;
  final int selectedIndex;
  final Object? error;

  SearchItem? get selectedItem => selectedIndex >= 0 &&
          selectedIndex < items.length ? items[selectedIndex] : null;
}

/// Owns search state; superseded responses cannot replace a newer query.
class DesktopSearchController extends ChangeNotifier {
  DesktopSearchController(this.repository);

  final SearchRepository repository;
  SearchState _state = SearchState();
  SearchState get state => _state;

  CancellationToken? _timer;
  CancellationToken _query = CancellationToken();
  final _lifetime = CancellationToken();
  int? _lastCallAt;
  int _lastInvokeAt = 0;
  String? _pendingQuery;
  int _revision = 0;
  bool _initialized = false;
  bool _disposed = false;
  bool _updatingHistory = false;
  bool get isUpdatingHistory => _updatingHistory;
  static const _waitMilliseconds = 200;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    if (_state.phase != SearchPhase.idle) return;
    await refresh();
  }

  void setQuery(String query, {bool fetchSuggestions = true}) {
    if (_disposed || query == _state.query) return;
    _query.cancel(); _query = CancellationToken();
    _revision++;
    _publish(
      query: query,
      phase: SearchPhase.loading,
      isRecent: query.isEmpty,
      items: _state.isRecent != query.isEmpty ? [] : null,
    );
    if (!fetchSuggestions && query.isNotEmpty) {
      _resetDebounce();
    } else if (query.isEmpty) {
      _resetDebounce();
      unawaited(_fetchRecent(_revision));
    } else {
      _schedule(query);
    }
  }

  Future<void> removeRecent([String? uri]) async {
    final target = repository;
    if (_disposed || _updatingHistory || target is! FullSearchRepository || !_state.isRecent) return;
    final previous = _state.items, revision = ++_revision;
    final uris = uri == null ? previous.map((item) => item.uri).toList(growable: false) : [uri];
    if (uris.isEmpty) return;
    _query.cancel(); _query = CancellationToken();
    _updatingHistory = true;
    _publish(items: uri == null ? [] : previous.where((item) => item.uri != uri).toList());
    try {
      await (target as FullSearchRepository).removeRecent(uris, cancellationToken: _lifetime);
    } on CancelledException { return; } catch (error) {
      if (!_disposed && revision == _revision && _state.isRecent) _publish(items: previous, error: error);
    } finally {
      _updatingHistory = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> remember(SearchItem item) async {
    final target = repository;
    if (_disposed || target is! FullSearchRepository || item.uri.isEmpty || item.type == 'autocomplete') return;
    try {
      await (target as FullSearchRepository).saveRecent([item.uri], cancellationToken: _lifetime);
    } catch (_) { /* History must not delay a selected result or playback. */ }
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _query.cancel(); _query = CancellationToken();
    _revision++;
    _resetDebounce();
    _publish(phase: SearchPhase.loading, isRecent: _state.query.isEmpty);
    if (_state.query.isEmpty) {
      await _fetchRecent(_revision);
    } else {
      await _fetchSuggestions(_state.query, _revision);
    }
  }

  void moveSelection(int delta) {
    if (_disposed || _state.items.isEmpty) return;
    final current = _state.selectedIndex;
    final index = current < 0
        ? (delta < 0 ? _state.items.length - 1 : 0)
        : (current + delta) % _state.items.length;
    _publish(selectedIndex: index);
  }

  void _schedule(String query) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final invoke = _shouldInvoke(now);
    _pendingQuery = query;
    _lastCallAt = now;
    if (invoke) {
      if (_timer == null) {
        _lastInvokeAt = now;
        _startTimer(_waitMilliseconds);
        _invoke(now);
        return;
      }
      _startTimer(_waitMilliseconds);
      _invoke(now);
      return;
    }
    if (_timer == null) _startTimer(_waitMilliseconds);
  }

  bool _shouldInvoke(int now) => _lastCallAt == null ||
      now - _lastCallAt! >= _waitMilliseconds ||
      now - _lastCallAt! < 0 ||
      now - _lastInvokeAt >= _waitMilliseconds;

  void _startTimer(int milliseconds) {
    _timer?.cancel();
    final token = _timer = CancellationToken();
    unawaited(CancellableFuture.delayed<void>(Duration(milliseconds: math.max(0, milliseconds)), token)
      .then<void>((_) { if (identical(_timer, token)) _expire(); },
        onError: (Object error, StackTrace stack) {
          if (error is! CancelledException) Error.throwWithStackTrace(error, stack);
        }));
  }

  void _expire() {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_shouldInvoke(now)) {
      _timer = null;
      if (_pendingQuery != null) _invoke(now);
      return;
    }
    _startTimer(math.min(
      _waitMilliseconds - (now - _lastCallAt!),
      _waitMilliseconds - (now - _lastInvokeAt),
    ));
  }

  void _invoke(int now) {
    final query = _pendingQuery;
    _pendingQuery = null;
    _lastInvokeAt = now;
    if (query != null) unawaited(_fetchSuggestions(query, _revision));
  }

  void _resetDebounce() {
    _timer?.cancel();
    _timer = null;
    _pendingQuery = null;
    _lastCallAt = null;
    _lastInvokeAt = 0;
  }

  Future<void> _fetchRecent(int revision) =>
      _fetch((token) => repository.recent(cancellationToken: token), revision, recent: true);

  Future<void> _fetchSuggestions(String query, int revision) =>
      _fetch((token) => repository.suggestions(query, cancellationToken: token), revision, recent: false);

  Future<void> _fetch(
    Future<SearchPage> Function(CancellationToken) request,
    int revision, {
    required bool recent,
  }) async {
    final token = _query;
    try {
      token.throwIfCancelled();
      final page = await request(token);
      if (_disposed || revision != _revision) return;
      _publish(
        phase: SearchPhase.ready,
        items: page.items,
        responseQuery: page.query,
        isRecent: recent,
      );
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      _publish(phase: SearchPhase.failed, error: error, items: []);
    }
  }

  void _publish({
    String? query,
    String? responseQuery,
    SearchPhase? phase,
    List<SearchItem>? items,
    bool? isRecent,
    int selectedIndex = -1,
    Object? error,
  }) {
    _state = SearchState(
      query: query ?? _state.query,
      responseQuery: responseQuery ?? _state.responseQuery,
      phase: phase ?? _state.phase,
      items: items ?? _state.items,
      isRecent: isRecent ?? _state.isRecent,
      selectedIndex: selectedIndex,
      error: error,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _query.cancel(); _lifetime.cancel();
    _revision++;
    _resetDebounce();
    super.dispose();
  }
}
