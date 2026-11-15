import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/material.dart';

import '../entities/artist_about_repository.dart';
import '../entities/artist_follow_button.dart';
import '../entities/models.dart';
import '../entities/view.dart' show EntityArtworkBuilder;
import 'share_links.dart';

class ArtistAboutCard extends StatefulWidget {
  const ArtistAboutCard({super.key, required this.uri, required this.repository,
    this.artworkBuilder, this.onNavigate, this.onLibraryChanged});
  final String uri;
  final ArtistAboutRepository repository;
  final EntityArtworkBuilder? artworkBuilder;
  final ValueChanged<EntityLink>? onNavigate;
  final VoidCallback? onLibraryChanged;
  @override State<ArtistAboutCard> createState() => _ArtistAboutCardState();
}

class _ArtistAboutCardState extends State<ArtistAboutCard> {
  CancellationToken _request = CancellationToken();
  EntityDetails? _artist;

  @override void initState() { super.initState(); _load(); }
  @override void didUpdateWidget(ArtistAboutCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri == widget.uri && oldWidget.repository == widget.repository) return;
    _request.cancel(); _request = CancellationToken();
    _artist = null;
    _load();
  }
  void _load() { unawaited(_loadArtist(_request)); }
  Future<void> _loadArtist(CancellationToken token) async {
    try {
      final artist = await widget.repository.artist(widget.uri, cancellationToken: token);
      if (mounted && !token.isCancelled) setState(() => _artist = artist);
    } catch (_) { /* The original omits unavailable artist biographies. */ }
  }
  @override void dispose() { _request.cancel(); super.dispose(); }

  void _open() {
    final artist = _artist;
    if (artist != null) widget.onNavigate?.call(EntityLink(uri: artist.uri, name: artist.name, type: 'artist'));
  }

  @override Widget build(BuildContext context) {
    final artist = _artist;
    if (artist == null) return const SizedBox.shrink();
    final gallery = artist.data['hasGallery'] == true;
    final listeners = (artist.data['stats'] as Map?)?['monthlyListeners'];
    final biography = (artist.data['biography'] as String).replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&amp;', '&').replaceAll('&quot;', '"').replaceAll('&#39;', "'").replaceAll('&nbsp;', ' ').trim();
    return Padding(padding: const EdgeInsets.only(bottom: 16), child: SpotifyLinkContextMenu(uri: artist.uri,
      child: Material(color: const Color(0xff1f1f1f), borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias, child: InkWell(onTap: widget.onNavigate == null ? null : _open,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (gallery) AspectRatio(aspectRatio: 1, child: Stack(fit: StackFit.expand, children: [
              widget.artworkBuilder?.call(context, artist) ?? const ColoredBox(color: Color(0xff282828)),
              const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.center,
                colors: [Color(0x99000000), Colors.transparent]))),
              const Positioned(top: 16, left: 16, right: 16, child: Text('About the artist',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            ])) else Padding(padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('About the artist', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                if (artist.images.isNotEmpty) ...[const SizedBox(height: 16),
                  ClipOval(child: SizedBox.square(dimension: 80,
                    child: widget.artworkBuilder?.call(context, artist) ?? const ColoredBox(color: Color(0xff282828))))],
              ])),
            Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(artist.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Padding(padding: const EdgeInsets.only(top: 8, bottom: 12), child: Wrap(
                spacing: 8, runSpacing: 8, alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (listeners is num && listeners > 0) Text('${_count(listeners.toInt())} monthly listeners',
                    style: const TextStyle(fontSize: 16, height: 1.5, color: Color(0xffb3b3b3))),
                  ArtistFollowButton(uri: artist.uri, name: artist.name, repository: widget.repository,
                    compact: true, onLibraryChanged: widget.onLibraryChanged),
                ])),
              Text(biography, maxLines: 3, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, height: 1.5, color: Color(0xffb3b3b3))),
            ])),
          ])))));
  }
}

String _count(int value) => value.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
