import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode, kProfileMode;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app/playback_application.dart';
import 'diagnostics/http_status_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isMacOS) {
    try {
      final library = await getLibraryDirectory();
      final mode = kReleaseMode ? 'release' : kProfileMode ? 'profile' : 'debug';
      await HttpStatusLog.initialize(
        directory: Directory('${library.path}/Logs/spotify_flutter/$mode'), mode: mode);
    } catch (error) { stderr.writeln('HTTP logging could not start (${error.runtimeType}).'); }
  }
  runApp(const SpotifyPlaybackApplication());
}
