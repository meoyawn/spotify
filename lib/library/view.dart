import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/shell_icons.dart';
import '../app/desktop_icon_button.dart';
import '../app/share_links.dart';
import 'controller.dart';
import 'models.dart';
import 'selection_viewport.dart';

typedef LibraryArtworkBuilder = Widget Function(BuildContext context, LibraryItem item);
typedef LibraryItemActionsBuilder = Widget Function(BuildContext context, LibraryItem item);

class LibraryView extends StatefulWidget {
  const LibraryView({super.key, required this.controller, required this.onSelect,
    this.onOpenFolder, this.artworkBuilder, this.actionsBuilder, this.showHeader = true, this.activeUri});
  final LibraryController controller;
  final ValueChanged<LibraryItem> onSelect;
  final ValueChanged<LibraryItem>? onOpenFolder;
  final LibraryArtworkBuilder? artworkBuilder;
  final LibraryItemActionsBuilder? actionsBuilder;
  final bool showHeader;
  final String? activeUri;

  @override
  State<LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<LibraryView> {
  late final TextEditingController _input;
  final _searchFocus = FocusNode();
  bool _searchOpen = false;
  final _chipScroll = ScrollController();
  bool _loadMoreScheduled = false;

  void _loadMoreAfterLayout() {
    if (_loadMoreScheduled) return;
    _loadMoreScheduled = true;
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMoreScheduled = false;
      if (!mounted || !identical(controller, widget.controller)) return;
      final state = controller.state;
      if (state.hasMore && !state.isLoadingMore && state.error == null && state.phase != LibraryPhase.loading) {
        unawaited(controller.loadMore());
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.controller.state.query.textFilter);
    widget.controller.addListener(_syncInput);
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(LibraryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncInput);
      widget.controller.addListener(_syncInput);
      _syncInput();
      unawaited(widget.controller.initialize());
    }
  }

  void _syncInput() {
    final text = widget.controller.state.query.textFilter;
    if (_input.text != text) {
      _input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncInput);
    _input.dispose();
    _searchFocus.dispose();
    _chipScroll.dispose();
    super.dispose();
  }

  void _activate(LibraryItem item) {
    if (!item.isSupported) return;
    if (item.type == 'folder') {
      unawaited(widget.controller.openFolder(item.uri));
      widget.onOpenFolder?.call(item);
    } else {
      widget.onSelect(item);
    }
  }

