import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

Future<void> main(List<String> arguments) async {
  try {
    exitCode = await dev(arguments);
  } on ProcessException catch (error) {
    stderr.writeln('Cannot start Flutter: $error');
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln('Cannot start Flutter: $error');
    exitCode = 1;
  }
}

Future<int> dev(List<String> arguments) async {
  if (!Platform.isMacOS) {
    stderr.writeln('This project runs on macOS.');
    return 1;
  }
  final cwd = Directory.current.resolveSymbolicLinksSync();
  Directory('.local/run').createSync(recursive: true);
  final lock = File('.local/run/dev.lock').openSync(mode: FileMode.append);
  try {
    try {
      lock.lockSync(FileLock.exclusive);
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode != 35)
        rethrow; // EAGAIN: another launcher owns it.
      stdout.writeln('The app is already running or starting for $cwd.');
      return 0;
    }

    final apps = processes('comm')
        .where((row) => row.$2.split('/').last == 'spotify_flutter')
        .map((row) => row.$1)
        .toList();
    if (apps.isNotEmpty) {
      stdout.writeln(
        'spotify_flutter is already running (PID: ${apps.join(', ')}).',
      );
      return 0;
    }
    final flutterRun = RegExp(
      r'flutter_tools\.snapshot(?:\s+--\S+)*\s+run(?:\s|$)',
    );
    for (final (pid, command) in processes('command')) {
      if (!flutterRun.hasMatch(command)) continue;
      final directory = Process.runSync('/usr/sbin/lsof', [
        '-a',
        '-p',
        '$pid',
        '-d',
        'cwd',
        '-Fn',
      ]);
      if (const LineSplitter()
          .convert(directory.stdout as String)
          .contains('n$cwd')) {
        stdout.writeln('Flutter is already running for $cwd (PID: $pid).');
        return 0;
      }
    }

    final cancellation = CancellationToken();
    final signals = [ProcessSignal.sigint, ProcessSignal.sigterm]
        .map((signal) => signal.watch().listen((_) => cancellation.cancel()))
        .toList();
    try {
      stdout.writeln(
        'Starting Flutter in $cwd with hot reload (r reloads, R restarts, q quits).',
      );
      return await runFlutter(cwd, arguments, cancellation);
    } finally {
      for (final signal in signals) {
        await signal.cancel();
      }
    }
  } finally {
    // Keep the inode: deleting the file would let concurrent launchers lock different files.
    lock.closeSync();
  }
}

List<(int, String)> processes(String column) {
  final result = Process.runSync('/bin/ps', ['-axo', 'pid=,$column=']);
  if (result.exitCode != 0) {
    throw ProcessException(
      '/bin/ps',
      ['-axo', 'pid=,$column='],
      result.stderr as String,
      result.exitCode,
    );
  }
  final row = RegExp(r'^\s*(\d+)\s+(.+)$');
  return [
    for (final line in const LineSplitter().convert(result.stdout as String))
      if (row.firstMatch(line) case final match?)
        (int.parse(match.group(1)!), match.group(2)!),
  ];
}

Future<int> runFlutter(
  String cwd,
  List<String> arguments,
  CancellationToken cancellation,
) async {
  if (cancellation.isCancelled) return 0;
  final child = await Process.start(
    'flutter',
    ['run', '-d', 'macos', '--debug', '--hot', '--print-dtd', ...arguments],
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
  );
  try {
    return await child.exitCode.asCancellable(
      cancellation,
      onCancel: () {
        child.kill(ProcessSignal.sigint);
      },
    );
  } on CancelledException {
    // Reap the actual Flutter process before releasing the single-instance lock.
    return await child.exitCode;
  }
}
