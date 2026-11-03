import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app/shell_icons.dart';
import '../app/desktop_icon_button.dart';
import 'controller.dart';
import 'models.dart';
import 'playlist_dates.dart';

typedef EntityArtworkBuilder = Widget Function(BuildContext context, EntityDetails entity);
typedef EntityRowArtworkBuilder = Widget Function(BuildContext context, EntityRow row);
typedef EntityRowActionsBuilder = Widget Function(BuildContext context, EntityRow row);

/// Selected album/playlist content. Image loading and playback belong to callers.
class EntityView extends StatefulWidget {
  const EntityView({super.key, required this.controller, this.onSelect, this.onPlay, this.onNavigate,
    this.artworkBuilder, this.rowArtworkBuilder, this.rowActionsBuilder,
    this.playingUri, this.isPlaying = false, this.onToggleShuffle, this.shuffle = false});
  final EntityController controller;
  final ValueChanged<EntityRow>? onSelect;
  final ValueChanged<EntityPlaybackSelection>? onPlay;
  final ValueChanged<EntityLink>? onNavigate;
  final EntityArtworkBuilder? artworkBuilder;
  final EntityRowArtworkBuilder? rowArtworkBuilder;
  final EntityRowActionsBuilder? rowActionsBuilder;
  /// Current item identity, retained while loading or paused independently of
  /// [isPlaying], which controls only the playing indicator.
  final String? playingUri;
  final bool isPlaying;
  final VoidCallback? onToggleShuffle;
  final bool shuffle;

  @override
  State<EntityView> createState() => _EntityViewState();
}