  @override
  Widget build(BuildContext context) => Material(color: const Color(0xff121212),
    child: ListenableBuilder(listenable: widget.controller, builder: (context, _) {
      final state = widget.controller.state;
      final page = state.page;
      Widget? content;
      bool? contentWide;
      return LayoutBuilder(builder: (context, constraints) => developer.Timeline.timeSync('ui.library.layout', () {
        final wide = constraints.maxWidth >= 480;
        if (content != null && contentWide == wide) return content!;
        contentWide = wide;
        return content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.showHeader) const Padding(padding: EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Text('Your Library', style: TextStyle(fontFamily: 'SpotifyMixUITitle',
              fontSize: 24, fontWeight: FontWeight.w700))),
          if (state.query.folderUri != null) Row(children: [
            IconButton(tooltip: 'Back to parent folder', onPressed: widget.controller.goToParentFolder,
              icon: const Icon(SpotifyShellIcons.back, size: 16)),
            Expanded(child: Text(page?.openedFolderName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          if (page != null && (page.availableFilters.isNotEmpty || page.selectedFilters.isNotEmpty))
            _filters(page, state),
          _searchAndSort(state, wide),
          if (state.phase == LibraryPhase.loading && page != null)
            const LinearProgressIndicator(minHeight: 2, color: Color(0xff1ed760)),
          if (state.error != null && page != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              const Expanded(child: Text('Couldn’t load Your Library', style: _secondary)),
              TextButton(onPressed: state.phase == LibraryPhase.failed ? widget.controller.refresh : widget.controller.loadMore,
                child: const Text('Try again')),
            ])),
          Expanded(child: page == null
            ? state.phase == LibraryPhase.failed
                ? _status('Couldn’t load Your Library', retry: widget.controller.refresh)
                : const Center(child: CircularProgressIndicator(color: Color(0xff1ed760)))
            : state.items.isEmpty
                ? _status(state.phase == LibraryPhase.loading ? 'Searching Your Library…'
                  : state.query.textFilter.isEmpty ? 'Your Library is empty' : 'No results found')
                : NotificationListener<ScrollNotification>(onNotification: (notification) {
                    if (notification.metrics.axis == Axis.vertical && notification.metrics.extentAfter < 256 &&
                        state.hasMore && !state.isLoadingMore && state.error == null) {
                      _loadMoreAfterLayout();
                    }
                    return false;
                  }, child: state.itemsView == LibraryItemsView.grid || state.itemsView == LibraryItemsView.compactGrid
                    ? _grid(state) : _list(state))),
        ],
      );
      }, arguments: {'width': constraints.maxWidth, 'height': constraints.maxHeight, 'cached': content != null}));
    }),
  );

  Widget _filters(LibraryPage page, LibraryState state) {
    final options = <String, LibraryOption>{for (final option in [...page.selectedFilters, ...page.availableFilters]) option.id: option};
    final selected = page.selectedFilters.map((option) => option.id).toSet();
    return SizedBox(height: 48, child: LayoutBuilder(builder: (context, bounds) {
      final overflow = options.values.fold<double>(selected.isNotEmpty ? 40 : 0,
        (width, option) => width + _labelWidth(context, option.name) + 32) > bounds.maxWidth - 32;
      return Stack(children: [ListView(controller: _chipScroll, scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16), children: [
        if (selected.isNotEmpty) IconButton(tooltip: 'Clear Library filters',
          onPressed: widget.controller.clearFilters, icon: const Icon(SpotifyShellIcons.close, size: 16)),
        for (final option in options.values) Center(child: Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(
          label: Text(option.name, style: const TextStyle(fontSize: 14)), selected: selected.contains(option.id),
          showCheckmark: false, side: BorderSide.none, backgroundColor: const Color(0xff292929),
          shape: const StadiumBorder(), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          selectedColor: const Color(0xfff0f0f0),
          labelStyle: TextStyle(color: selected.contains(option.id) ? Colors.black : Colors.white),
          onSelected: (_) => selected.contains(option.id) && page.selectedFilters.first.id == option.id
            ? widget.controller.clearFilters() : widget.controller.toggleFilter(option.id),
        ))),
      ],
      ), if (overflow) Positioned(right: 8, top: 8, bottom: 8, child: DecoratedBox(
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xff1f1f1f),
          boxShadow: [BoxShadow(color: Color(0xff121212), blurRadius: 12, spreadRadius: 6)]),
        child: DesktopIconButton(size: 32, tooltip: 'More Library filters',
          icon: const Icon(SpotifyShellIcons.forward, size: 16),
          onPressed: () => _chipScroll.jumpTo((_chipScroll.offset + bounds.maxWidth * 0.7)
            .clamp(0, _chipScroll.position.maxScrollExtent))))),
    ]); }));
  }

  Widget _searchAndSort(LibraryState state, bool wide) {
    final page = state.page, searching = _searchOpen || state.query.textFilter.isNotEmpty;
    return Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: SizedBox(height: 40,
      child: Row(children: [
        if (searching) Expanded(child: CallbackShortcuts(bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            unawaited(widget.controller.setTextFilter(''));
            _searchFocus.unfocus(); setState(() => _searchOpen = false);
          },
        }, child: TextField(controller: _input, focusNode: _searchFocus,
          onChanged: widget.controller.setTextFilter, style: const TextStyle(fontSize: 14),
          onTapOutside: (_) { if (_input.text.isEmpty) { _searchFocus.unfocus(); setState(() => _searchOpen = false); } },
          decoration: InputDecoration(hintText: 'Search in Your Library', isDense: true,
            filled: true, fillColor: const Color(0xff2a2a2a),
            prefixIcon: const Icon(SpotifyShellIcons.search, size: 16),
            prefixIconConstraints: const BoxConstraints(minWidth: 32),
            suffixIcon: state.query.textFilter.isEmpty ? null : IconButton(tooltip: 'Clear library search',
              icon: const Icon(SpotifyShellIcons.close, size: 16),
              onPressed: () => unawaited(widget.controller.setTextFilter(''))),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.symmetric(vertical: 8)),
        ))) else ...[
          DesktopIconButton(size: 32, tooltip: 'Search in Your Library',
            icon: const Icon(SpotifyShellIcons.search, size: 16), onPressed: () {
              setState(() => _searchOpen = true); _searchFocus.requestFocus();
            }), const Spacer(),
        ],
        if (page != null) PopupMenuButton<Object>(tooltip: 'Sort: ${page.selectedSortOrder.name}',
          onSelected: (value) {
            if (value is LibraryItemsView) { widget.controller.setItemsView(value); }
            else { unawaited(widget.controller.selectSort(value as String)); }
          }, itemBuilder: (_) => [
            const PopupMenuItem<Object>(enabled: false, height: 32, child: Text('Sort by', style: _secondary)),
            for (final option in page.availableSortOrders)
              CheckedPopupMenuItem<Object>(value: option.id, checked: page.selectedSortOrder.id == option.id,
                child: Text(option.name)),
            const PopupMenuDivider(),
            const PopupMenuItem<Object>(enabled: false, height: 32, child: Text('View as', style: _secondary)),
            for (final view in LibraryItemsView.values)
              CheckedPopupMenuItem<Object>(value: view, checked: state.itemsView == view, child: Text(_viewName(view))),
          ], child: Padding(padding: const EdgeInsets.only(left: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (!searching || wide) ...[Text(page.selectedSortOrder.name, style: _secondary), const SizedBox(width: 8)],
            Icon(state.itemsView == LibraryItemsView.grid || state.itemsView == LibraryItemsView.compactGrid
              ? Icons.grid_view_rounded : Icons.format_list_bulleted, size: 20, color: const Color(0xffb3b3b3)),
          ]))),
      ])));
  }

  Widget _list(LibraryState state) {
    final compact = state.itemsView == LibraryItemsView.compact;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final height = math.max(compact ? 32.0 : 64.0, (compact ? 28 : 56) * scale);
    return LibrarySelectionViewport(library: widget.controller, activeUri: widget.activeUri,
      rowExtent: height, itemCount: state.items.length,
      builder: (scroll) => ListView.builder(key: const PageStorageKey('library-list'),
      controller: scroll,
      padding: const EdgeInsets.symmetric(horizontal: 8), itemExtent: height,
      itemCount: state.items.length + (state.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == state.items.length) return _more(state);
        final item = state.items[index];
        if (!item.isSupported) return const Center(child: Text('Content is currently unavailable.', style: _secondary));
        final selected = libraryUriMatches(item.uri, widget.activeUri);
        return SpotifyLinkContextMenu(uri: item.uri, child: Semantics(selected: selected, child: Material(
          color: selected ? const Color(0xff333333) : Colors.transparent,
          borderRadius: BorderRadius.circular(4), clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: () => _activate(item), child: Padding(
            padding: EdgeInsets.only(left: 8 + math.min(item.folderDepth ?? 0, 6) * 16, right: 8),
            child: Row(children: [
              if (!compact) Padding(padding: const EdgeInsets.only(right: 12),
                child: SizedBox.square(dimension: 48, child: ClipRRect(
                  borderRadius: BorderRadius.circular(item.type == 'artist' || item.type == 'author' ? 24 : 4),
                  child: _artwork(context, item)))),
              Expanded(child: compact
                ? Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))
                : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, color: selected ? const Color(0xff1ed760) : Colors.white)),
                    const SizedBox(height: 3), Row(children: [
                      if (item.pinned) const Padding(padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.push_pin, size: 12, color: Color(0xff1ed760), semanticLabel: 'Pinned')),
                      Expanded(child: Text(_subtitle(item, state.page?.primaryFilter), maxLines: 1,
                        overflow: TextOverflow.ellipsis, style: _secondary)),
                    ])])),
              if (compact && item.pinned) const Icon(Icons.push_pin, size: 12, color: Color(0xff1ed760)),
              if (item.type == 'folder' && state.query.textFilter.isEmpty) IconButton(
                tooltip: state.query.expandedFolders.contains(item.uri) ? 'Collapse folder' : 'Expand folder',
                constraints: const BoxConstraints.tightFor(width: 32, height: 32), padding: EdgeInsets.zero,
                onPressed: () => widget.controller.toggleExpandedFolder(item.uri),
                icon: Icon(state.query.expandedFolders.contains(item.uri) ? Icons.expand_less : Icons.expand_more, size: 18)),
              if (widget.actionsBuilder != null) widget.actionsBuilder!(context, item),
            ]),
          )))));
      },
    ));
  }

  Widget _grid(LibraryState state) {
    final compact = state.itemsView == LibraryItemsView.compactGrid;
    return LayoutBuilder(builder: (context, constraints) {
      final minimum = compact ? constraints.maxWidth < 405 ? 102 : 140
          : constraints.maxWidth < 336 ? 116 : constraints.maxWidth < 405 ? 130 : 155;
      final columns = ((constraints.maxWidth - 16 + 8) / (minimum + 8)).floor().clamp(1, 100);
      final width = (constraints.maxWidth - 16 - (columns - 1) * 8) / columns;
      final scale = MediaQuery.textScalerOf(context).scale(1);
      return LibrarySelectionViewport(library: widget.controller, activeUri: widget.activeUri,
        rowExtent: width + (compact ? 48 : 68) * scale + 8, columns: columns, topPadding: 8,
        itemCount: state.items.length,
        builder: (scroll) => GridView.builder(key: const PageStorageKey('library-grid'),
      controller: scroll, padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
        mainAxisExtent: width + (compact ? 48 : 68) * scale, mainAxisSpacing: 8, crossAxisSpacing: 8),
      itemCount: state.items.length + (state.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == state.items.length) return _more(state);
        final item = state.items[index];
        final selected = libraryUriMatches(item.uri, widget.activeUri);
        return SpotifyLinkContextMenu(uri: item.uri, child: Semantics(selected: selected, child: Material(
          color: selected ? const Color(0xff333333) : Colors.transparent,
          borderRadius: BorderRadius.circular(6), clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: item.isSupported ? () => _activate(item) : null,
            child: Padding(padding: const EdgeInsets.all(8), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                AspectRatio(aspectRatio: 1, child: ClipRRect(
                  borderRadius: BorderRadius.circular(item.type == 'artist' || item.type == 'author' ? 100 : 4),
                  child: Stack(fit: StackFit.expand, children: [
                    _artwork(context, item),
                    if (widget.actionsBuilder != null && item.isSupported)
                      Align(alignment: Alignment.topRight, child: widget.actionsBuilder!(context, item)),
                  ]))),
                const SizedBox(height: 8),
                Text(item.isSupported ? item.name : 'Content is currently unavailable.', maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
                if (!compact) Text(_subtitle(item, state.page?.primaryFilter), maxLines: 1, overflow: TextOverflow.ellipsis, style: _secondary),
              ])),
          ))));
      },
      ));
    });
  }

  Widget _more(LibraryState state) => Center(child: state.isLoadingMore
    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
    : TextButton(onPressed: widget.controller.loadMore, child: const Text('Load more')));

  Widget _status(String text, {VoidCallback? retry}) => Center(child: Padding(
    padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      if (retry != null) Padding(padding: const EdgeInsets.only(top: 12),
        child: FilledButton(onPressed: retry, child: const Text('Try again'))),
    ])));

  Widget _artwork(BuildContext context, LibraryItem item) => item.type == 'folder'
    ? const ColoredBox(color: Color(0xff282828), child: Icon(Icons.folder_outlined, color: Color(0xffb3b3b3), size: 28))
    : widget.artworkBuilder?.call(context, item) ??
    Semantics(label: '${item.name} artwork unavailable', image: true,
      child: const ColoredBox(color: Color(0xff282828)));
}

