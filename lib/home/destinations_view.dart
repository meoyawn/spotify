import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/share_links.dart';
import 'controller.dart';
import 'destinations_controller.dart';
import 'models.dart';
import 'view.dart';

/// Lazily rendered Home drilldowns and Browse pages; paging follows demand.
class HomeDestinationView extends StatefulWidget {
  const HomeDestinationView({super.key, required this.controller,
    required this.onSelect, required this.onOpenSection, this.artworkBuilder});
  final HomeDestinationController controller;
  final ValueChanged<HomeItem> onSelect;
  final ValueChanged<HomeSection> onOpenSection;
  final HomeArtworkBuilder? artworkBuilder;

  @override
  State<HomeDestinationView> createState() => _HomeDestinationViewState();
}

class _HomeDestinationViewState extends State<HomeDestinationView> {
  @override
  void initState() { super.initState(); unawaited(widget.controller.initialize()); }

  @override
  void didUpdateWidget(HomeDestinationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) unawaited(widget.controller.initialize());
  }

  @override
  Widget build(BuildContext context) => Material(color: const Color(0xff121212),
    child: ListenableBuilder(listenable: widget.controller, builder: (context, _) {
      final state = widget.controller.state, page = state.page;
      if (page == null) {
        if (state.phase == HomePhase.failed) return _status('Couldn’t load this page', widget.controller.refresh);
        return const Center(child: CircularProgressIndicator(color: Color(0xff1ed760)));
      }
      return LayoutBuilder(builder: (context, constraints) {
        final inset = constraints.maxWidth < 600 ? 16.0 : 40.0;
        final width = math.max(1.0, constraints.maxWidth - inset * 2);
        final headerColor = _color(page.color);
        final slivers = <Widget>[
          if (state.phase == HomePhase.loading)
            const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2, color: Color(0xff1ed760))),
          if (state.phase == HomePhase.failed)
            SliverToBoxAdapter(child: _status('Couldn’t refresh this page', widget.controller.refresh)),
          if (page.title.isNotEmpty)
            SliverToBoxAdapter(child: Container(
              padding: EdgeInsets.fromLTRB(inset, 32, inset, 24),
              decoration: BoxDecoration(gradient: headerColor != null
                ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [headerColor, headerColor.withValues(alpha: .15)]) : null),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(page.title, style: _title.copyWith(fontSize: page.fullPage ? 32 : 48)),
                if (page.subtitle.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
                  child: Text(page.subtitle, style: _secondary)),
              ]))),
        ];
        for (final section in page.sections) {
          if (section.kind == HomeSectionKind.unsupported) {
            slivers.add(SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(inset),
              child: const Text('Content is currently unavailable.', style: _secondary))));
            continue;
          }
          final grid = page.fullPage || section.sourceType == 'BrowseGridSectionData';
          if (section.title.isNotEmpty && (!page.fullPage || section.title != page.title)) {
            slivers.add(SliverToBoxAdapter(child: Padding(
              padding: EdgeInsets.fromLTRB(inset, 20, inset, 8), child: Row(children: [
                Expanded(child: Text(section.title, style: _title)),
                if (!page.fullPage && section.seeAllUri != null)
                  TextButton(onPressed: () => widget.onOpenSection(section), child: const Text('Show all')),
              ]))));
          }
          if (grid) {
            final hubs = section.items.isNotEmpty && section.items.every((item) => item.type == 'browse');
            // Original module54461 BROWSE and HOME_REGULAR_DENSITY widths.
            final minimum = hubs ? width < 520 ? 180 : width < 1280 ? 254 : 300
              : width < 1200 ? 160 : 210;
            final columns = math.max(1, (width / minimum).floor());
            final cardWidth = width / columns;
            slivers.add(SliverPadding(padding: EdgeInsets.symmetric(horizontal: inset), sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns,
                mainAxisExtent: hubs ? (cardWidth - 16) * .5625 + 16
                  : cardWidth + 88 * MediaQuery.textScalerOf(context).scale(1)),
              delegate: SliverChildBuilderDelegate((context, index) => _card(context, section.items[index],
                compact: width <= 520),
                childCount: section.items.length))));
          } else {
            slivers.add(SliverToBoxAdapter(child: SizedBox(height: 252 * MediaQuery.textScalerOf(context).scale(1),
              child: ListView.builder(scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: inset), itemExtent: 170,
                itemCount: section.items.length,
                itemBuilder: (context, index) => _card(context, section.items[index])))));
          }
        }
        if (page.sections.every((section) => section.items.isEmpty)) {
          slivers.add(const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(40),
            child: Text('There’s nothing to show right now.', style: _secondary))));
        }
        if (page.nextOffset != null) {
          slivers.add(SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(24),
            child: Center(child: state.loadingMore
              ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton(onPressed: widget.controller.loadMore,
                  child: Text(state.moreError == null ? 'Show more' : 'Couldn’t load more. Try again'))))));
        }
        slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 40)));
        return NotificationListener<ScrollNotification>(onNotification: (notification) {
          if (notification.depth == 0 && notification.metrics.axis == Axis.vertical &&
              notification.metrics.extentAfter < 320 && state.moreError == null) {
            unawaited(widget.controller.loadMore());
          }
          return false;
        }, child: CustomScrollView(key: PageStorageKey('home-destination:${widget.controller.target.key}'),
          slivers: slivers));
      });
    }));

  Widget _card(BuildContext context, HomeItem item, {bool compact = false}) {
    final artwork = widget.artworkBuilder?.call(context, item) ?? const ColoredBox(color: Color(0xff282828));
    if (item.type == 'browse') {
      final content = item.source['content'];
      final data = content is Map ? content['data'] : null;
      final details = data is Map ? data['data'] : null;
      final representation = data is Map && data['__typename'] == 'BrowseClientFeature'
        ? data : details is Map ? details['cardRepresentation'] : null;
      final background = representation is Map ? representation['backgroundColor'] : null;
      final color = background is Map ? _color(background['hex'] as String?) : null;
      return Padding(padding: const EdgeInsets.all(8), child: Material(
        color: color ?? const Color(0xff282828), borderRadius: BorderRadius.circular(8), clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: () => widget.onSelect(item), child: LayoutBuilder(builder: (context, box) {
          final imageWidth = box.maxWidth * .45;
          return Stack(children: [
            Positioned(right: 0, bottom: 0, width: imageWidth, height: imageWidth,
              child: Transform.rotate(angle: math.pi * 25 / 180,
                child: Transform.translate(offset: Offset(imageWidth * .18, -imageWidth * .02), child: artwork))),
            Padding(padding: EdgeInsets.fromLTRB(16, 16, box.maxWidth * .3, 0),
              child: Text(item.name, maxLines: 3, overflow: TextOverflow.ellipsis,
                style: compact ? const TextStyle(fontSize: 14, fontWeight: FontWeight.w700) : _title)),
          ]);
        }))));
    }
    return SpotifyLinkContextMenu(uri: item.uri,
      child: Material(color: Colors.transparent, borderRadius: BorderRadius.circular(8), clipBehavior: Clip.antiAlias,
      child: Semantics(label: item.showTitle ? null : item.name,
        child: InkWell(onTap: () => widget.onSelect(item), child: Padding(padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(aspectRatio: 1, child: ClipRRect(
            borderRadius: BorderRadius.circular(item.type == 'artist' || item.type == 'user' ? 1000 : 6), child: artwork)),
          const SizedBox(height: 8),
          if (item.showTitle) Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16)),
          if (item.cardSubtitle.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(item.cardSubtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: _secondary)),
        ]))))));
  }

  Widget _status(String title, VoidCallback retry) => Center(child: Padding(padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(title, style: _title), const SizedBox(height: 12),
      TextButton(onPressed: retry, child: const Text('Try again')),
    ])));
}

Color? _color(String? hex) {
  final value = hex?.replaceFirst('#', '');
  if (value == null || !RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)) return null;
  return Color(0xff000000 | int.parse(value, radix: 16));
}

const _title = TextStyle(fontFamily: 'SpotifyMixUITitle', fontSize: 24, fontWeight: FontWeight.w700);
const _secondary = TextStyle(color: Color(0xffb3b3b3), fontSize: 14);
