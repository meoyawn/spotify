import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'models.dart';
import '../app/song_links.dart';

typedef SearchArtworkBuilder = Widget Function(BuildContext context, SearchItem item);

/// The global field's suggestions stay anchored above the existing page.
/// This consumes the existing original suggestions owner and fetches no images.
class SearchSuggestionsDropdown extends StatefulWidget {
  const SearchSuggestionsDropdown({super.key, required this.controller,
    required this.onSelect, required this.onViewAllResults,
    this.artworkBuilder, this.maxHeight = 420});
  final DesktopSearchController controller;
  final ValueChanged<SearchItem> onSelect;
  final ValueChanged<String> onViewAllResults;
  final SearchArtworkBuilder? artworkBuilder;
  final double maxHeight;

  @override
  State<SearchSuggestionsDropdown> createState() => _SearchSuggestionsDropdownState();
}

class _SearchSuggestionsDropdownState extends State<SearchSuggestionsDropdown> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(SearchSuggestionsDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  static double _rowHeight(SearchItem item) => item.type == 'autocomplete' ? 60 : 68;

  void _changed() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final state = widget.controller.state, index = widget.controller.state.selectedIndex;
      if (index < 0 || index >= state.items.length) return;
      final top = state.items.take(index).fold<double>(0, (total, item) => total + _rowHeight(item));
      final bottom = top + _rowHeight(state.items[index]);
      final view = _scroll.position.viewportDimension, offset = _scroll.offset;
      final target = top < offset ? top : bottom > offset + view ? bottom - view : offset;
      _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller.state;
      final footer = !state.isRecent;
      final rowsHeight = state.items.fold<double>(0, (total, item) => total + _rowHeight(item));
      final contentHeight = state.items.isEmpty ? 80.0 : rowsHeight + (footer ? 44 : 0);
      return Material(color: const Color(0xff282828), elevation: 16,
        shadowColor: Colors.black54, borderRadius: BorderRadius.circular(4),
        clipBehavior: Clip.antiAlias, child: SizedBox(
          height: math.min(widget.maxHeight, contentHeight + 36),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4), child: Row(children: [
              if (state.isRecent) ...[
                const Text('Recent searches', style: TextStyle(color: Color(0xffb3b3b3), fontSize: 12)),
                const Spacer(),
                if (state.items.isNotEmpty) TextButton(onPressed: widget.controller.isUpdatingHistory ? null
                  : () => unawaited(widget.controller.removeRecent()),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: const Text('Clear all', style: TextStyle(color: Color(0xffb3b3b3), fontSize: 12))),
              ]
              else ...[
                const _SearchKeycap('↑'), const SizedBox(width: 4), const _SearchKeycap('↓'),
                const SizedBox(width: 8), const Text('Navigate',
                  style: TextStyle(color: Color(0xffb3b3b3), fontSize: 12)),
                const Spacer(), const _SearchKeycap('Enter'), const SizedBox(width: 8),
                const Text('Search', style: TextStyle(color: Color(0xffb3b3b3), fontSize: 12)),
              ],
            ])),
            if (state.phase == SearchPhase.loading && state.items.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2, color: Color(0xffb3b3b3)),
            Expanded(child: state.items.isEmpty ? _empty(state) : ListView.builder(
              controller: _scroll, padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              itemCount: state.items.length + (footer ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == state.items.length) {
                  return TextButton(onPressed: () => widget.onViewAllResults(state.query),
                    style: TextButton.styleFrom(foregroundColor: Colors.white,
                      minimumSize: const Size(48, 44)),
                    child: Text('View all results for “${state.query}”', maxLines: 1,
                      overflow: TextOverflow.ellipsis));
                }
                final item = state.items[index], autocomplete = state.items[index].type == 'autocomplete';
                return SongLinkContextMenu(uri: item.uri, child: Semantics(selected: state.selectedIndex == index, child: Material(
                  color: state.selectedIndex == index ? const Color(0xff3e3e3e) : Colors.transparent,
                  borderRadius: BorderRadius.circular(4), child: InkWell(
                    canRequestFocus: false, borderRadius: BorderRadius.circular(4),
                    hoverColor: const Color(0xff3e3e3e), onTap: () => widget.onSelect(item),
                    child: SizedBox(height: _rowHeight(item), child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
                        SizedBox.square(dimension: 48, child: autocomplete
                          ? const Icon(Icons.search, size: 28, color: Color(0xffb3b3b3))
                          : ClipRRect(borderRadius: BorderRadius.circular(
                              const {'artist', 'author', 'user'}.contains(item.type) ? 24 : 4),
                            child: widget.artworkBuilder?.call(context, item) ?? _placeholder(item))),
                        const SizedBox(width: 12),
                        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.white, fontSize: 16,
                                fontWeight: autocomplete && item.name == state.query ? FontWeight.w700 : FontWeight.w400)),
                            if (!autocomplete) ...[
                              const SizedBox(height: 4),
                              Text([_typeLabel(item.type), ...item.contributors]
                                .where((text) => text.isNotEmpty).join(' • '), maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 14)),
                            ],
                          ])),
                        if (state.isRecent) IconButton(tooltip: 'Remove ${item.name} from recent searches',
                          onPressed: widget.controller.isUpdatingHistory ? null
                            : () => unawaited(widget.controller.removeRecent(item.uri)),
                          icon: const Icon(Icons.close, size: 18, color: Color(0xffb3b3b3))),
                      ])))))));
              })),
          ])));
    });

  Widget _empty(SearchState state) {
    if (state.phase == SearchPhase.loading) {
      return const Center(child: SizedBox.square(dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xffb3b3b3))));
    }
    return Center(child: Padding(padding: const EdgeInsets.all(12), child: Text(
      state.phase == SearchPhase.failed ? 'Couldn’t load suggestions. Try again.'
        : state.isRecent ? 'Your recent searches will appear here.' : 'No results found.',
      style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 14), textAlign: TextAlign.center)));
  }
}