String _subtitle(LibraryItem item, String? primaryFilter) {
  var type = const {'playlist': 'Playlist', 'album': 'Album', 'artist': 'Artist', 'show': 'Podcast',
    'audiobook': 'Audiobook', 'author': 'Author', 'folder': 'Folder', 'concert': 'Event',
    'venue': 'Venue', 'concert-campaign': 'Tour', 'pre-release-album': 'Upcoming album',
    'pre-release-book': 'Upcoming audiobook', 'local-files': 'Playlist', 'your-episodes': 'Playlist'}[item.type] ?? '';
  final albumType = item.data['albumType'];
  final specialAlbum = item.type == 'album' && albumType != null && albumType != 'album';
  if (specialAlbum) type = const {'ep': 'EP', 'single': 'Single', 'compilation': 'Compilation'}[albumType] ?? 'Album';
  final normalized = {'your-episodes', 'local-files', 'liked-songs'}.contains(item.type) ? 'playlist' : item.type;
  return [if (normalized != primaryFilter || specialAlbum) type, ...item.contributors]
      .where((value) => value.isNotEmpty).join(' • ');
}
String _viewName(LibraryItemsView view) => switch (view) {
  LibraryItemsView.compact => 'Compact list', LibraryItemsView.list => 'Default list',
  LibraryItemsView.grid => 'Default grid', LibraryItemsView.compactGrid => 'Compact grid',
};
const _secondary = TextStyle(fontSize: 14, color: Color(0xffb3b3b3));

double _labelWidth(BuildContext context, String text) {
  final painter = TextPainter(text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.copyWith(fontSize: 14)),
    textDirection: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context))..layout();
  final width = painter.width; painter.dispose(); return width;
}
