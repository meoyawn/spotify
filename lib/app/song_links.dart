import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'snack_bar.dart';

/// Original URI.toURL(), without the optional sharing ID and telemetry.
String? spotifySongLink(String uri) => RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)
  ? 'https://open.spotify.com/track/${uri.substring(14)}' : null;

Future<void> copySongLink(BuildContext context, String uri) async {
  final link = spotifySongLink(uri);
  if (link == null) return;
  try {
    await Clipboard.setData(ClipboardData(text: link));
    if (context.mounted) showSpotifySnackBar(context, 'Link copied to clipboard');
  } on PlatformException {
    if (context.mounted) showSpotifySnackBar(context, 'Couldn’t copy the song link.');
  }
}

class SongLinkMenu extends StatelessWidget {
  const SongLinkMenu({super.key, required this.uri, required this.name});
  final String uri, name;

  @override Widget build(BuildContext context) => spotifySongLink(uri) == null
    ? const SizedBox.shrink() : SizedBox.square(dimension: 32,
      child: PopupMenuButton<String>(tooltip: 'More options for $name',
        padding: EdgeInsets.zero, icon: const Icon(Icons.more_horiz, size: 20),
        itemBuilder: (_) => const [PopupMenuItem(value: 'copy', child: Text('Copy song link'))],
        onSelected: (_) => unawaited(copySongLink(context, uri))));
}

class SongLinkContextMenu extends StatelessWidget {
  const SongLinkContextMenu({super.key, required this.uri, required this.child});
  final String uri;
  final Widget child;

  @override Widget build(BuildContext context) => spotifySongLink(uri) == null ? child : GestureDetector(
    onSecondaryTapUp: (details) async {
      final presentation = Navigator.of(context, rootNavigator: true).context;
      final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
      final point = overlay.globalToLocal(details.globalPosition);
      final selected = await showMenu<String>(context: context,
        position: RelativeRect.fromRect(Rect.fromLTWH(point.dx, point.dy, 0, 0), Offset.zero & overlay.size),
        items: const [PopupMenuItem(value: 'copy', child: Text('Copy song link'))]);
      if (selected != null && presentation.mounted) await copySongLink(presentation, uri);
    }, child: child);
}