class _EntityViewState extends State<EntityView> {
  final _filterInput = TextEditingController();
  final _trackFocus = FocusNode(debugLabel: 'Entity tracks');
  final _trackListKey = GlobalKey();
  bool _revealScheduled = false;
  bool _showFilter = false;
  String _filter = '';
  int? _selectedRowIndex;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(EntityView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _filterInput.clear();
      _filter = '';
      _showFilter = false;
      _selectedRowIndex = null;
      unawaited(widget.controller.initialize());
    }
  }

  @override
  void dispose() {
    _filterInput.dispose();
    _trackFocus.dispose();
    super.dispose();
  }

  void _selectRow(int index, {bool reveal = false}) {
    _trackFocus.requestFocus();
    setState(() => _selectedRowIndex = index);
    widget.onSelect?.call(widget.controller.state.rows[index]);
    if (!reveal || _revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted) _revealSelectedRow();
    });
  }

  KeyEventResult _onTrackKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowUp && key != LogicalKeyboardKey.arrowDown) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isControlPressed ||
        keyboard.isMetaPressed || keyboard.isShiftPressed) { return KeyEventResult.ignored; }
    final focusedRow = FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<_EntityTrackRow>();
    if (!node.hasPrimaryFocus && focusedRow == null) { return KeyEventResult.ignored; }
    final rows = widget.controller.state.rows;
    final current = focusedRow == null ? _selectedRowIndex : rows.indexOf(focusedRow.row);
    final down = key == LogicalKeyboardKey.arrowDown;
    final candidates = [for (final (index, row) in rows.indexed)
      if (!row.isDisc && row.isSupported && _matches(row) &&
          (current == null || (down ? index > current : index < current))) index];
    if (candidates.isNotEmpty) {
      _selectRow(down ? candidates.first : candidates.last, reveal: true);
    }
    return KeyEventResult.handled;
  }

  void _revealSelectedRow() {
    final listContext = _trackListKey.currentContext;
    final sliver = listContext?.findRenderObject();
    if (listContext == null || sliver is! RenderSliverMultiBoxAdaptor) return;
    final position = Scrollable.of(listContext).position;
    if (!position.hasContentDimensions) return;
    final visible = [for (final (index, row) in widget.controller.state.rows.indexed)
      if (_matches(row)) index];
    final index = visible.indexOf(_selectedRowIndex ?? -1);
    if (index < 0) return;
    double? offset, extent;
    if (sliver is RenderSliverFixedExtentList) {
      offset = index * sliver.itemExtent;
      extent = sliver.itemExtent;
    } else {
      for (var child = sliver.firstChild; child != null; child = sliver.childAfter(child)) {
        if ((child.parentData as SliverMultiBoxAdaptorParentData).index != index) continue;
        offset = sliver.childScrollOffset(child);
        extent = child.size.height;
        break;
      }
    }
    if (offset == null || extent == null) return;
    final start = sliver.constraints.precedingScrollExtent + offset;
    final end = start + extent;
    final target = start < position.pixels ? start
      : end > position.pixels + position.viewportDimension ? end - position.viewportDimension
      : position.pixels;
    if (target != position.pixels) {
      position.jumpTo(target.clamp(position.minScrollExtent, position.maxScrollExtent));
    }
  }

  @override
  Widget build(BuildContext context) => Focus(focusNode: _trackFocus, skipTraversal: true,
    onKeyEvent: _onTrackKey, child: Material(color: const Color(0xff121212), child: ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final state = widget.controller.state;
      final entity = state.details;
      if (entity == null) {
        return state.phase == EntityPhase.failed
        ? _status('Couldn’t load this content', retry: widget.controller.refresh)
        : const Center(child: CircularProgressIndicator(color: Color(0xff1ed760)));
      }
      if (!entity.isAccessible) return _status('This content is unavailable.');
      if (entity.type == 'artist-section') return _artistSectionPage(entity, state);
      final visible = [for (final (index, row) in state.rows.indexed)
        if (_matches(row)) (index: index, row: row)];
      final rowHeight = _entityTrackRowHeight(MediaQuery.textScalerOf(context));
      final hasDiscHeaders = visible.any((item) => item.row.isDisc);
      Widget? trackSliver;
      ({double inset, bool artwork, bool album, bool date, bool plays})? trackLayout;
      Widget? header;
      ({double inset, int band, double bannerHeight})? headerLayout;
      Widget? content;
      int? contentBand;
      double? contentBannerHeight;
      return LayoutBuilder(builder: (context, constraints) => developer.Timeline.timeSync('ui.entity.layout', () {
        final width = constraints.maxWidth;
        final band = width < 420 ? 0 : width < 560 ? 1 : width < 600 ? 2
          : width < 640 ? 3 : width < 800 ? 4 : width < 900 ? 5 : 6;
        final banner = entity.headerImageUrl;
        final bannerHeight = banner == null ? 0.0 : (constraints.maxHeight * (width < 600 ? .35 : .5))
          .clamp(156.0, width < 600 ? 215.0 : width < 900 ? 284.0 : 374.0);
        // The viewport and text receive new constraints without new widgets.
        // Only responsive mode changes or the compact filter's explicit width
        // require another scroll-view/toolbar build. Data and selection changes
        // rebuild this enclosing listener and invalidate the cached tree.
        if (content != null && contentBand == band && contentBannerHeight == bannerHeight &&
            !(_showFilter && width < 640)) { return content!; }
        contentBand = band;
        contentBannerHeight = bannerHeight;
        final inset = width < 600 ? 16.0 : 24.0;
        final color = _entityColor(entity);
        final showAlbum = entity.type == 'playlist' && width >= 640;
        final showDate = entity.type == 'playlist' && width >= 900 &&
          entity.data['hasDateAdded'] != false;
        final showPlays = entity.type == 'album' && width >= 600;
        final nextLayout = (inset: inset, artwork: entity.type == 'playlist' && width >= 420,
          album: showAlbum, date: showDate, plays: showPlays);
        final nextHeaderLayout = (inset: inset, band: width < 560 ? 0 : width < 900 ? 1 : 2, bannerHeight: bannerHeight);
        // Resizing still relayouts text against the real available width.
        // Recreate the header's widgets only when its layout mode changes;
        // controller, selection and inherited-data rebuilds reset this cache.
        if (header == null || headerLayout != nextHeaderLayout) {
          headerLayout = nextHeaderLayout;
          header = SliverToBoxAdapter(child: RepaintBoundary(
            child: _header(context, entity, state, width, inset, color, bannerHeight)));
        }
        if (trackSliver == null || trackLayout != nextLayout) {
          trackLayout = nextLayout;
          Widget rowBuilder(BuildContext context, int index) => _row(context, entity,
            visible[index].row, visible[index].index, showArtwork: nextLayout.artwork || entity.type == 'artist',
            showAlbum: showAlbum, showDate: showDate, showPlays: showPlays);
          trackSliver = SliverPadding(padding: EdgeInsets.symmetric(horizontal: inset), sliver: hasDiscHeaders
            ? SliverList.builder(key: _trackListKey, itemCount: visible.length, itemBuilder: rowBuilder)
            : SliverFixedExtentList.builder(key: _trackListKey, itemExtent: rowHeight,
                itemCount: visible.length, itemBuilder: rowBuilder));
        }
        return content = CustomScrollView(key: PageStorageKey('entity:${state.uri}'),
          // Use the viewport's standard bounded cache. Several screens of
          // offscreen rows otherwise relayout on every window-width change.
          slivers: [
          header!,
          if (state.phase == EntityPhase.loading)
            const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2, color: Color(0xff1ed760))),
          SliverToBoxAdapter(child: Container(padding: EdgeInsets.symmetric(horizontal: inset),
            decoration: BoxDecoration(gradient: banner == null ? LinearGradient(begin: Alignment.topCenter,
              end: Alignment.bottomCenter, colors: [Color.lerp(color, Colors.black, 0.60)!, const Color(0xff121212)]) : null),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (banner != null) _playlistInfo(entity, state),
              _toolbar(context, entity, state, width),
              if (state.error != null) _error(state.phase == EntityPhase.failed
                ? 'Couldn’t refresh this content' : 'Couldn’t load more tracks',
                state.phase == EntityPhase.failed ? widget.controller.refresh : widget.controller.loadMore),
              if (entity.type == 'artist') Padding(padding: const EdgeInsets.only(bottom: 16),
                child: Text(entity.data['trackHeading'] as String? ?? 'Top tracks',
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)))
              else _columns(showAlbum: showAlbum, showDate: showDate, showPlays: showPlays),
              if (visible.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 40),
                child: Text(_filter.isEmpty ? 'There’s nothing to show right now.' : 'No matching tracks.',
                  textAlign: TextAlign.center, style: _secondary)),
            ]))),
          // Track rows have a known extent. Avoid laying out rows merely to
          // discover scroll offsets when rapidly moving through a playlist.
          // Disc headings keep their natural height in multi-disc albums.
          trackSliver!,
          SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(inset, 24, inset, 40), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (state.isLoadingMore) const Center(child: CircularProgressIndicator(color: Color(0xff1ed760)))
              else if (state.hasMore) Center(child: TextButton(onPressed: widget.controller.loadMore,
                child: const Text('Load more'))),
              if (entity.type == 'album') ..._copyright(entity),
              if (entity.type == 'artist') _artistSections(entity),
            ]))),
        ]);
      }, arguments: {'width': constraints.maxWidth, 'height': constraints.maxHeight,
        'cached': content != null, 'band': contentBand ?? -1}));
    },
  )));

  bool _matches(EntityRow row) {
    if (_filter.isEmpty) return true;
    if (row.isDisc) return false;
    return [row.name, ...row.artists.map((artist) => artist['name']),
      row.album?['name'], (row.data['show'] as Map?)?['name']]
      .whereType<String>().any((value) => value.toLowerCase().contains(_filter));
  }

  bool _isCurrent(EntityRow row) {
    final uri = widget.playingUri;
    return uri != null && uri.isNotEmpty && !row.isDisc &&
      (row.uri == uri || row.playbackUri == uri || row.data['relinkedUri'] == uri);
  }

  Widget _toolbar(BuildContext context, EntityDetails entity, EntityState state, double width) {
    final current = state.rows.where(_isCurrent).firstOrNull;
    return Padding(padding: EdgeInsets.only(top: entity.headerImageUrl == null ? 24 : 8, bottom: 24), child: Row(children: [
      DesktopIconButton(tooltip: 'Play ${entity.name}', size: 56, padding: EdgeInsets.zero,
        backgroundColor: widget.onPlay != null && entity.canRequestPlayback
          ? const Color(0xff1ed760) : const Color(0xff2a2a2a), color: Colors.black,
        onPressed: widget.onPlay != null && entity.canRequestPlayback
          ? () => widget.onPlay!(EntityPlaybackSelection(entity: entity, rows: state.rows)) : null,
        icon: const Icon(SpotifyShellIcons.play, size: 24)),
      if (current != null && widget.rowArtworkBuilder != null && width >= 640) ...[
        const SizedBox(width: 24),
        DecoratedBox(decoration: BoxDecoration(border: Border.all(color: const Color(0xffb3b3b3)),
          borderRadius: BorderRadius.circular(4)),
          child: Padding(padding: const EdgeInsets.all(2), child: SizedBox.square(dimension: 36,
            child: widget.rowArtworkBuilder!(context, current)))),
      ],
      if ((entity.type == 'album' || entity.type == 'playlist') &&
          (width >= 640 || width >= 420 && !_showFilter)) ...[
        const SizedBox(width: 16),
        DesktopIconButton(tooltip: widget.shuffle ? 'Disable shuffle' : 'Enable shuffle', size: 40,
          icon: const Icon(SpotifyShellIcons.shuffle, size: 28),
          color: widget.shuffle ? const Color(0xff1ed760) : const Color(0xffb3b3b3),
          onPressed: widget.onToggleShuffle),
        if (entity.data['isSaved'] is bool) ...[
          const SizedBox(width: 16),
          Tooltip(message: entity.data['isSaved'] == true ? 'Saved to Your Library' : 'Not saved to Your Library',
            child: Icon(entity.data['isSaved'] == true ? Icons.check_circle : Icons.add_circle_outline,
              color: entity.data['isSaved'] == true ? const Color(0xff1ed760) : const Color(0xffb3b3b3), size: 32)),
        ],
      ],
      const SizedBox(width: 16),
      PopupMenuButton<String>(tooltip: 'More options',
        onSelected: (_) => unawaited(widget.controller.refresh()),
        itemBuilder: (_) => [const PopupMenuItem(value: 'refresh', child: Text('Refresh'))],
        child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.more_horiz, size: 28))),
      const Spacer(),
      if (entity.type == 'album' && width >= 640) const Row(mainAxisSize: MainAxisSize.min, children: [
        Text('List', style: _secondary), SizedBox(width: 8),
        Icon(Icons.format_list_bulleted, size: 20, color: Color(0xffb3b3b3)),
      ]),
      if (entity.type == 'playlist') ...[
        if (_showFilter) SizedBox(width: width < 640 ? math.max(100.0, width - 200) : 200,
          child: TextField(controller: _filterInput, autofocus: true,
            onChanged: (value) => setState(() => _filter = value.toLowerCase()),
            style: const TextStyle(fontSize: 14), decoration: InputDecoration(
              isDense: true, hintText: state.hasMore ? 'Find in loaded tracks' : 'Find in playlist',
              border: InputBorder.none, prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: DesktopIconButton(tooltip: 'Close filter', icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() { _filterInput.clear(); _filter = ''; _showFilter = false; })))))
        else DesktopIconButton(tooltip: 'Find in playlist', icon: const Icon(Icons.search, size: 22),
          onPressed: () => setState(() => _showFilter = true)),
        if (width >= 800) Padding(padding: const EdgeInsets.only(left: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('Custom order', style: _secondary), const SizedBox(width: 8),
            const Icon(Icons.format_list_bulleted, size: 20, color: Color(0xffb3b3b3)),
          ])),
      ],
    ]));
  }

  Widget _header(BuildContext context, EntityDetails entity, EntityState state,
      double width, double inset, Color color, double bannerHeight) {
    if (entity.type == 'artist') return _artistHeader(entity, width, inset, color);
    final banner = entity.headerImageUrl;
    if (banner != null) {
      final artwork = EntityDetails.fromJson({...entity.data,
        'images': <EntityJson>[{'url': banner}], 'artworkRole': 'header-background'});
      return SizedBox(height: bannerHeight, child: Stack(fit: StackFit.expand, children: [
        widget.artworkBuilder?.call(context, artwork) ?? const ColoredBox(color: Color(0xff282828)),
        const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0x99000000)]))),
        Padding(padding: EdgeInsets.fromLTRB(inset, 24, inset, 24),
          child: Align(alignment: Alignment.bottomLeft, child: _EntityTitle(text: entity.name, compact: false))),
      ]));
    }
    final compact = width < 560;
    final size = compact ? 144.0 : width < 900 ? 192.0 : 232.0;
    final artwork = Container(width: size, height: size,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), boxShadow: const [
        BoxShadow(color: Color(0x55000000), blurRadius: 24, offset: Offset(0, 8)),
      ]), child: ClipRRect(borderRadius: BorderRadius.circular(4),
        child: widget.artworkBuilder?.call(context, entity) ?? Semantics(image: true,
          label: '${entity.name} artwork unavailable', child: const ColoredBox(color: Color(0xff282828)))));
    final release = (entity.data['release'] as Map?)?['isoString'] as String?;
    final createdValue = entity.type == 'playlist' ? entity.data['createdAt'] : null;
    final created = createdValue is String ? DateTime.tryParse(createdValue) : null;
    final total = entity.data['totalLength'] ?? entity.data['nrTracks'];
    final trackRows = state.rows.where((row) => !row.isDisc).toList();
    final completeDuration = total is int && trackRows.length == total &&
      trackRows.every((row) => row.isSupported && (row.durationMs ?? 0) > 0)
      ? trackRows.fold<int>(0, (sum, row) => sum + row.durationMs!) : null;
    final duration = entity.durationMs ?? completeDuration;
    final recipient = (entity.data['madeFor'] as Map?)?['displayName'] ?? (entity.data['madeFor'] as Map?)?['username'];
    final owner = recipient is String && recipient.isNotEmpty ? recipient : entity.contributors.join(', ');
    final artists = (entity.data['artists'] as List? ?? const []).cast<EntityJson>();
    final album = entity.type == 'track' ? (entity.data['album'] as Map?)?.cast<String, Object?>() : null;
    final albumName = album?['name'] as String? ?? '';
    const creatorStyle = TextStyle(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w700);
    final likes = entity.data['totalLikes'];
    final summary = [
      if (likes is num && likes >= 0) '${_number(likes.toInt())} saves',
      if (release != null && release.length >= 4) release.substring(0, 4),
      if (total is int) '$total ${entity.type == 'album' || entity.data['hasSpotifyTracks'] == true && entity.data['hasEpisodes'] == false
        ? total == 1 ? 'song' : 'songs' : total == 1 ? 'item' : 'items'}',
      if (duration != null && duration > 0) _totalDuration(duration),
    ].join(' • ');
    final title = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_typeLabel(entity), style: const TextStyle(fontSize: 14)),
      const SizedBox(height: 8),
      _EntityTitle(text: entity.name, compact: compact),
      if (entity.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text(entity.description, style: _secondary.copyWith(color: const Color(0xffb7cbd0)),
          maxLines: 2, overflow: TextOverflow.ellipsis)),
      const SizedBox(height: 16),
      Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
        if (owner.isNotEmpty) ...[
          ClipOval(child: SizedBox.square(dimension: 24,
            child: artists.isNotEmpty && (artists.first['images'] as List?)?.isNotEmpty == true && widget.artworkBuilder != null
                ? widget.artworkBuilder!(context, EntityDetails.fromJson(artists.first))
                : const ColoredBox(color: Color(0x55000000),
                  child: Icon(Icons.person, size: 13, color: Color(0xffd4d4d4))))),
          if (artists.isNotEmpty)
            for (final (index, artist) in artists.indexed)
              _EntityTextLink(text: '${artist['name']}${index < artists.length - 1 ? ',' : ''}',
                style: creatorStyle, link: EntityLink.fromJson(artist, type: 'artist'),
                onNavigate: widget.onNavigate)
          else Text.rich(TextSpan(children: [
            if (recipient is String && recipient.isNotEmpty) const TextSpan(text: 'Made for ', style: _secondary),
            TextSpan(text: owner, style: creatorStyle),
          ])),
          if (albumName.isNotEmpty || summary.isNotEmpty) const Text('•', style: _secondary),
        ],
        if (albumName.isNotEmpty) ...[
          _EntityTextLink(text: albumName, style: const TextStyle(fontSize: 14, color: Colors.white),
            link: EntityLink.fromJson(album!, type: 'album'), onNavigate: widget.onNavigate),
          if (summary.isNotEmpty) const Text('•', style: _secondary),
        ],
        if (summary.isNotEmpty) Text(summary, style: _secondary.copyWith(color: const Color(0xffb7cbd0))),
      ]),
      if (created != null && created.millisecondsSinceEpoch > 0) Padding(
        padding: const EdgeInsets.only(top: 8), child: Tooltip(message: 'Created ${created.toUtc().toIso8601String()}',
          child: Text('Created ${playlistAbsoluteDate(created)}', style: _secondary.copyWith(color: const Color(0xffb7cbd0))))),
    ]);
    return Container(padding: EdgeInsets.fromLTRB(inset, compact ? 24 : 68, inset, 24),
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [color, Color.lerp(color, Colors.black, 0.48)!])),
      child: compact ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: artwork), const SizedBox(height: 24), title,
      ]) : Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        artwork, const SizedBox(width: 24), Expanded(child: title),
      ]));
  }

  Widget _playlistInfo(EntityDetails entity, EntityState state) {
     final madeFor = entity.data['madeFor'] as Map?;
     final recipient = madeFor?['displayName'] ?? madeFor?['username'];
     final owner = entity.contributors.join(', ');
     final total = entity.data['totalLength'] ?? entity.data['nrTracks'];
     final rows = state.rows.where((row) => !row.isDisc).toList(growable: false);
     final duration = entity.durationMs ?? (total is int && rows.length == total &&
       rows.every((row) => row.isSupported && row.durationMs != null)
       ? rows.fold<int>(0, (sum, row) => sum + row.durationMs!) : null);
     final likes = entity.data['totalLikes'];
     final songs = entity.data['hasSpotifyTracks'] == true && entity.data['hasEpisodes'] == false;
     return Padding(padding: const EdgeInsets.only(top: 16, bottom: 8),
       child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
         if (entity.description.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8),
           child: Text(entity.description.replaceAll(RegExp(r'<[^>]*>'), ''), maxLines: 2,
             overflow: TextOverflow.ellipsis, style: _secondary)),
         Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
           if (recipient is String && recipient.isNotEmpty)
             Text.rich(TextSpan(children: [const TextSpan(text: 'Made for ', style: _secondary),
               TextSpan(text: recipient, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white))]),
               style: const TextStyle(fontSize: 14))
           else if (owner.isNotEmpty) ...[
             if ((entity.data['owner'] as Map?)?['username'] == 'spotify')
               const Icon(SpotifyShellIcons.brand, size: 20, color: Colors.white),
             Text(owner, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
           ],
           if (likes is num && likes > 0) Text('• ${_number(likes.toInt())} saves', style: _secondary),
           if (total is int) Text('• $total ${songs ? total == 1 ? 'song' : 'songs' : total == 1 ? 'item' : 'items'}'
             '${duration != null && duration > 0 ? ', ${_totalDuration(duration)}' : ''}', style: _secondary)
           else if (duration != null && duration > 0) Text('• ${_totalDuration(duration)}', style: _secondary),
         ]),
       ]));
  }

  Widget _artistHeader(EntityDetails entity, double width, double inset, Color color) {
    final stats = (entity.data['stats'] as Map?) ?? const {};
    final listeners = stats['monthlyListeners'];
    final size = width < 560 ? 128.0 : 192.0;
    return Container(padding: EdgeInsets.fromLTRB(inset, 40, inset, 24),
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [color, Color.lerp(color, Colors.black, 0.5)!])),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        SizedBox.square(dimension: size, child: ClipOval(child: widget.artworkBuilder?.call(context, entity) ??
          const ColoredBox(color: Color(0xff282828)))),
        const SizedBox(width: 24), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min, children: [
            const Text('Artist', style: TextStyle(fontSize: 14)), const SizedBox(height: 12),
            Text(entity.name, style: TextStyle(fontFamily: 'SpotifyMixUITitle',
              fontSize: width < 560 ? 32 : width < 900 ? 56 : 72, height: 1.1, fontWeight: FontWeight.w800)),
            if (listeners is num) Padding(padding: const EdgeInsets.only(top: 16),
              child: Text('${_number(listeners.toInt())} monthly listeners', style: const TextStyle(fontSize: 14))),
          ])),
      ]));
  }

  Widget _artistSections(EntityDetails entity) {
    final sections = (entity.data['artistSections'] as List? ?? []).cast<EntityJson>();
    final biography = entity.data['biography'] as String? ?? '';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final section in sections) Padding(padding: const EdgeInsets.only(top: 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Expanded(child: Text(section['title'] as String,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
            if (widget.onNavigate != null && section['seeAllUri'] is String)
              TextButton(onPressed: () => widget.onNavigate!(EntityLink(uri: section['seeAllUri'] as String,
                name: section['title'] as String, type: 'artist')), child: const Text('Show all'))]),
          const SizedBox(height: 16),
          SizedBox(height: 248 * MediaQuery.textScalerOf(context).scale(1).clamp(1, 2),
            child: ListView.separated(scrollDirection: Axis.horizontal,
              itemCount: (section['items'] as List).length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final data = (section['items'] as List)[index] as EntityJson;
                return SizedBox(width: 164, child: _artistCard(data));
              })),
        ])),
      if (biography.isNotEmpty) ...[
        const SizedBox(height: 32), const Text('About', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16), Text(biography.replaceAll(RegExp(r'<[^>]*>'), ''), style: _secondary),
      ],
    ]);
  }

  Widget _artistCard(EntityJson data) {
    final card = EntityDetails.fromJson(data), type = data['type'] as String? ?? '';
    final link = EntityLink.fromJson(data, type: type);
    return Material(color: const Color(0xff181818), borderRadius: BorderRadius.circular(6), clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: link != null && widget.onNavigate != null ? () => widget.onNavigate!(link) : null,
        child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(borderRadius: BorderRadius.circular(type == 'artist' ? 100 : 4),
            child: AspectRatio(aspectRatio: 1, child: widget.artworkBuilder?.call(context, card) ??
              const ColoredBox(color: Color(0xff282828)))),
          const SizedBox(height: 10), Text(card.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4), Text(data['subtitle'] as String? ?? '',
            maxLines: 2, overflow: TextOverflow.ellipsis, style: _secondary),
        ]))));
  }

  Widget _artistSectionPage(EntityDetails entity, EntityState state) => LayoutBuilder(builder: (context, bounds) {
    final inset = bounds.maxWidth < 600 ? 16.0 : 24.0;
    final columns = ((bounds.maxWidth - inset * 2 + 16) / 180).floor().clamp(1, 12);
    final width = (bounds.maxWidth - inset * 2 - (columns - 1) * 16) / columns;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return NotificationListener<ScrollNotification>(onNotification: (event) {
      if (event is ScrollUpdateNotification && event.metrics.axis == Axis.vertical && event.metrics.extentAfter < 256 &&
          state.hasMore && !state.isLoadingMore && state.error == null) { unawaited(widget.controller.loadMore()); }
      return false;
    }, child: CustomScrollView(key: PageStorageKey('artist-section:${entity.uri}'), slivers: [
      SliverPadding(padding: EdgeInsets.fromLTRB(inset, 24, inset, 24), sliver: SliverToBoxAdapter(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(entity.name, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
          if (entity.data['artistName'] is String && widget.onNavigate != null) TextButton(
            onPressed: () => widget.onNavigate!(EntityLink(uri: entity.data['artistUri'] as String,
              name: entity.data['artistName'] as String, type: 'artist')),
            child: Text(entity.data['artistName'] as String)),
          if (state.phase == EntityPhase.loading) const LinearProgressIndicator(minHeight: 2),
          if (state.error != null) _error('Couldn’t load this section', state.phase == EntityPhase.failed
            ? widget.controller.refresh : widget.controller.loadMore),
          if (state.rows.isEmpty && state.phase != EntityPhase.loading) const Text('There’s nothing to show right now.', style: _secondary),
        ]))),
      SliverPadding(padding: EdgeInsets.symmetric(horizontal: inset), sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
          crossAxisSpacing: 16, mainAxisSpacing: 16, mainAxisExtent: width + 92 * scale),
        itemCount: state.rows.length, itemBuilder: (context, index) => _artistCard(state.rows[index].data))),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(24), child: Center(child: state.isLoadingMore
        ? const CircularProgressIndicator() : state.hasMore
          ? TextButton(onPressed: widget.controller.loadMore, child: const Text('Load more')) : const SizedBox.shrink()))),
    ]));
  });

  double get _actionsWidth => widget.rowActionsBuilder == null ? 32 : 48;

  Widget _columns({required bool showAlbum, required bool showDate, required bool showPlays}) => Container(
    padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x33ffffff)))),
    child: Row(children: [
      const SizedBox(width: 32, child: Center(child: Text('#', style: _secondary))),
      const Expanded(flex: 6, child: Text('Title', style: _secondary)),
      if (showAlbum)
        const Expanded(flex: 3, child: Text('Album', style: _secondary)),
      if (showDate)
        const Expanded(flex: 3, child: Text('Date added', style: _secondary)),
      if (showPlays) const Expanded(flex: 3, child: Padding(padding: EdgeInsets.only(right: 24),
        child: Text('Plays', textAlign: TextAlign.right, style: _secondary))),
      if (showPlays) const SizedBox(width: 96),
      SizedBox(width: _actionsWidth),
      const SizedBox(width: 56, child: Align(alignment: Alignment.centerRight,
        child: Padding(padding: EdgeInsets.only(right: 2),
          child: Tooltip(message: 'Duration', child: Icon(Icons.schedule_outlined,
            size: 18, color: Color(0xffb3b3b3)))))),
    ]),
  );

  Widget _row(BuildContext context, EntityDetails entity, EntityRow row, int index,
      {required bool showArtwork, required bool showAlbum, required bool showDate, required bool showPlays}) {
    if (row.isDisc) {
      return Padding(padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
      child: Text('Disc ${row.discNumber}', style: _secondary.copyWith(fontSize: 16)));
    }
    if (!row.isSupported) {
      return SizedBox(height: _entityTrackRowHeight(MediaQuery.textScalerOf(context)), child: Row(children: [
        SizedBox(width: 40, child: Center(child: Text('${index + 1}', style: _secondary))),
        const Expanded(child: Text('This content is unavailable.', style: _secondary)),
      ]));
    }
    final canPlay = widget.onPlay != null && row.canRequestPlayback;
    final play = canPlay ? () => widget.onPlay!(EntityPlaybackSelection(entity: entity,
      row: row, rowIndex: index, rows: widget.controller.state.rows)) : null;
    return _EntityTrackRow(key: ValueKey('${row.uid ?? row.uri}:$index'), row: row,
      number: entity.type == 'album' && (row.trackNumber ?? 0) > 0 ? row.trackNumber! : index + 1,
      showArtwork: showArtwork,
      showAlbum: showAlbum, showDate: showDate, showPlays: showPlays, actionsWidth: _actionsWidth,
      current: _isCurrent(row),
      isPlaying: widget.isPlaying, selected: _selectedRowIndex == index,
      artworkBuilder: widget.rowArtworkBuilder, actionsBuilder: widget.rowActionsBuilder,
      onNavigate: widget.onNavigate == null ? null : (link) {
        _selectRow(index);
        widget.onNavigate!(link);
      }, onPlay: play, onSelect: () {
        _selectRow(index);
      });
  }

  Widget _error(String message, VoidCallback retry) => Padding(padding: const EdgeInsets.only(bottom: 12),
    child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 12, children: [
      Text(message, style: _secondary), TextButton(onPressed: retry, child: const Text('Try again')),
    ]));

  Widget _status(String message, {VoidCallback? retry}) => Center(child: Padding(padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
      if (retry != null) Padding(padding: const EdgeInsets.only(top: 16),
        child: FilledButton(onPressed: retry, child: const Text('Try again'))),
    ])));
}

