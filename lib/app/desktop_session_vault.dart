import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:cancellation_token/cancellation_token.dart';

/// Session bytes belong only to this app's private Application Support tree.
/// The directory is owner-only (0700), each file is owner-only (0600), and
/// replacement is atomic. No Keychain or original Spotify profile is queried.
class DesktopSessionVault {
  const DesktopSessionVault({required this.directory});
  final Directory directory;
  static const _readLimit = 1024 * 1024;
  File get _file => File('${directory.path}/session.json');

  Future<bool> _secureDirectory({bool create = false, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    var type = await FileSystemEntity.type(directory.path, followLinks: false);
    cancellationToken?.throwIfCancelled();
    if (type == FileSystemEntityType.notFound) {
      if (!create) return false;
      await directory.create(recursive: true);
      cancellationToken?.throwIfCancelled();
      type = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException('Session storage must be an app-owned directory', directory.path);
    }
    cancellationToken?.throwIfCancelled();
    _restrictAccess(directory.path, 0x1c0); //0700
    return true;
  }

  Future<Uint8List?> read({CancellationToken? cancellationToken}) async {
    if (!await _secureDirectory(cancellationToken: cancellationToken)) return null;
    final file = _file;
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    cancellationToken?.throwIfCancelled();
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Session storage must be a regular file', file.path);
    }
    _restrictAccess(file.path, 0x180); //0600
    final input = await file.open();
    try {
      cancellationToken?.throwIfCancelled();
      final length = await input.length();
      cancellationToken?.throwIfCancelled();
      if (length <= 0 || length > _readLimit) throw const FormatException('Invalid saved session length');
      final bytes = await input.read(length);
      if (cancellationToken?.isCancelled == true) {
        bytes.fillRange(0, bytes.length, 0); cancellationToken!.throwIfCancelled();
      }
      if (bytes.length != length) throw const FormatException('Saved session was incomplete');
      return bytes;
    } finally { await input.close(); }
  }

  Future<void> write(Uint8List data, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (data.isEmpty || data.length > _readLimit) throw const FormatException('Invalid session length');
    final snapshot = Uint8List.fromList(data);
    Directory? pending;
    RandomAccessFile? output;
    try {
      await _secureDirectory(create: true, cancellationToken: cancellationToken);
      cancellationToken?.throwIfCancelled();
      pending = await directory.createTemp('session-write-');
      cancellationToken?.throwIfCancelled();
      _restrictAccess(pending.path, 0x1c0);
      final temporary = await File('${pending.path}/session.json').create();
      cancellationToken?.throwIfCancelled();
      _restrictAccess(temporary.path, 0x180);
      output = await temporary.open(mode: FileMode.write);
      cancellationToken?.throwIfCancelled();
      await output.writeFrom(snapshot);
      cancellationToken?.throwIfCancelled();
      await output.flush();
      await output.close(); output = null;
      cancellationToken?.throwIfCancelled();
      await temporary.rename(_file.path);
    } finally {
      snapshot.fillRange(0, snapshot.length, 0);
      try { await output?.close(); }
      finally { if (pending != null && await pending.exists()) await pending.delete(recursive: true); }
    }
  }

  Future<void> delete() async {
    if (!await _secureDirectory()) return;
    final file = _file;
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException('Session storage must be a regular file', file.path);
    }
    await file.delete();
  }
}

typedef _ChmodNative = Int32 Function(Pointer<Utf8>, Uint16);
typedef _ChmodDart = int Function(Pointer<Utf8>, int);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();
final _libc = DynamicLibrary.process();
final _chmod = _libc.lookupFunction<_ChmodNative, _ChmodDart>('chmod');
final _errno = _libc.lookupFunction<_ErrnoNative, _ErrnoDart>(Platform.isMacOS ? '__error' : '__errno_location');

void _restrictAccess(String path, int mode) {
  final value = path.toNativeUtf8();
  try {
    if (_chmod(value, mode) != 0) {
      throw FileSystemException('Could not secure app-owned session storage', path,
        OSError('chmod failed', _errno().value));
    }
  } finally { calloc.free(value); }
}
