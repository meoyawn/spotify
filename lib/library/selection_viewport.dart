import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';

/// A virtualized Library can reveal a route before its row has been built.
class LibrarySelectionViewport extends StatefulWidget {
  const LibrarySelectionViewport({super.key, required this.library, required this.activeUri,
    required this.rowExtent, required this.itemCount, required this.builder, this.columns = 1, this.topPadding = 0});
  final LibraryController library;
  final String? activeUri;
  final double rowExtent, topPadding;
  final int columns;
  final int itemCount;
  final Widget Function(ScrollController controller) builder;

  @override
  State<LibrarySelectionViewport> createState() => _LibrarySelectionViewportState();
}

class _LibrarySelectionViewportState extends State<LibrarySelectionViewport> {
  final _scroll = ScrollController();
  bool _pending = true, _scheduled = false;
  int _pagesRequested = 0;
  String? _loadingUri;
  LibraryQuery? _query;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_schedule);
    _schedule();
  }

  @override
  void didUpdateWidget(LibrarySelectionViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_schedule);
      widget.library.addListener(_schedule);
    }
    if (oldWidget.library != widget.library || oldWidget.activeUri != widget.activeUri ||
        oldWidget.rowExtent != widget.rowExtent || oldWidget.columns != widget.columns) {
      _pending = true;
      _pagesRequested = 0;
    }
    _schedule();
  }

  void _schedule() {
    final query = widget.library.state.query;
    if (!identical(_query, query)) { _query = query; _pending = true; _pagesRequested = 0; }
    if (!_pending || _scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted && _pending) _reveal();
    });
  }

  void _reveal() {
    final uri = widget.activeUri;
    if (uri == null) { _pending = false; return; }
    final state = widget.library.state;
    if (state.phase != LibraryPhase.ready || state.error != null) return;
    final index = state.items.indexWhere((item) => libraryUriMatches(item.uri, uri));
    if (index < 0) {
      if (!state.hasMore) { _pending = false; return; }
      if (!uri.startsWith('spotify:playlist:') &&
          !RegExp(r'^spotify:user:[^:]+:playlist:').hasMatch(uri)) { _pending = false; return; }
      // A route outside the active filter/folder remains highlighted if it
      // becomes visible, without walking every unrelated Library result.
      if (state.query.textFilter.isNotEmpty || state.query.filters.isNotEmpty ||
          state.query.folderUri != null) { _pending = false; return; }
      // External route reveal is bounded. A Library containing thousands of
      // albums/artists must not hydrate them all to locate an old playlist.
      if (_pagesRequested >= 2) { _pending = false; return; }
      if (!state.isLoadingMore && _loadingUri != uri) {
        _pagesRequested++;
        _loadingUri = uri;
        unawaited(widget.library.loadMore().whenComplete(() {
          _loadingUri = null;
          if (mounted) _schedule();
        }));
      }
      return;
    }
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
    if (index >= widget.itemCount) return;
    final start = widget.topPadding + (index ~/ widget.columns) * widget.rowExtent;
    final end = start + widget.rowExtent;
    final position = _scroll.position;
    final target = start < position.pixels ? start
      : end > position.pixels + position.viewportDimension ? end - position.viewportDimension
      : position.pixels;
    _pending = target > position.maxScrollExtent;
    if (target != position.pixels) {
      _scroll.jumpTo(target.clamp(position.minScrollExtent,
        math.max(position.minScrollExtent, position.maxScrollExtent)));
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_schedule);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (_) { _schedule(); return false; }, child: widget.builder(_scroll));
}
