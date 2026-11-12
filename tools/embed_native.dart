import 'dart:io';

bool _sameFile(File source, File destination) {
  if (!destination.existsSync() || source.lengthSync() != destination.lengthSync()) return false;
  final first = source.openSync(), second = destination.openSync();
  try {
    while (true) {
      final left = first.readSync(65536), right = second.readSync(65536);
      if (left.length != right.length) return false;
      if (left.isEmpty) return true;
      for (var index = 0; index < left.length; index++) {
        if (left[index] != right[index]) return false;
      }
    }
  } finally { first.closeSync(); second.closeSync(); }
}

void main() {
  final root = File.fromUri(Platform.script).parent.parent.path;
  final environment = Platform.environment;
  final target = environment['TARGET_BUILD_DIR']!;
  final frameworks = Directory('$target/${environment['FRAMEWORKS_FOLDER_PATH']}')..createSync(recursive: true);
  final resources = Directory('$target/${environment['UNLOCALIZED_RESOURCES_FOLDER_PATH']}/Licenses')..createSync(recursive: true);
  for (final name in ['quiche', 'nghttp3', 'spotify_ffmpeg', 'spotify_streaming']) {
    final source = File('$root/.local/native/lib$name.dylib');
    if (!source.existsSync()) throw StateError('Build native dependencies first: moonx native');
    final destination = File('${frameworks.path}/lib$name.dylib');
    if (_sameFile(source, destination)) continue;
    source.copySync(destination.path);
    if (environment['CODE_SIGNING_ALLOWED'] != 'NO') {
      final identity = environment['EXPANDED_CODE_SIGN_IDENTITY'];
      final signing = Process.runSync('/usr/bin/codesign', ['--force', '--sign',
        identity == null || identity.isEmpty ? '-' : identity, '--timestamp=none', destination.path]);
      if (signing.exitCode != 0) throw StateError('${signing.stderr}');
    }
  }
  for (final name in ['quiche', 'nghttp3']) {
    final destination = Directory('${resources.path}/$name')..createSync(recursive: true);
    for (final source in Directory('$root/native/$name').listSync().whereType<File>()) {
      if (source.uri.pathSegments.last.startsWith('LICENSE.')) source.copySync('${destination.path}/${source.uri.pathSegments.last}');
    }
  }
  final ffmpeg = Directory('${resources.path}/ffmpeg')..createSync(recursive: true);
  for (final path in ['.local/native/LICENSE.ffmpeg', '.local/native/ffmpeg-build.json',
    '.local/native/streaming-build.json', 'native/ffmpeg/upstream.json']) {
    final source = File('$root/$path');
    source.copySync('${ffmpeg.path}/${source.uri.pathSegments.last}');
  }
}