class _EntityTrackRow extends StatefulWidget {
  const _EntityTrackRow({super.key, required this.row, required this.number,
    required this.showArtwork, required this.showAlbum, required this.showDate,
    required this.showPlays,
    required this.actionsWidth, required this.current, required this.isPlaying,
    required this.selected, required this.onSelect, this.onPlay, this.onNavigate,
    this.artworkBuilder, this.actionsBuilder});
  final EntityRow row;
  final int number;
  final bool showArtwork, showAlbum, showDate, showPlays, current, isPlaying, selected;
  final double actionsWidth;
  final VoidCallback onSelect;
  final VoidCallback? onPlay;
  final ValueChanged<EntityLink>? onNavigate;
  final EntityRowArtworkBuilder? artworkBuilder;
  final EntityRowActionsBuilder? actionsBuilder;

  @override
  State<_EntityTrackRow> createState() => _EntityTrackRowState();
}

class _EntityTrackRowState extends State<_EntityTrackRow> {
  bool _hovered = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final artists = row.artists.map((artist) => artist['name']).whereType<String>().join(', ');
    final showName = (row.data['show'] as Map?)?['name'] as String?;
    final active = _hovered || _focused;
    final height = _entityTrackRowHeight(MediaQuery.textScalerOf(context));
    final green = const Color(0xff1ed760);
    return Semantics(selected: widget.selected, child: FocusableActionDetector(
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
        widget.onSelect();
        return null;
      })},
      child: GestureDetector(behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect, onDoubleTap: widget.onPlay,
        child: DecoratedBox(decoration: BoxDecoration(
          color: widget.selected ? const Color(0xff333333)
            : active ? const Color(0xff2a2a2a) : Colors.transparent,
          borderRadius: BorderRadius.circular(4)),
        child: SizedBox(height: height, child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
            SizedBox(width: 32, child: active && widget.onPlay != null
              ? DesktopIconButton(tooltip: 'Play ${row.name}', padding: EdgeInsets.zero,
                  onPressed: widget.onPlay, color: Colors.white,
                  icon: const Icon(SpotifyShellIcons.play, size: 14))
              : Center(child: widget.current && widget.isPlaying
                  ? Icon(Icons.equalizer, color: green, size: 18)
                  : Text('${widget.number}', style: _secondary.copyWith(
                      color: widget.current ? green : const Color(0xffb3b3b3))))),
            Expanded(flex: 6, child: Row(children: [
              if (widget.showArtwork) Padding(padding: const EdgeInsets.only(right: 12),
                child: ClipRRect(borderRadius: BorderRadius.circular(4),
                  child: SizedBox.square(dimension: 40,
                    child: widget.artworkBuilder?.call(context, row)
                      ?? const ColoredBox(color: Color(0xff282828))))),
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _EntityTextLink(text: row.name,
                    link: row.type == 'track' ? EntityLink.fromJson(row.data, type: 'track') : null,
                    onNavigate: widget.onNavigate, onDoubleTap: widget.onPlay,
                    hoverColor: widget.current ? green : Colors.white,
                    style: TextStyle(fontSize: 16, height: 1.2,
                      color: widget.current ? green : row.canRequestPlayback
                        ? Colors.white : const Color(0xffb3b3b3))),
                  if (artists.isNotEmpty || showName != null || row.isExplicit) ...[
                    const SizedBox(height: 2),
                    Row(children: [
                      if (row.isExplicit) Padding(padding: const EdgeInsets.only(right: 6),
                        child: Container(padding: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(color: const Color(0xffb3b3b3),
                            borderRadius: BorderRadius.circular(2)),
                          child: const Text('E', semanticsLabel: 'Explicit',
                            style: TextStyle(color: Color(0xff121212), fontSize: 10, height: 1.3,
                              fontWeight: FontWeight.w700)))),
                      Expanded(child: artists.isNotEmpty
                        ? _EntityArtistLinks(artists: row.artists, onNavigate: widget.onNavigate)
                        : Text(showName ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: _secondary.copyWith(height: 1.2))),
                    ]),
                  ],
                ])),
              const SizedBox(width: 12),
            ])),
            if (widget.showAlbum) Expanded(flex: 3, child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: _EntityTextLink(text: row.album?['name'] as String? ?? '',
                link: row.album == null ? null : EntityLink.fromJson(row.album!, type: 'album'),
                onNavigate: widget.onNavigate, style: _secondary))),
            if (widget.showDate) Expanded(flex: 3, child: Text(playlistDateAddedLabel(row.data['addedAt'], now: DateTime.now()),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: _secondary)),
            if (widget.showPlays) Expanded(flex: 3, child: Padding(padding: const EdgeInsets.only(right: 24),
              child: Text(_playCount(row.data['playcount']), textAlign: TextAlign.right, style: _secondary))),
            if (widget.showPlays) const SizedBox(width: 96),
            SizedBox(width: widget.actionsWidth, child: widget.actionsBuilder?.call(context, row)
              ?? (row.data['isSaved'] == true ? Icon(Icons.check_circle, color: green, size: 16) : null)),
            SizedBox(width: 56, child: Text(row.durationMs == null ? '' : _trackDuration(row.durationMs!),
              textAlign: TextAlign.right, style: _secondary)),
          ])))))));
  }
}

