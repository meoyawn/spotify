import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:cancellation_token/cancellation_token.dart';

import 'controller.dart';
import 'models.dart';
import 'repository.dart';
import 'view.dart';
import '../app/share_links.dart';

/// Full results use their own requests; the global field still owns suggestions.
class SearchResultsView extends StatefulWidget {
  const SearchResultsView({super.key, required this.controller, required this.query,
    required this.onSelect, required this.onCategory, this.category, this.onPlay, this.artworkBuilder});
  final DesktopSearchController controller;
  final String query;
  final SearchCategory? category;
  final ValueChanged<SearchItem> onSelect;
  final ValueChanged<SearchCategory?> onCategory;
  final ValueChanged<SearchItem>? onPlay;
  final SearchArtworkBuilder? artworkBuilder;
  @override State<SearchResultsView> createState() => _SearchResultsViewState();
}

class _SearchResultsViewState extends State<SearchResultsView> {
  final _scroll = ScrollController();
  SearchResults? _page;
  SearchResults? _overview;
  List<SearchItem> _items = const [];
  int _revision = 0, _total = 0;
  CancellationToken _request = CancellationToken();
  int? _nextOffset;
  bool _loading = true, _loadingMore = false;
  Object? _error;

  @override void initState() {
    super.initState();
    widget.controller.addListener(_historyChanged);
    _scroll.addListener(_scrolled);
    unawaited(_open());
  }
  @override void didUpdateWidget(SearchResultsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_historyChanged);
      widget.controller.addListener(_historyChanged);
    }
    if (oldWidget.query != widget.query || oldWidget.category != widget.category || oldWidget.controller != widget.controller) {
      if (oldWidget.query != widget.query || oldWidget.controller != widget.controller) _overview = null;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      unawaited(_open());
    }
  }
  void _historyChanged() { if (mounted && widget.query.isEmpty) setState(() {}); }
  void _scrolled() {
    if (_error == null && _scroll.hasClients && _scroll.position.extentAfter < 400 && _scroll.position.pixels > 0) unawaited(_more());
  }
  Future<void> _open() async {
    _request.cancel();
    final token = _request = CancellationToken();
    final revision = ++_revision;
    _page = null; _items = const []; _nextOffset = null; _total = 0;
    _loading = true; _loadingMore = false; _error = null;
    if (mounted) setState(() {});
    if (widget.query.isEmpty) {
      await widget.controller.initialize();
      if (mounted && revision == _revision) setState(() => _loading = false);
      return;
    }
    final repository = widget.controller.repository;
    try {
      if (repository is! FullSearchRepository) throw const SearchQueryError('Full search unavailable');
      final page = await (repository as FullSearchRepository).results(widget.query, category: widget.category,
        cancellationToken: token);
      if (!mounted || revision != _revision) return;
      setState(() {
        _page = page; _loading = false;
        if (widget.category == null) _overview = page;
        final section = page.sections[widget.category];
        _items = section?.items ?? const [];
        _total = section?.totalCount ?? 0;
        _nextOffset = _cursor(section, 0);
      });
    } on CancelledException { return; } catch (error) {
      if (mounted && revision == _revision) setState(() { _loading = false; _error = error; });
    }
  }
  int? _cursor(SearchSection? section, int offset) {
    if (section == null) return null;
    final cursor = widget.category == SearchCategory.episodes
      ? (section.returnedCount == 0 ? null : offset + section.returnedCount) : section.nextOffset;
    return cursor != null && cursor > offset && cursor < section.totalCount ? cursor : null;
  }
  Future<void> _more() async {
    final offset = _nextOffset, category = widget.category, repository = widget.controller.repository;
    if (_loading || _loadingMore || offset == null || category == null || repository is! FullSearchRepository) return;
    final revision = _revision;
    setState(() { _loadingMore = true; _error = null; });
    try {
      final page = await (repository as FullSearchRepository).results(widget.query, category: category,
        offset: offset, limit: math.min(category.pageSize, _total - offset), cancellationToken: _request);
      if (!mounted || revision != _revision) return;
      setState(() {
        final section = page.sections[category];
        _items = [..._items, ...?section?.items]; _total = section?.totalCount ?? _total;
        _nextOffset = _cursor(section, offset); _loadingMore = false;
      });
    } on CancelledException { return; } catch (error) {
      if (mounted && revision == _revision) setState(() { _loadingMore = false; _error = error; });
    }
  }
  @override void dispose() {
    _request.cancel();
    _revision++;
    widget.controller.removeListener(_historyChanged);
    _scroll.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    if (widget.query.isEmpty) return _recent();
    final page = _page, category = widget.category, overview = _overview;
    final categories = overview == null && category != null ? SearchCategory.values : {
      ...?(overview ?? page)?.chipOrder,
      ...SearchCategory.values.where((kind) => kind == category || ((overview ?? page)?.sections[kind]?.totalCount ?? 0) > 0),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
        child: Row(spacing: 8, children: [
          _chip('All', null),
          for (final kind in categories) _chip(kind.label, kind),
        ])),
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator(color: Color(0xff1ed760)))
        : _error != null && page == null ? _failure(_open)
        : category == null ? _all(page!) : _category()),
    ]);
  }
  Widget _chip(String label, SearchCategory? category) => ChoiceChip(label: Text(label),
    selected: widget.category == category, onSelected: (_) => widget.onCategory(category), showCheckmark: false,
    selectedColor: Colors.white, backgroundColor: const Color(0xff282828), side: BorderSide.none,
    labelStyle: TextStyle(color: widget.category == category ? Colors.black : Colors.white));

  Widget _recent() {
    final state = widget.controller.state;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(24, 24, 24, 12), child: Row(children: [
        const Expanded(child: Text('Recent searches', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
        if (state.items.isNotEmpty) TextButton(onPressed: widget.controller.isUpdatingHistory ? null
          : () => unawaited(widget.controller.removeRecent()), child: const Text('Clear all', style: TextStyle(color: Color(0xffb3b3b3)))),
      ])),
      if (state.error != null) const Padding(padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text('Couldn’t update recent searches. Try again.', style: TextStyle(color: Color(0xffb3b3b3)))),
      Expanded(child: state.phase == SearchPhase.loading && state.items.isEmpty
        ? const Center(child: CircularProgressIndicator(color: Color(0xff1ed760)))
        : state.items.isEmpty ? Center(child: state.phase == SearchPhase.failed ? _failure(widget.controller.refresh)
          : const Text('Your recent searches will appear here.', style: TextStyle(color: Color(0xffb3b3b3))))
        : LayoutBuilder(builder: (context, constraints) => GridView.builder(controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: math.max(1, (constraints.maxWidth / 190).floor()),
            mainAxisExtent: 254, crossAxisSpacing: 8, mainAxisSpacing: 8), itemCount: state.items.length,
          itemBuilder: (context, index) => _card(state.items[index], recent: true)))),
    ]);
  }

  Widget _all(SearchResults page) {
    if (page.items.isEmpty) return _empty();
    return LayoutBuilder(builder: (context, constraints) => CustomScrollView(controller: _scroll, slivers: [
      SliverPadding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 24), sliver: SliverToBoxAdapter(
        child: constraints.maxWidth >= 680 ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (page.topResults.isNotEmpty) Expanded(flex: 2, child: _top(page.topResults.first)),
          if (page.topResults.isNotEmpty) const SizedBox(width: 24),
          Expanded(flex: 3, child: _songs(page.sections[SearchCategory.tracks]?.items ?? const [])),
        ]) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (page.topResults.isNotEmpty) _top(page.topResults.first), const SizedBox(height: 24),
          _songs(page.sections[SearchCategory.tracks]?.items ?? const []),
        ]))),
      for (final kind in const [SearchCategory.artists, SearchCategory.albums, SearchCategory.playlists,
        SearchCategory.podcasts, SearchCategory.episodes, SearchCategory.audiobooks, SearchCategory.authors, SearchCategory.users, SearchCategory.genres])
        if (page.sections[kind] case final section? when section.items.isNotEmpty) ...[
          SliverToBoxAdapter(child: _heading(kind.label, onMore: () => widget.onCategory(kind))),
          SliverPadding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: math.max(1, (constraints.maxWidth / 190).floor()),
              mainAxisExtent: 254, crossAxisSpacing: 8),
            delegate: SliverChildBuilderDelegate((context, index) => _card(section.items[index]),
              childCount: math.min(section.items.length, math.max(1, (constraints.maxWidth / 190).floor()))))),
        ],
    ]));
  }
  Widget _top(SearchItem item) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('Top result', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)), const SizedBox(height: 16),
    SpotifyLinkContextMenu(uri: item.uri, child: Material(color: const Color(0xff181818), borderRadius: BorderRadius.circular(8), child: InkWell(
      borderRadius: BorderRadius.circular(8), onTap: () => widget.onSelect(item), child: Padding(
        padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox.square(dimension: 92, child: _art(item)), const SizedBox(height: 16),
          Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8), Text([_type(item), ...item.contributors].join(' • '), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xffb3b3b3))),
        ]))))),
  ]);
  Widget _songs(List<SearchItem> songs) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(children: [const Expanded(child: Text('Songs', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
      if (songs.isNotEmpty) TextButton(onPressed: () => widget.onCategory(SearchCategory.tracks), child: const Text('Show all', style: TextStyle(color: Color(0xffb3b3b3)))),
    ]), const SizedBox(height: 8), for (final item in songs.take(4)) _row(item),
  ]);
  Widget _heading(String title, {VoidCallback? onMore}) => Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
    child: Row(children: [Expanded(child: Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
      if (onMore != null) TextButton(onPressed: onMore, child: const Text('Show all', style: TextStyle(color: Color(0xffb3b3b3)))),
    ]));

  Widget _category() {
    if (_items.isEmpty && _error == null && _nextOffset == null) return _empty();
    return CustomScrollView(controller: _scroll, slivers: [
      SliverToBoxAdapter(child: _heading(widget.category!.label)),
      if (widget.category == SearchCategory.tracks || widget.category == SearchCategory.episodes)
        SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 24), sliver: SliverList.builder(
          itemCount: _items.length, itemBuilder: (context, index) => _row(_items[index], number: index + 1)))
      else SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 16), sliver: SliverLayoutBuilder(
        builder: (context, constraints) => SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: math.max(1, (constraints.crossAxisExtent / 190).floor()),
            mainAxisExtent: 254, crossAxisSpacing: 8, mainAxisSpacing: 8),
          delegate: SliverChildBuilderDelegate((context, index) => _card(_items[index]), childCount: _items.length)))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(24), child: Center(child:
        _loadingMore ? const CircularProgressIndicator(color: Color(0xff1ed760))
        : _error != null ? _failure(_more)
        : _nextOffset != null ? OutlinedButton(onPressed: _more, child: const Text('Load more')) : const SizedBox.shrink()))),
    ]);
  }
  Widget _card(SearchItem item, {bool recent = false}) => Material(color: Colors.transparent,
    borderRadius: BorderRadius.circular(6), child: InkWell(borderRadius: BorderRadius.circular(6),
      hoverColor: const Color(0xff282828), onTap: () => widget.onSelect(item), child: Padding(
        padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Stack(fit: StackFit.expand, children: [Center(child: AspectRatio(aspectRatio: 1, child: _art(item))),
            if (recent) Positioned(top: 0, right: 0, child: IconButton.filled(
              tooltip: 'Remove ${item.name} from recent searches', icon: const Icon(Icons.close, size: 18),
              style: IconButton.styleFrom(backgroundColor: Colors.black87),
              onPressed: widget.controller.isUpdatingHistory ? null : () => unawaited(widget.controller.removeRecent(item.uri)))),
          ])), const SizedBox(height: 12),
          Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 5), Text([_type(item), ...item.contributors].where((value) => value.isNotEmpty).join(' • '),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xffb3b3b3))),
        ]))));
  Widget _row(SearchItem item, {int? number}) => SpotifyLinkContextMenu(uri: item.uri,
    child: Material(color: Colors.transparent, borderRadius: BorderRadius.circular(4),
    child: InkWell(onTap: () => widget.onSelect(item),
      onDoubleTap: widget.onPlay != null && item.isPlayable != false ? () => widget.onPlay!(item) : null,
      hoverColor: const Color(0xff282828), borderRadius: BorderRadius.circular(4), child: SizedBox(height: 58,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          if (number != null) SizedBox(width: 28, child: Text('$number', style: const TextStyle(color: Color(0xffb3b3b3)))),
          SizedBox.square(dimension: 40, child: _art(item)), const SizedBox(width: 12),
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
            Text([if (item.isExplicit) 'E', ...item.contributors].join(' • '), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xffb3b3b3))),
          ])),
          if (item.durationMs case final duration?) Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('${duration ~/ 60000}:${(duration ~/ 1000 % 60).toString().padLeft(2, '0')}', style: const TextStyle(color: Color(0xffb3b3b3)))),
          if (widget.onPlay != null && item.isPlayable != false) IconButton(tooltip: 'Play ${item.name}',
            onPressed: () => widget.onPlay!(item), icon: const Icon(Icons.play_arrow, size: 20)),
          if (item.type == 'track') SpotifyLinkMenu(uri: item.uri, name: item.name),
        ]))))));
  Widget _art(SearchItem item) => ClipRRect(borderRadius: BorderRadius.circular(
    const {'artist', 'author', 'user'}.contains(item.type) ? 999 : 4),
    child: widget.artworkBuilder?.call(context, item) ?? const ColoredBox(color: Color(0xff282828), child: Icon(Icons.music_note)));
  String _type(SearchItem item) => switch (item.type) {
    'track' => 'Song', 'artist' => 'Artist', 'album' => 'Album', 'playlist' => 'Playlist',
    'show' => 'Podcast', 'episode' => 'Episode', 'audiobook' => 'Audiobook', 'author' => 'Author',
    'user' => 'Profile', 'genre' => 'Genre', 'pre-release-album' => 'Upcoming release', _ => '',
  };
  Widget _empty() => Center(child: Text('No results found for “${widget.query}”', textAlign: TextAlign.center,
    style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 16)));
  Widget _failure(Future<void> Function() retry) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Text('Couldn’t load search results.', style: TextStyle(color: Color(0xffb3b3b3))), const SizedBox(height: 12),
    OutlinedButton(onPressed: () => unawaited(retry()), child: const Text('Try again')),
  ]));
}
