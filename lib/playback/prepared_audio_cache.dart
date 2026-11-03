import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import 'audio_source.dart';

/// Retains successful online source leases inside one live account session.
/// No files are copied, imported or moved, and no license TTL is invented.
/// The session owner invalidates this cache on logout/session retirement; its
/// key also includes the current source-selection and account policy inputs.
class PreparedAudioCache {
  // A disk-file budget, not a resident audio buffer. PCM sources are larger
  // than compressed media, so retain several complete songs for quick replay.
  PreparedAudioCache({this.maximumBytes = 256 * 1024 * 1024});
  final int maximumBytes;
  final _entries = <String, _PreparedSource>{};
  final _pending = <String, SharedTask<_PreparedSource>>{};
  Map<String, int>? _acquisitions;
  int _bytes = 0;
  bool _closed = false;
  int hits = 0;

  Future<PreparedAudioFile> obtain(String key,
      Future<PreparedAudioFile> Function(CancellationToken) resolve, {String requestClass = 'foreground',
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final acquiring = _acquisitions ??= <String, int>{};
    acquiring[key] = (acquiring[key] ?? 0) + 1;
    try {
      return await _obtain(key, resolve, requestClass: requestClass, cancellationToken: cancellationToken);
    } finally {
      final remaining = acquiring[key]! - 1;
      if (remaining == 0) { acquiring.remove(key); }
      else { acquiring[key] = remaining; }
      await _trim();
    }
  }

  Future<PreparedAudioFile> _obtain(String key,
      Future<PreparedAudioFile> Function(CancellationToken) resolve, {required String requestClass,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_closed) throw StateError('Prepared audio session is closed');
    var entry = _entries.remove(key);
    if (entry != null && (!File(entry.source.path).existsSync() || entry.source.progress?.error != null ||
        entry.source.progress?.isComplete == false && entry.cancellation.isCancelled)) {
      _bytes -= entry.bytes;
      entry.retained = false;
      if (entry.readers == 0) await entry.source.close();
      entry = null;
    }
    if (entry != null) {
      hits++;
      _entries[key] = entry;
    } else {
      final jobKey = '$key|$requestClass';
      var task = _pending[jobKey];
      if (task == null || task.token.isCancelled) {
        task = SharedTask((token) => _build(key, jobKey, resolve, token));
        _pending[jobKey] = task;
      }
      entry = await task.wait(cancellationToken);
    }
    cancellationToken?.throwIfCancelled();
    if (_closed) throw StateError('Prepared audio session is closed');
    if (!entry.retained) throw entry.source.progress?.error ?? StateError('Prepared audio source was retired');
    entry.readers++;
    final owned = entry;
    final lease = PreparedAudioFile(path: owned.source.path, metadata: owned.source.metadata,
      encoding: owned.source.encoding, progress: owned.source.progress,
      release: () async {
        owned.readers--;
        if (!owned.retained && owned.readers == 0) await owned.source.close();
        await _trim();
      });
    _watchProgress(key, owned);
    try {
      await _trim();
      cancellationToken?.throwIfCancelled();
      return lease;
    } catch (_) { await lease.close(); rethrow; }
  }

  Future<_PreparedSource> _build(String key, String jobKey,
      Future<PreparedAudioFile> Function(CancellationToken) resolve, CancellationToken token) async {
    PreparedAudioFile? source;
    try {
      token.throwIfCancelled();
      source = await resolve(token);
      token.throwIfCancelled();
      if (_closed) throw StateError('Prepared audio session is closed');
      final existing = _entries[key];
      if (existing != null) return existing;
      if (source.progress?.error case final error?) throw error;
      final progress = source.progress;
      final size = progress != null && !progress.isComplete
        ? (progress.expectedBytes > progress.availableBytes ? progress.expectedBytes : progress.availableBytes)
        : await File(source.path).length();
      token.throwIfCancelled();
      if (_closed) throw StateError('Prepared audio session is closed');
      // A foreground/prefetch producer can win while the file stat is in
      // flight. Never overwrite its indexed source and lose its cleanup lease.
      final winner = _entries[key];
      if (winner != null) return winner;
      final entry = _PreparedSource(source, size, token);
      _entries[key] = entry;
      _bytes += size;
      _watchProgress(key, entry);
      source = null;
      return entry;
    } finally {
      if (identical(_pending[jobKey]?.token, token)) _pending.remove(jobKey);
      await source?.close();
    }
  }

  void _watchProgress(String key, _PreparedSource entry) {
    final progress = entry.source.progress;
    if (progress == null || entry.watching) return;
    entry.watching = true;
    unawaited(progress.completion.then<void>((_) async {
      if (!entry.retained || !identical(_entries[key], entry)) return;
      _bytes += progress.availableBytes - entry.bytes;
      entry.bytes = progress.availableBytes;
      await _trim();
    }, onError: (Object _, StackTrace __) async {
      if (identical(_entries[key], entry)) {
        _entries.remove(key);
        _bytes -= entry.bytes;
        entry.retained = false;
      }
      if (!entry.retained && entry.readers == 0) await entry.source.close();
    }));
  }

  Future<void> _trim() async {
    for (final key in _entries.keys.toList()) {
      if (!_closed && _bytes <= maximumBytes) break;
      final entry = _entries[key];
      if (entry == null) continue;
      if (entry.readers != 0) continue;
      if ((_acquisitions?[key] ?? 0) != 0) continue;
      _entries.remove(key);
      _bytes -= entry.bytes;
      entry.retained = false;
      entry.cancellation.cancel();
      await entry.source.close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final job in _pending.values) { job.token.cancel(); }
    _pending.clear();
    final entries = _entries.values.toList();
    _entries.clear();
    _bytes = 0;
    for (final entry in entries) {
      entry.retained = false;
      entry.cancellation.cancel();
      if (entry.readers == 0) await entry.source.close();
    }
  }
}

class _PreparedSource {
  _PreparedSource(this.source, this.bytes, this.cancellation);
  final PreparedAudioFile source;
  final CancellationToken cancellation;
  int bytes;
  int readers = 0;
  bool retained = true;
  bool watching = false;
}
