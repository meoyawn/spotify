import 'package:flutter/material.dart';

import '../playback/models.dart';
import '../entities/models.dart';
import '../lyrics/controller.dart';
import '../lyrics/view.dart';
import 'playback_bar.dart';
import 'desktop_icon_button.dart';
import 'shell_icons.dart';

class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({super.key, required this.state, this.artworkBuilder,
    this.lyricsController, this.onShowLyrics, this.onNavigate,
    this.trackSaveButtonBuilder, required this.onClose});
  final PlaybackState state;
  final LyricsController? lyricsController;
  final VoidCallback? onShowLyrics;
  final ValueChanged<EntityLink>? onNavigate;
  final PlaybackArtworkBuilder? artworkBuilder;
  final TrackSaveButtonBuilder? trackSaveButtonBuilder;
  final VoidCallback onClose;

  @override Widget build(BuildContext context) {
    final item = state.item;
    if (item == null) return const SizedBox.shrink();
    final artists = (item.toJson()['artists'] as List? ?? []).whereType<Map>()
      .map((artist) => artist.cast<String, Object?>()).toList();
    final track = EntityLink.fromJson({'uri': item.uri, 'name': item.name}, type: 'track');
    final saveUri = item.metadata['original_uri'] ?? item.uri;
    final saveButton = RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(saveUri)
      ? trackSaveButtonBuilder?.call(context, saveUri) : null;
    final contextMetadata = state.context['metadata'];
    final contextTitle = contextMetadata is Map ? contextMetadata['context_description'] ?? contextMetadata['title'] : null;
    final details = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [Expanded(child: InkWell(onTap: track == null || onNavigate == null ? null : () => onNavigate!(track),
        child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, height: 1.15)))),
        if (saveButton != null) ...[const SizedBox(width: 8), saveButton]]),
      if (artists.isNotEmpty) ...[const SizedBox(height: 6),
        Wrap(spacing: 6, children: [for (final (index, artist) in artists.indexed)
          InkWell(onTap: EntityLink.fromJson(artist, type: 'artist') == null || onNavigate == null ? null
            : () => onNavigate!(EntityLink.fromJson(artist, type: 'artist')!),
            child: Text('${artist['name']}${index < artists.length - 1 ? ',' : ''}',
              style: const TextStyle(fontSize: 14, color: Colors.white)))])],
    ]);
    return Material(color: const Color(0xff121212), borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias, child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 64, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [Expanded(child: Text(contextTitle is String && contextTitle.isNotEmpty
              ? contextTitle : item.metadata['album_title'] ?? item.name, maxLines: 1,
              overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              DesktopIconButton(tooltip: 'Close Now Playing', onPressed: onClose,
                icon: const Icon(SpotifyShellIcons.close, size: 16))]))),
          LayoutBuilder(builder: (context, bounds) => SizedBox(height: bounds.maxWidth + 48,
            child: Stack(fit: StackFit.expand, children: [
              const ColoredBox(color: Color(0xff0a0a0a)),
              Positioned(left: 0, right: 0, top: 74, height: bounds.maxWidth,
                child: artworkBuilder?.call(context, item) ?? const ColoredBox(color: Color(0xff282828))),
              const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Color(0x00000000), Color(0x33000000), Color(0xff121212)], stops: [0, 0.45, 1]))),
              Positioned(left: 16, right: 16, bottom: 16, child: details),
            ]))),
          if (lyricsController != null && item.type == 'track') ...[
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 0), child: ClipRRect(borderRadius: BorderRadius.circular(8),
              child: LyricsView(controller: lyricsController!, preview: true, onExpand: onShowLyrics)))],
          if (state.nextItems.isNotEmpty) Padding(padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 32),
            const Text('Next in queue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            for (final next in state.nextItems.take(3)) Padding(padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(onTap: onNavigate == null || next.type != 'track' ? null
                : () => onNavigate!(EntityLink(uri: next.uri, name: next.name, type: 'track')),
              child: Row(children: [SizedBox.square(dimension: 48,
                child: artworkBuilder?.call(context, next) ?? const ColoredBox(color: Color(0xff282828))),
                const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(next.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(next.metadata['artist_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Color(0xffb3b3b3)))],
                ))]))),
          ])),
        ])));
  }
}