/// Original header scales down to a single line, then wraps at its minimum.
/// Measuring inside layout also handles sidebar drags without stale font sizes.
class _EntityTitle extends StatelessWidget {
  const _EntityTitle({required this.text, required this.compact});
  final String text;
  final bool compact;

  @override Widget build(BuildContext context) => LayoutBuilder(builder: (context, bounds) {
    final scaler = MediaQuery.textScalerOf(context), direction = Directionality.of(context);
    var size = compact ? 24.0 : 32.0;
    for (final candidate in compact ? const [32.0, 24.0] : const [96.0, 72.0, 48.0, 32.0]) {
      final painter = TextPainter(text: TextSpan(text: text, style: TextStyle(
        fontFamily: 'SpotifyMixUITitle', fontSize: candidate, fontWeight: FontWeight.w800, height: 1.2)),
        textDirection: direction, textScaler: scaler, maxLines: 1)..layout();
      final fits = painter.width <= bounds.maxWidth;
      painter.dispose();
      size = candidate;
      if (fits) break;
    }
    return Text(text, maxLines: compact ? 2 : 3, overflow: TextOverflow.ellipsis,
      style: TextStyle(fontFamily: 'SpotifyMixUITitle', fontSize: size,
        fontWeight: FontWeight.w800, height: 1.2, color: Colors.white));
  });
}

