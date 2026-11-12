import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'snack_bar.dart';

/// Original URI.toURL(), without the optional sharing ID and telemetry.
String? spotifyShareLink(String uri) => RegExp(r'^spotify:(track|album|artist):[0-9A-Za-z]{22}$').hasMatch(uri)
  ? 'https://open.spotify.com/${uri.substring(8).replaceFirst(':', '/')}' : null;

String spotifyCopyLinkLabel(String uri) => switch (uri.split(':').elementAtOrNull(1)) {
  'album' => 'Copy album link', 'artist' => 'Copy artist link', _ => 'Copy song link',
};

Future<void> copySpotifyLink(BuildContext context, String uri) async {
  final link = spotifyShareLink(uri);
  if (link == null) return;
  try {
    await Clipboard.setData(ClipboardData(text: link));
    if (context.mounted) showSpotifySnackBar(context, 'Link copied to clipboard');
  } on PlatformException {
    if (context.mounted) showSpotifySnackBar(context, 'Couldn’t copy the link.');
  }
}

class SpotifyLinkMenu extends StatelessWidget {
  const SpotifyLinkMenu({super.key, required this.uri, required this.name});
  final String uri, name;

  @override Widget build(BuildContext context) => spotifyShareLink(uri) == null
    ? const SizedBox.shrink() : SizedBox.square(dimension: 32,
      child: PopupMenuButton<String>(tooltip: 'More options for $name',
        padding: EdgeInsets.zero, icon: const Icon(Icons.more_horiz, size: 20),
        itemBuilder: (_) => [PopupMenuItem(value: 'copy', child: Text(spotifyCopyLinkLabel(uri)))],
        onSelected: (_) => unawaited(copySpotifyLink(context, uri))));
}

Future<void> showSpotifyLinkContextMenu(BuildContext context, String uri, Offset globalPosition) async {
  if (spotifyShareLink(uri) == null) return;
  final presentation = Navigator.of(context, rootNavigator: true).context;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final point = overlay.globalToLocal(globalPosition);
  final selected = await showMenu<String>(context: context,
    position: RelativeRect.fromRect(Rect.fromLTWH(point.dx, point.dy, 0, 0), Offset.zero & overlay.size),
    items: [PopupMenuItem(value: 'copy', child: Text(spotifyCopyLinkLabel(uri)))]);
  if (selected != null && presentation.mounted) await copySpotifyLink(presentation, uri);
}

class SpotifyLinkContextMenu extends StatelessWidget {
  const SpotifyLinkContextMenu({super.key, required this.uri, required this.child});
  final String uri;
  final Widget child;

  @override Widget build(BuildContext context) => spotifyShareLink(uri) == null ? child : GestureDetector(
    onSecondaryTapUp: (details) => unawaited(showSpotifyLinkContextMenu(context, uri, details.globalPosition)),
    child: child);
}
