import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'app.dart';

@Preview(name: 'Spotify desktop shell', group: 'App', size: Size(1280, 800))
@Preview(name: 'Spotify narrow shell', group: 'App', size: Size(420, 640))
Widget spotifyDesktopPreview() => const SpotifyDesktopApp();