class _EntityTextLink extends StatefulWidget {
  const _EntityTextLink({required this.text, required this.style, this.link,
    this.onNavigate, this.onDoubleTap, this.hoverColor = Colors.white});
  final String text;
  final TextStyle style;
  final EntityLink? link;
  final ValueChanged<EntityLink>? onNavigate;
  final VoidCallback? onDoubleTap;
  final Color hoverColor;

  @override
  State<_EntityTextLink> createState() => _EntityTextLinkState();
}

class _EntityTextLinkState extends State<_EntityTextLink> {
  bool _hovered = false, _focused = false;
  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final enabled = link != null && widget.onNavigate != null;
    final active = enabled && (_hovered || _focused);
    final text = Text(widget.text, maxLines: 1, overflow: TextOverflow.ellipsis,
      style: widget.style.copyWith(color: active ? widget.hoverColor : widget.style.color,
        decoration: active ? TextDecoration.underline : TextDecoration.none));
    if (!enabled) return text;
    // Text links need hover/focus and activation, without a separate material
    // ink animation subtree for every title and album cell in every row.
    return Semantics(link: true, child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
        widget.onNavigate!(link);
        return null;
      })},
      child: GestureDetector(behavior: HitTestBehavior.opaque,
        onTap: () => widget.onNavigate!(link), onDoubleTap: widget.onDoubleTap,
        child: text)));
  }
}

