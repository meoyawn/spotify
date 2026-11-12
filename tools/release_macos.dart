import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import 'dev.dart' as desktop;

final _root = File.fromUri(Platform.script).parent.parent.resolveSymbolicLinksSync();
const _app = 'spotify_flutter.app';
const _bundleId = 'dev.meoyawn.spotifyFlutter';
const _register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/'
  'LaunchServices.framework/Support/lsregister';

Future<void> _run(List<String> command, CancellationToken cancellationToken) async {
  cancellationToken.throwIfCancelled();
  final child = await Process.start(command.first, command.skip(1).toList(),
    workingDirectory: _root, mode: ProcessStartMode.inheritStdio);
  try {
    final code = await child.exitCode.asCancellable(cancellationToken,
      onCancel: () => child.kill(ProcessSignal.sigint));
    if (code != 0) throw ProcessException(command.first, command.skip(1).toList(), 'Command failed', code);
  } on CancelledException {
    await child.exitCode;
    rethrow;
  }
}

Map<String, dynamic> _bundleInfo(String bundle) {
  final result = Process.runSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '$bundle/Contents/Info.plist']);
  if (result.exitCode != 0) throw StateError('Cannot read bundle identity: $bundle');
  final info = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  if (info['CFBundleIdentifier'] != _bundleId) {
    throw StateError('Refusing a bundle with a different identity: $bundle');
  }
  final executable = info['CFBundleExecutable'];
  if (executable is! String || executable.isEmpty || executable.contains('/') || executable == '..') {
    throw StateError('Invalid bundle executable: $bundle');
  }
  return info;
}

Future<void> _verify(String bundle, CancellationToken cancellationToken) async {
  final info = _bundleInfo(bundle);
  final required = ['MacOS/${info['CFBundleExecutable']}',
    'Frameworks/App.framework/App', 'Frameworks/FlutterMacOS.framework/FlutterMacOS',
    'Frameworks/libquiche.dylib', 'Frameworks/libnghttp3.dylib',
    'Frameworks/libspotify_ffmpeg.dylib', 'Frameworks/libspotify_streaming.dylib',
    'Resources/AppIcon.icns'];
  for (final relative in required) {
    if (!File('$bundle/Contents/$relative').existsSync()) {
      throw StateError('Incomplete release bundle: missing $relative');
    }
  }
  await _run(['/usr/bin/codesign', '--verify', '--deep', '--strict', bundle], cancellationToken);
}

List<int> _releasePids(String bundle) {
  final executable = '$bundle/Contents/MacOS/${_bundleInfo(bundle)['CFBundleExecutable']}';
  return [for (final (pid, command) in desktop.processes('comm')) if (command == executable) pid];
}

void _requireStopped(String bundle) {
  final pids = _releasePids(bundle);
  if (pids.isNotEmpty) throw StateError('Release still running as PID(s) $pids; no bundle was replaced.');
}

Future<void> _stopRelease(String bundle, CancellationToken cancellationToken) async {
  final pids = _releasePids(bundle);
  if (pids.isEmpty) return;
  stdout.writeln('Stopping installed release PID(s): $pids');
  for (final pid in pids) {
    cancellationToken.throwIfCancelled();
    // Recheck the exact executable immediately before signalling a PID.
    if (_releasePids(bundle).contains(pid)) Process.killPid(pid, ProcessSignal.sigterm);
  }
  final elapsed = Stopwatch()..start();
  while (_releasePids(bundle).isNotEmpty) {
    if (elapsed.elapsed >= const Duration(seconds: 15)) _requireStopped(bundle);
    await Future<void>.delayed(const Duration(milliseconds: 100)).asCancellable(cancellationToken);
  }
  stdout.writeln('Installed release exited.');
}

Future<RandomAccessFile> _lock(String name, CancellationToken cancellationToken) async {
  final directory = Directory('$_root/.local/run')..createSync(recursive: true);
  final file = File('${directory.path}/$name').openSync(mode: FileMode.append);
  try {
    while (true) {
      cancellationToken.throwIfCancelled();
      try { file.lockSync(FileLock.exclusive); return file; }
      on FileSystemException catch (error) {
        if (error.osError?.errorCode != 11 && error.osError?.errorCode != 35) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100)).asCancellable(cancellationToken);
      }
    }
  } catch (_) {
    file.closeSync();
    rethrow;
  }
}

Future<void> _install(String release, String applications, CancellationToken cancellationToken) async {
  await _verify(release, cancellationToken);
  final directory = Directory(applications)..createSync(recursive: true);
  final destination = '${directory.resolveSymbolicLinksSync()}/$_app';
  if (FileSystemEntity.typeSync(destination, followLinks: false) == FileSystemEntityType.link) {
    throw StateError('Refusing to replace a symlink: $destination');
  }
  final temporary = directory.createTempSync('.spotify-flutter-install-');
  final staged = '${temporary.path}/$_app', previous = '${temporary.path}/previous.app';
  var succeeded = false;
  try {
    await _run(['/usr/bin/ditto', release, staged], cancellationToken);
    await _verify(staged, cancellationToken);
    final launchLock = await _lock('launch.lock', cancellationToken);
    try {
      // Debug apps and Flutter supervisors are independent of this destination.
      if (Directory(destination).existsSync()) {
        await _stopRelease(destination, cancellationToken);
        _requireStopped(destination);
        Directory(destination).renameSync(previous);
      }
      try {
        cancellationToken.throwIfCancelled();
        Directory(staged).renameSync(destination);
        await _verify(destination, cancellationToken);
      } catch (_) {
        if (Directory(destination).existsSync()) Directory(destination).renameSync(staged);
        if (Directory(previous).existsSync()) Directory(previous).renameSync(destination);
        rethrow;
      }
    } finally {
      launchLock.closeSync();
    }
    succeeded = true;
    final registered = Process.runSync(_register, ['-f', destination]);
    if (registered.exitCode != 0) stdout.writeln('Installed successfully; Launch Services registration could not be refreshed.');
    stdout.writeln('Installed release: $destination');
  } finally {
    if (succeeded || !Directory(previous).existsSync()) {
      temporary.deleteSync(recursive: true);
    } else {
      stderr.writeln('Previous installation retained at $previous');
    }
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && (arguments.first == '--help' || arguments.first == '-h')) {
    stdout.writeln('Usage: dart run tools/release_macos.dart <build|install> [--applications-dir PATH]');
    return;
  }
  if (!Platform.isMacOS || arguments.isEmpty || !['build', 'install'].contains(arguments.first) ||
      (arguments.length != 1 && (arguments.length != 3 || arguments[1] != '--applications-dir'))) {
    stderr.writeln('Usage: dart run tools/release_macos.dart <build|install> [--applications-dir PATH] (macOS only)');
    exitCode = 64;
    return;
  }
  final cancellation = CancellationToken();
  final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
    .map((signal) => signal.watch().listen((_) => cancellation.cancel())).toList();
  try {
    final lock = await _lock('macos-release.lock', cancellation);
    try {
      final release = '$_root/build/macos/Build/Products/Release/$_app';
      if (arguments.first == 'build') {
        await _run(['flutter', 'build', 'macos', '--release'], cancellation);
        await _verify(release, cancellation);
        stdout.writeln('Built release: $release');
      } else {
        await _install(release, arguments.length == 3 ? arguments[2] : '/Applications', cancellation);
      }
    } finally {
      lock.closeSync();
    }
  } on CancelledException {
    exitCode = 130;
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    for (final signal in signals) { await signal.cancel(); }
    cancellation.cancel();
  }
}
