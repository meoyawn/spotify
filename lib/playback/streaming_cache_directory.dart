import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

/// Main-isolate streaming ownership. Decoder workers never open root owners.
/// The process guard complements the OS advisory lock, which is process-wide
/// on macOS rather than exclusive between two handles in the same process.
final _ownedStreamingRoots = <String>{};

class StreamingCacheDirectory {
  StreamingCacheDirectory._(this.root, this.directory, this.lock,
    CancellationToken? cancellationToken)
    : cancellation = MergedCancellationToken([?cancellationToken]);
  final Directory root, directory;
  final RandomAccessFile lock;
  final CancellationToken cancellation;
  int references = 1;
  bool retired = false;
  int removedDirectories = 0, cleanupFailures = 0;
  Future<void>? reconciliation, closing;
}

/// Open before exposing a runtime or starting any source in this root. Files
/// from preceding processes have no live index/leases in this application.
Future<StreamingCacheDirectory> openStreamingCacheDirectory(Directory root,
    {CancellationToken? cancellationToken}) async {
  cancellationToken?.throwIfCancelled();
  await root.create(recursive: true);
  cancellationToken?.throwIfCancelled();
  final canonical = Directory(await root.resolveSymbolicLinks());
  cancellationToken?.throwIfCancelled();
  if (!_ownedStreamingRoots.add(canonical.path)) {
    throw StateError('Streaming buffers already have an owner');
  }
  RandomAccessFile? lock;
  Directory? working;
  try {
    lock = await File('${canonical.path}/.streaming-owner.lock').open(mode: FileMode.append);
    cancellationToken?.throwIfCancelled();
    // Nonblocking: never wait for or interfere with another app process.
    await lock.lock(FileLock.exclusive);
    cancellationToken?.throwIfCancelled();
    working = await canonical.createTemp('spotify-stream-session-');
    cancellationToken?.throwIfCancelled();
    final owner = StreamingCacheDirectory._(canonical, working, lock, cancellationToken);
    owner.reconciliation = _reconcileStreamingDirectory(owner);
    return owner;
  } catch (_) {
    try { if (working != null) await working.delete(recursive: true); }
    on FileSystemException { /* The next root reconciliation can reclaim it. */ }
    finally {
      try { await lock?.close(); }
      finally { _ownedStreamingRoots.remove(canonical.path); }
    }
    rethrow;
  }
}

Future<void> _reconcileStreamingDirectory(StreamingCacheDirectory owner) async {
  final token = owner.cancellation;
  try {
    // Reconcile once away from foreground startup, without an idle polling
    // loop. Original presence/ownership decisions are recorded separately.
    await CancellableFuture.delayed<void>(const Duration(seconds: 10), token);
    token.throwIfCancelled();
    await for (final entity in owner.root.list(followLinks: false)) {
      token.throwIfCancelled();
      if (entity is! Directory || entity.path == owner.directory.path) continue;
      final name = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (name.startsWith('spotify-stream-session-') || name.startsWith('spotify-audio-') ||
          name.startsWith('spotify-pcm-stream-') || name.startsWith('spotify-pcm-')) {
        await _removeStreamingOrphan(owner, entity);
      } else if (name == 'buffers') {
        // Legacy encrypted pools used this parent. Preserve unrelated names.
        await for (final child in entity.list(followLinks: false)) {
          token.throwIfCancelled();
          if (child is Directory && child.uri.pathSegments.where((part) => part.isNotEmpty)
              .last.startsWith('media-session-')) {
            await _removeStreamingOrphan(owner, child);
          }
        }
      }
    }
  } catch (_) {
    if (!token.isCancelled) owner.cleanupFailures++;
  }
}

Future<void> _removeStreamingOrphan(StreamingCacheDirectory owner, Directory directory) async {
  owner.cancellation.throwIfCancelled();
  try {
    // Standard recursive deletion does not follow links. Once dispatched it
    // settles under this owner before the root lock can be released.
    await directory.delete(recursive: true);
    owner.removedDirectories++;
  } on FileSystemException { owner.cleanupFailures++; }
  owner.cancellation.throwIfCancelled();
}

void retainStreamingCacheDirectory(StreamingCacheDirectory owner) {
  if (owner.retired || owner.closing != null) throw StateError('Streaming buffer owner is retired');
  owner.references++;
}

Future<void> releaseStreamingCacheDirectory(StreamingCacheDirectory owner) async {
  owner.references--;
  if (owner.references < 0) throw StateError('Streaming buffer ownership is unbalanced');
  if (owner.references != 0 || !owner.retired) return;
  await (owner.closing ??= _closeStreamingCacheDirectory(owner));
}

Future<void> retireStreamingCacheDirectory(StreamingCacheDirectory? owner) async {
  if (owner == null || owner.retired) return;
  owner.retired = true;
  owner.cancellation.cancel();
  await releaseStreamingCacheDirectory(owner);
}

Future<void> _closeStreamingCacheDirectory(StreamingCacheDirectory owner) async {
  try {
    await owner.reconciliation;
    try { await owner.directory.delete(recursive: true); }
    on FileSystemException { owner.cleanupFailures++; }
  } finally {
    try { await owner.lock.close(); }
    finally { _ownedStreamingRoots.remove(owner.root.path); }
  }
}