/// Inline spans retain one ellipsized line while each supplied artist URI has
/// its own hover/click target; recognizers belong to the mounted row.
class _EntityArtistLinks extends StatefulWidget {
  const _EntityArtistLinks({required this.artists, this.onNavigate});
  final List<EntityJson> artists;
  final ValueChanged<EntityLink>? onNavigate;
  @override
  State<_EntityArtistLinks> createState() => _EntityArtistLinksState();
}

class _EntityArtistLinksState extends State<_EntityArtistLinks> {
  final _recognizers = <int, TapGestureRecognizer>{};
  int? _hovered;
  @override
  void dispose() {
    for (final recognizer in _recognizers.values) { recognizer.dispose(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final artists = widget.artists.where((artist) => artist['name'] is String &&
      (artist['name'] as String).isNotEmpty).toList(growable: false);
    return Text.rich(TextSpan(children: [for (final (index, artist) in artists.indexed) ...[
      if (index != 0) const TextSpan(text: ', '),
      _artist(artist, index),
    ]]), maxLines: 1, overflow: TextOverflow.ellipsis, style: _secondary.copyWith(height: 1.2));
  }

  TextSpan _artist(EntityJson artist, int index) {
    final link = EntityLink.fromJson(artist, type: 'artist');
    final enabled = link != null && widget.onNavigate != null;
    final recognizer = _recognizers.putIfAbsent(index, () => TapGestureRecognizer());
    recognizer.onTap = enabled ? () => widget.onNavigate!(link) : null;
    return TextSpan(text: artist['name'] as String, recognizer: enabled ? recognizer : null,
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: enabled ? (_) { if (mounted) setState(() => _hovered = index); } : null,
      onExit: enabled ? (_) { if (mounted && _hovered == index) setState(() => _hovered = null); } : null,
      style: _hovered == index && enabled
        ? const TextStyle(color: Colors.white, decoration: TextDecoration.underline) : null);
  }
}

double _entityTrackRowHeight(TextScaler scaler) =>
  math.max(56.0, 18 + scaler.scale(16) * 1.2 + scaler.scale(14) * 1.2);

String _typeLabel(EntityDetails entity) => entity.type == 'track' ? 'Song'
  : entity.type == 'artist' ? 'Artist' : entity.type == 'playlist'
  ? entity.data['isPublished'] == true ? 'Public Playlist'
    : ((entity.data['permissions'] as Map?)?['isPrivate'] == true) ? 'Private Playlist' : 'Playlist'
  : switch (entity.data['albumType']) {
  'SINGLE' => 'Single', 'EP' => 'EP', 'COMPILATION' => 'Compilation', _ => 'Album',
};
String _trackDuration(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
String _totalDuration(num ms) => ms < 3600000 ? '${ms ~/ 60000} min' : '${ms ~/ 3600000} hr ${ms ~/ 60000 % 60} min';
String _number(int value) => '$value'.replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (match) => '${match[1]},');
String _playCount(Object? value) {
  final count = value is int ? value : int.tryParse('$value');
  return count == null || count < 0 ? '' : _number(count);
}

Color _entityColor(EntityDetails entity) {
  final dynamicColors = entity.data['dynamicColors'];
  final extracted = entity.data['extractedColors'];
  final values = [
    if (dynamicColors is Map) ...[dynamicColors['backgroundBase'], dynamicColors['backgroundTinted']],
    if (extracted is Map) ...[extracted['colorDark'], extracted['colorRaw']],
    entity.data['color'],
  ];
  for (var value in values) {
    if (value is Map) value = value['hex'];
    if (value is int) return Color(value <= 0xffffff ? value | 0xff000000 : value);
    if (value is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
      return Color(int.parse(value.substring(1), radix: 16) | 0xff000000);
    }
  }
  // A cohesive fallback only; never claim it was extracted from an image.
  return const Color(0xff2d6473);
}
List<Widget> _copyright(EntityDetails entity) => [for (final entry in ((entity.data['copyright'] as Map?)?['items'] as List? ?? []))
  Text((entry as Map)['text'] as String? ?? '', style: _secondary.copyWith(fontSize: 11))];
const _secondary = TextStyle(fontSize: 14, color: Color(0xffb3b3b3));