class _SearchKeycap extends StatelessWidget {
  const _SearchKeycap(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(border: Border.all(color: const Color(0xff8b8b8b)),
      borderRadius: BorderRadius.circular(3)),
    child: Text(label, style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 11)));
}

/// Search input and suggestions for a bounded desktop or narrow content area.
/// Artwork is supplied by the caller; the default never fetches image URLs.
class SearchView extends StatefulWidget {
  const SearchView({
    super.key,
    required this.controller,
    required this.onSelect,
    this.onViewAllResults,
    this.artworkBuilder,
    this.showInput = true,
  });

  final DesktopSearchController controller;
  final ValueChanged<SearchItem> onSelect;
  final ValueChanged<String>? onViewAllResults;
  final SearchArtworkBuilder? artworkBuilder;
  final bool showInput;

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  late final TextEditingController _input;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.controller.state.query);
    widget.controller.addListener(_syncInput);
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(SearchView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncInput);
      widget.controller.addListener(_syncInput);
      _syncInput();
      unawaited(widget.controller.initialize());
    }
  }

  void _syncInput() {
    final query = widget.controller.state.query;
    if (_input.text != query) {
      _input.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    if (!widget.showInput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _revealSelection();
      });
    }
  }

  void _revealSelection() {
    if (!_scroll.hasClients || widget.controller.state.selectedIndex < 0) return;
    final top = widget.controller.state.selectedIndex * 72.0;
    final viewport = _scroll.position.viewportDimension;
    final offset = _scroll.offset;
    final target = top < offset ? top : top + 72 > offset + viewport
        ? top + 72 - viewport : offset;
    _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
  }

  void _activate() {
    final state = widget.controller.state;
    final selected = state.selectedItem;
    if (selected != null) {
      widget.onSelect(selected);
    } else if (state.query.isNotEmpty) {
      widget.onViewAllResults?.call(state.query);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    widget.controller.moveSelection(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
    _revealSelection();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncInput);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => LayoutBuilder(builder: (context, constraints) {
      final state = widget.controller.state;
      return Material(
        color: const Color(0xff121212),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.all(constraints.maxWidth < 480 ? 12 : 24),
          child: Focus(
            onKeyEvent: _onKey,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (widget.showInput) SizedBox(
                height: 48,
                child: TextField(
                  controller: _input,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  cursorColor: Colors.white,
                  onChanged: widget.controller.setQuery,
                  onSubmitted: (_) => _activate(),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'What do you want to play?',
                    hintStyle: const TextStyle(color: Color(0xffb3b3b3), fontSize: 16),
                    filled: true,
                    fillColor: const Color(0xff1f1f1f),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    prefixIcon: const Icon(Icons.search, color: Color(0xffb3b3b3)),
                    suffixIcon: state.query.isEmpty ? null : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () => widget.controller.setQuery(''),
                      icon: const Icon(Icons.close, color: Color(0xffb3b3b3)),
                    ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(500), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(500), borderSide: const BorderSide(color: Colors.white, width: 2)),
                  ),
                ),
              ),
              if (widget.showInput) const SizedBox(height: 20),
              Row(children: [
                Expanded(child: Text(
                  state.isRecent ? 'Recent searches' : 'Search results',
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                )),
                if (constraints.maxWidth >= 540)
                  const Text('↑ ↓ Navigate', style: TextStyle(color: Color(0xffb3b3b3), fontSize: 12)),
              ]),
              const SizedBox(height: 12),
              if (state.phase == SearchPhase.loading && state.items.isNotEmpty)
                const LinearProgressIndicator(minHeight: 2, color: Color(0xff1ed760)),
              Expanded(child: _content(state, constraints.maxWidth)),
              if (!state.isRecent && widget.onViewAllResults != null)
                TextButton(
                  onPressed: () => widget.onViewAllResults!(state.query),
                  style: TextButton.styleFrom(foregroundColor: Colors.white, minimumSize: const Size(48, 48)),
                  child: Text('View all results for “${state.query}”', textAlign: TextAlign.center),
                ),
            ]),
          ),
        ),
      );
    }),
  );

  Widget _content(SearchState state, double width) {
    if (state.phase == SearchPhase.failed) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Something went wrong. Try searching again.',
          textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: widget.controller.refresh,
          child: const Text('Try again', style: TextStyle(color: Colors.white))),
      ]));
    }
    if (state.phase == SearchPhase.loading && state.items.isEmpty) {
      return Center(child: Semantics(label: 'Searching',
        child: const CircularProgressIndicator(color: Color(0xff1ed760))));
    }
    if (state.items.isEmpty) {
      return Center(child: Text(
        state.isRecent ? 'Your recent searches will appear here.'
            : 'No results found for “${state.query}”',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ));
    }
    return ListView.builder(
      controller: _scroll,
      itemExtent: 72,
      itemCount: state.items.length,
      itemBuilder: (context, index) {
        final item = state.items[index];
        final label = _typeLabel(item.type);
        return SongLinkContextMenu(uri: item.uri, child: Semantics(
          selected: state.selectedIndex == index,
          child: Material(
            color: state.selectedIndex == index ? const Color(0xff282828) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              onTap: () => widget.onSelect(item),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                child: Row(children: [
                  SizedBox(width: 48, height: 48,
                    child: widget.artworkBuilder?.call(context, item) ?? _placeholder(item)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center, children: [
                      Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 16)),
                      const SizedBox(height: 4),
                      Row(children: [
                        if (item.isExplicit) const Padding(
                          padding: EdgeInsets.only(right: 5),
                          child: Text('E', semanticsLabel: 'Explicit',
                            style: TextStyle(color: Color(0xffb3b3b3), fontSize: 11, fontWeight: FontWeight.w700)),
                        ),
                        Expanded(child: Text(
                          [label, ...item.contributors].where((text) => text.isNotEmpty).join(' • '),
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 14),
                        )),
                      ]),
                    ])),
                  if (item.type == 'track') SongLinkMenu(uri: item.uri, name: item.name),
                  if (width >= 420 && item.durationMs != null)
                    Padding(padding: const EdgeInsets.only(left: 12), child: Text(
                      _duration(item.durationMs!),
                      style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 14),
                    )),
                ]),
              ),
            ),
          ),
        ));
      },
    );
  }
}

String _duration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _typeLabel(String type) => switch (type) {
  'track' => 'Song', 'artist' => 'Artist', 'album' => 'Album',
  'playlist' => 'Playlist', 'show' => 'Podcast', 'episode' => 'Episode',
  'audiobook' => 'Audiobook', 'author' => 'Author', 'user' => 'Profile',
  'genre' => 'Genre', 'liked-songs' => 'Playlist',
  'pre-release-album' => 'Upcoming release', 'autocomplete' => 'Search',
  _ => '',
};

Widget _placeholder(SearchItem item) => DecoratedBox(
  decoration: BoxDecoration(
    color: const Color(0xff282828),
    borderRadius: BorderRadius.circular(
      const ['artist', 'author', 'user'].contains(item.type) ? 24 : 4),
  ),
  child: Icon(switch (item.type) {
    'artist' || 'author' || 'user' => Icons.person_outline,
    'show' || 'episode' => Icons.podcasts,
    'audiobook' => Icons.menu_book,
    'autocomplete' => Icons.search,
    _ => Icons.music_note,
  }, color: const Color(0xffb3b3b3), size: 24),
);
