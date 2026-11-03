import 'package:flutter/foundation.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'controller.dart';
import 'destinations_repository.dart';
import 'models.dart';

class HomeDestinationState {
  const HomeDestinationState({this.phase = HomePhase.idle, this.page, this.error,
    this.loadingMore = false, this.moreError});
  final HomePhase phase;
  final HomeDestinationPage? page;
  final Object? error, moreError;
  final bool loadingMore;
}

class HomeDestinationController extends ChangeNotifier {
  HomeDestinationController(this.repository, this.target);
  final HomeDestinationRepository repository;
  final HomeDestinationTarget target;
  HomeDestinationState _state = const HomeDestinationState();
  HomeDestinationState get state => _state;
  DateTime? _loadedAt;
  int _revision = 0;
  CancellationToken _request = CancellationToken();
  bool _disposed = false;

  Future<void> initialize() async {
    final stale = Duration(minutes: target.kind == HomeDestinationKind.homeSection ? 5 : 15);
    if (_state.phase == HomePhase.loading || _loadedAt?.add(stale).isAfter(DateTime.now()) == true) return;
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _request.cancel();
    final token = _request = CancellationToken();
    final revision = ++_revision;
    _state = HomeDestinationState(phase: HomePhase.loading, page: _state.page);
    notifyListeners();
    try {
      final page = await repository.destination(target, cancellationToken: token);
      if (_disposed || revision != _revision) return;
      _loadedAt = DateTime.now();
      _state = HomeDestinationState(phase: HomePhase.ready, page: page);
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      _state = HomeDestinationState(phase: HomePhase.failed, page: _state.page, error: error);
    }
    notifyListeners();
  }

  Future<void> loadMore() async {
    final previous = _state.page, offset = _state.page?.nextOffset;
    if (_disposed || _state.phase != HomePhase.ready || _state.loadingMore || previous == null || offset == null) return;
    final revision = _revision;
    _state = HomeDestinationState(phase: HomePhase.ready, page: previous, loadingMore: true);
    notifyListeners();
    try {
      final pageTarget = previous.continuationTarget ?? target;
      final next = await repository.destination(pageTarget, offset: offset, cancellationToken: _request);
      if (_disposed || revision != _revision) return;
      final sections = [...previous.sections];
      for (final section in next.sections) {
        final index = pageTarget.kind == HomeDestinationKind.browsePage ? -1
          : sections.indexWhere((old) => old.uri == section.uri);
        if (index < 0) {
          sections.add(section);
        } else {
          final old = sections[index];
          sections[index] = HomeSection(uri: old.uri, kind: old.kind, sourceType: old.sourceType,
            title: old.title, pretitle: old.pretitle, source: old.source,
            items: [...old.items, ...section.items]);
        }
      }
      _state = HomeDestinationState(phase: HomePhase.ready, page: HomeDestinationPage(
        title: previous.title, subtitle: previous.subtitle, color: previous.color,
        fullPage: previous.fullPage, continuationTarget: previous.continuationTarget,
        sections: sections, nextOffset: next.nextOffset));
    } on CancelledException { return; } catch (error) {
      if (_disposed || revision != _revision) return;
      _state = HomeDestinationState(phase: HomePhase.ready, page: previous, moreError: error);
    }
    notifyListeners();
  }

  @override
  void dispose() { _disposed = true; _revision++; _request.cancel(); super.dispose(); }
}
