import 'package:flutter/foundation.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'models.dart';
import 'repository.dart';

enum HomePhase { idle, loading, ready, failed }

class HomeState {
  const HomeState({this.facet = '', this.phase = HomePhase.idle, this.page, this.error});
  final String facet;
  final HomePhase phase;
  final HomePage? page;
  final Object? error;
}

/// Retains prior content while refreshing, and rejects superseded responses.
class HomeController extends ChangeNotifier {
  HomeController(this.repository);
  final HomeRepository repository;
  HomeState _state = const HomeState();
  HomeState get state => _state;
  bool _initialized = false;
  bool _disposed = false;
  int _revision = 0;
  CancellationToken _request = CancellationToken();

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    if (_state.phase == HomePhase.idle) await refresh();
  }

  Future<void> setFacet(String facet) async {
    if (_disposed || facet == _state.facet) return;
    _state = HomeState(facet: facet, phase: _state.phase, page: _state.page);
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _request.cancel();
    final token = _request = CancellationToken();
    final revision = ++_revision;
    final facet = _state.facet;
    _state = HomeState(facet: facet, phase: HomePhase.loading, page: _state.page);
    notifyListeners();
    try {
      final page = await repository.load(facet: facet, cancellationToken: token);
      if (_disposed || revision != _revision) return;
      _state = HomeState(facet: facet, phase: HomePhase.ready, page: page);
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      _state = HomeState(facet: facet, phase: HomePhase.failed, page: _state.page, error: error);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request.cancel();
    _revision++;
    super.dispose();
  }
}
