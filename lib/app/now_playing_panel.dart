import 'package:flutter/material.dart';

import '../playback/models.dart';
import '../entities/models.dart';
import '../entities/artist_about_repository.dart';
import '../entities/view.dart' show EntityArtworkBuilder;
import '../lyrics/controller.dart';
import '../lyrics/view.dart';
import 'playback_bar.dart';
import 'share_links.dart';
import 'desktop_icon_button.dart';
import 'shell_icons.dart';
import 'artist_about_card.dart';

/// Cover-art presentation recovered in native-now-playing-sidebar.json.
class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({super.key, required this.state, this.artworkBuilder,
    this.lyricsController, this.onShowLyrics, this.onNavigate,
    this.artistAboutRepository, this.artistArtworkBuilder, this.onLibraryChanged,
    this.trackSaveButtonBuilder, required this.onClose});
  final PlaybackState state;
  final LyricsController? lyricsController;
  final VoidCallback? onShowLyrics;
  final ValueChanged<EntityLink>? onNavigate;
  final ArtistAboutRepository? artistAboutRepository;
  final EntityArtworkBuilder? artistArtworkBuilder;
  final VoidCallback? onLibraryChanged;
  final PlaybackArtworkBuilder? artworkBuilder;
  final TrackSaveButtonBuilder? trackSaveButtonBuilder;
  final VoidCallback onClose;

  @override Widget build(BuildContext context) {
    final item = state.item;
    if (item == null) return const SizedBox.shrink();
    final artists = (item.toJson()['artists'] as List? ?? []).whereType<Map>()
      .map((artist) => artist.cast<String, Object?>())
      .where((artist) => (artist['name'] as String? ?? '').isNotEmpty).toList();
    final track = EntityLink.fromJson({'uri': item.uri, 'name': item.name}, type: 'track');
    final album = EntityLink.fromJson({'uri': item.metadata['album_uri'],
      'name': item.metadata['album_title']}, type: 'album');
    final saveUri = item.metadata['original_uri'] ?? item.uri;
    final saveButton = RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(saveUri)
      ? trackSaveButtonBuilder?.call(context, saveUri) : null;
    final contextMetadata = state.context['metadata'];
    final contextTitle = contextMetadata is Map ? contextMetadata['context_description'] ?? contextMetadata['title'] : null;
    final title = item.provider == 'queue' ? 'Queue' : contextTitle is String && contextTitle.isNotEmpty
      ? contextTitle : item.metadata['album_title'] ?? item.name;
    final contextUri = state.context['uri'] as String? ?? '';
    final contextLink = EntityLink.fromJson({'uri': contextUri, 'name': title},
      type: contextUri.split(':').elementAtOrNull(1) ?? '');
    final next = state.nextItems.firstOrNull;
    final artistUri = artists.map((artist) => artist['uri']).whereType<String>()
      .where((uri) => RegExp(r'^spotify:artist:[0-9A-Za-z]{22}$').hasMatch(uri)).firstOrNull;
    final details = Row(children: [Expanded(child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      InkWell(onTap: track == null || onNavigate == null ? null : () => onNavigate!(track),
        child: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'SpotifyMixUITitle', fontSize: 24,
            fontWeight: FontWeight.w700, height: 1.2))),
      if (artists.isNotEmpty) ...[const SizedBox(height: 4),
        Wrap(spacing: 6, children: [for (final (index, artist) in artists.indexed)
          SpotifyLinkContextMenu(uri: artist['uri'] as String? ?? '',
            child: InkWell(onTap: EntityLink.fromJson(artist, type: 'artist') == null || onNavigate == null ? null
            : () => onNavigate!(EntityLink.fromJson(artist, type: 'artist')!),
            child: Text('${artist['name']}${index < artists.length - 1 ? ',' : ''}',
              style: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xffb3b3b3)))))])],
    ])), if (saveButton != null) ...[const SizedBox(width: 12), saveButton]]);
    return Material(color: const Color(0xff121212), borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 64, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [Expanded(child: InkWell(
              onTap: item.provider == 'queue' || contextLink == null || onNavigate == null ? null
                : () => onNavigate!(contextLink),
              child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)))),
              if (spotifyShareLink(saveUri) != null) SpotifyLinkMenu(uri: saveUri, name: item.name),
              DesktopIconButton(tooltip: 'Close Now Playing', onPressed: onClose,
                icon: const Icon(SpotifyShellIcons.close, size: 16))]))),
          Expanded(child: SingleChildScrollView(key: ValueKey(item.uri),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Original COVER_ART branch: inset square, then a 16px details gap.
          // Canvas has its own presentation; album art never uses its overlay.
          AspectRatio(aspectRatio: 1, child: ClipRRect(borderRadius: BorderRadius.circular(8),
            child: SpotifyLinkContextMenu(uri: album?.uri ?? saveUri, child: InkWell(
              onTap: album == null || onNavigate == null ? null : () => onNavigate!(album),
              child: artworkBuilder?.call(context, item) ?? const ColoredBox(color: Color(0xff282828)))))),
          const SizedBox(height: 16),
          SpotifyLinkContextMenu(uri: saveUri, child: details),
          const SizedBox(height: 24),
          if (lyricsController != null && item.type == 'track')
            LyricsView(controller: lyricsController!, preview: true, onExpand: onShowLyrics),
          if (artistAboutRepository != null && artistUri != null && item.type == 'track')
            ArtistAboutCard(uri: artistUri, repository: artistAboutRepository!,
              artworkBuilder: artistArtworkBuilder, onNavigate: onNavigate,
              onLibraryChanged: onLibraryChanged),
          if (next != null) DecoratedBox(decoration: BoxDecoration(color: const Color(0xff1f1f1f),
            borderRadius: BorderRadius.circular(8)), child: Padding(padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Next in queue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            InkWell(onTap: onNavigate == null || next.type != 'track' ? null
                : () => onNavigate!(EntityLink(uri: next.uri, name: next.name, type: 'track')),
              child: Row(children: [ClipRRect(borderRadius: BorderRadius.circular(4), child: SizedBox.square(dimension: 48,
                child: artworkBuilder?.call(context, next) ?? const ColoredBox(color: Color(0xff282828)))),
                const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(next.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, height: 1.5)),
                    Text(next.metadata['artist_name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.4, color: Color(0xffb3b3b3)))],
                ))])),
          ]))),
        ]))),
      ]));
  }
}
