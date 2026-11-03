import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../content/advertising.dart';

import 'controller.dart';
import 'models.dart';

typedef HomeArtworkBuilder = Widget Function(BuildContext context, HomeItem item);

/// Home shelves from an injected repository. Artwork never fetches by default.
class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.controller,
    required this.onSelect,
    this.onOpenSection,
    this.artworkBuilder,
    this.showFilters = false,
    this.facet,
    this.onSelectFacet,
  });

  final HomeController controller;
  final ValueChanged<HomeItem> onSelect;
  final ValueChanged<HomeSection>? onOpenSection;
  final HomeArtworkBuilder? artworkBuilder;
  final bool showFilters;
  final String? facet;
  final ValueChanged<String>? onSelectFacet;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didUpdateWidget(HomeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.facet != widget.facet) _initialize();
  }

  void _initialize() {
    final facet = widget.facet;
    if (facet != null && facet != widget.controller.state.facet) {
      unawaited(widget.controller.setFacet(facet));
    } else { unawaited(widget.controller.initialize()); }
  }

  void _selectFacet(String facet) {
    if (widget.onSelectFacet case final select?) { select(facet); }
    else { unawaited(widget.controller.setFacet(facet)); }
  }

  Widget _filters(HomePage page, String facet) => SingleChildScrollView(
    scrollDirection: Axis.horizontal, child: Row(children: [
      _chip('All', selected: facet.isEmpty, onSelect: () => _selectFacet('')),
      for (final chip in page.chips) ...[
        _chip(chip.label, selected: facet == chip.id || chip.subChips.any((child) => child.id == facet),
          onSelect: () => _selectFacet(facet == chip.id || chip.subChips.any((child) => child.id == facet) ? '' : chip.id)),
        if (facet == chip.id || chip.subChips.any((child) => child.id == facet))
          for (final child in chip.subChips) _chip(child.label, selected: facet == child.id,
            onSelect: () => _selectFacet(facet == child.id ? chip.id : child.id)),
      ],
    ]));

  Widget _chip(String label, {required bool selected, required VoidCallback onSelect}) => Padding(
    padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
      label: Text(label), selected: selected, showCheckmark: false,
      side: BorderSide.none, shape: const StadiumBorder(),
      backgroundColor: const Color(0xff292929), selectedColor: Colors.white,
      labelStyle: TextStyle(fontSize: 14, color: selected ? Colors.black : Colors.white),
      onSelected: (_) => onSelect(),
    ));

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xff121212),
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        final page = state.page;
        if (page == null) {
          return switch (state.phase) {
            HomePhase.failed => _status('Couldn’t load Home', retry: widget.controller.refresh),
            _ => const Center(child: CircularProgressIndicator(color: Color(0xff1ed760))),
          };
        }
        final sections = page.sections.where((section) => !isAdvertisingSection(section.sourceType)).toList(growable: false);
        return LayoutBuilder(builder: (context, constraints) {
          final inset = constraints.maxWidth < 600 ? 16.0 : 24.0;
          final hasStatus = state.phase == HomePhase.failed || state.phase == HomePhase.loading;
          return Column(children: [
            if (widget.showFilters) Padding(padding: EdgeInsets.fromLTRB(inset, 16, inset, 8),
              child: Align(alignment: Alignment.centerLeft, child: _filters(page, state.facet))),
            if (state.phase == HomePhase.loading)
              const LinearProgressIndicator(minHeight: 2, color: Color(0xff1ed760)),
            if (state.phase == HomePhase.failed)
              Padding(padding: EdgeInsets.symmetric(horizontal: inset, vertical: 8),
                child: Row(children: [
                  const Expanded(child: Text('Couldn’t refresh Home', style: _secondary)),
                  TextButton(onPressed: widget.controller.refresh, child: const Text('Try again')),
                ])),
            Expanded(child: sections.isEmpty
              ? _status('There’s nothing to show right now.')
              : ListView.builder(
                key: PageStorageKey(state.facet.isEmpty ? 'home-sections' : 'home-sections:${state.facet}'),
                padding: EdgeInsets.fromLTRB(inset, hasStatus ? 12 : 20, inset, 40),
                itemCount: sections.length,
                itemBuilder: (context, index) {
                  final section = sections[index];
                  return Padding(
                    key: ValueKey('home-section:${section.uri}'),
                    padding: const EdgeInsets.only(bottom: 24),
                    child: _shelf(context, section, constraints.maxWidth - inset * 2, page.greeting),
                  );
                },
              )),
          ]);
        });
      },
    ),
  );

  Widget _status(String message, {VoidCallback? retry}) => Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(message, textAlign: TextAlign.center, style: _heading),
      if (retry != null) Padding(padding: const EdgeInsets.only(top: 16),
        child: FilledButton(onPressed: retry, child: const Text('Try again'))),
    ]),
  ));

  Widget _shelf(BuildContext context, HomeSection section, double width, String? greeting) {
    if (section.kind == HomeSectionKind.shortcuts) return _shortcuts(context, section, width, greeting);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (section.title.isNotEmpty || section.pretitle?.isNotEmpty == true)
        Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (section.pretitle?.isNotEmpty == true)
                Text(section.pretitle!, style: _secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(section.title, style: _heading, maxLines: 2, overflow: TextOverflow.ellipsis),
            ])),
            if (section.seeAllUri != null && widget.onOpenSection != null)
              TextButton(onPressed: () => widget.onOpenSection!(section),
                style: TextButton.styleFrom(foregroundColor: const Color(0xffb3b3b3)),
                child: const Text('Show all')),
          ],
        )),
      if (section.kind == HomeSectionKind.unsupported)
        const Padding(padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Content is currently unavailable.', style: _secondary))
      else if (section.kind == HomeSectionKind.feed)
        _cards(context, section, math.min(width, width < 380 ? width : (width * .55).clamp(380, 480)), feed: true)
      else
        _cards(context, section, width / math.max(1, (width / (width < 1200 ? 160 : 210)).floor())),
    ]);
  }

  Widget _shortcuts(BuildContext context, HomeSection section, double width, String? greeting) {
    final columns = width >= 815 ? section.items.length % 4 == 0 ? 4 : 3 : 2;
    final gap = width >= 1141 ? 12.0 : 8.0;
    final height = width >= 1599 ? 80.0 : width >= 1141 ? 64.0 : 48.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!widget.showFilters) Padding(padding: const EdgeInsets.only(bottom: 20),
        child: Text(greeting ?? _localGreeting(), style: _heading.copyWith(fontSize: 32))),
      GridView.builder(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns, mainAxisExtent: height,
        mainAxisSpacing: gap, crossAxisSpacing: gap,
      ),
      itemCount: section.items.length,
      itemBuilder: (context, index) {
        final item = section.items[index];
        return Material(color: const Color(0xff292929), borderRadius: BorderRadius.circular(4),
          clipBehavior: Clip.antiAlias, child: InkWell(
            onTap: () => widget.onSelect(item),
            child: Row(children: [
              SizedBox.square(dimension: height, child: _artwork(context, item)),
              Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)))),
            ]),
          ));
      },
      ),
    ]);
  }

  Widget _cards(BuildContext context, HomeSection section, double width, {bool feed = false}) {
    final scaled = MediaQuery.textScalerOf(context).scale(1);
    final height = feed ? width + 172 * scaled : width + (section.items.any((item) => item.showTitle) ? 80 : 56) * scaled;
    return SizedBox(height: height, child: ListView.builder(
      scrollDirection: Axis.horizontal,
      itemExtent: width,
      itemCount: section.items.length,
      itemBuilder: (context, index) {
        final item = section.items[index];
        return Padding(padding: EdgeInsets.only(right: feed ? 16 : 0), child: Material(
          color: feed ? const Color(0xff181818) : Colors.transparent,
          borderRadius: BorderRadius.circular(8), clipBehavior: Clip.antiAlias,
          child: Semantics(label: item.showTitle || feed ? null : item.name,
            child: InkWell(onTap: () => widget.onSelect(item), child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (feed && item.reason.isNotEmpty) Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(item.reason, maxLines: 1, overflow: TextOverflow.ellipsis, style: _secondary)),
              AspectRatio(aspectRatio: 1, child: ClipRRect(
                borderRadius: BorderRadius.circular(item.type == 'artist' ? width : 6),
                child: _artwork(context, item),
              )),
              const SizedBox(height: 8),
              if (item.showTitle || feed) ...[
                Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: feed ? 20 : 16, fontWeight: feed ? FontWeight.w700 : FontWeight.w400)),
                const SizedBox(height: 4),
              ],
              if (!feed && item.cardSubtitle.isNotEmpty)
                Text(item.cardSubtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: _secondary)
              else if (feed && item.contributors.isNotEmpty)
                Text(item.contributors.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: _secondary),
              if (feed && item.description.isNotEmpty) Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: _secondary)),
              if (item.isExplicit || item.durationMs != null) Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  if (item.isExplicit) const Padding(padding: EdgeInsets.only(right: 6),
                    child: Text('E', style: TextStyle(color: Color(0xffb3b3b3), fontSize: 12, fontWeight: FontWeight.w700))),
                  if (item.durationMs != null) Flexible(child: Text(_duration(item.durationMs!),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: _secondary)),
                ])),
            ]),
          ))),
        ));
      },
    ));
  }

  Widget _artwork(BuildContext context, HomeItem item) =>
      widget.artworkBuilder?.call(context, item) ?? Semantics(
        label: '${item.name} artwork unavailable', image: true,
        child: const ColoredBox(color: Color(0xff282828)),
      );
}

String _duration(int milliseconds) {
  final minutes = milliseconds ~/ 60000;
  return minutes >= 60 ? '${minutes ~/ 60} hr ${minutes % 60} min' : '$minutes min';
}

String _localGreeting() {
  final hour = DateTime.now().hour;
  return hour >= 5 && hour < 12 ? 'Good morning'
      : hour >= 12 && hour < 18 ? 'Good afternoon' : 'Good evening';
}

const _heading = TextStyle(fontFamily: 'SpotifyMixUITitle', fontSize: 24,
  fontWeight: FontWeight.w700, color: Colors.white);
const _secondary = TextStyle(fontSize: 14, color: Color(0xffb3b3b3));
