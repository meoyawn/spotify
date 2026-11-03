import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

/// Session-owned encrypted streaming buffers. File IDs identify the selected
/// bytes; signed CDN URLs and their expiring query strings are not cache keys.
/// A cache hit supplies bytes only: the caller still obtains a current license.
class SpotifyMediaCache {
  SpotifyMediaCache._(this.directory, this.maximumBytes, [this._cancellation]);
  final Directory directory;
  // This is our resource budget, not a claimed original expiry/LRU policy.
  final int maximumBytes;
  final _entries = <String, _CachedMedia>{};
  final _writers = <Future<void>>{};
  Set<String>? _fills;
  CancellationToken? _cancellation;
  CancellationToken get _lifetime => _cancellation ??= CancellationToken();
  int _reservedBytes = 0, _fileSerial = 0;
  int _bytes = 0;
  bool _closed = false;
  Future<void>? _closing, _trimming;
  int cleanupFailures = 0;

  static Future<SpotifyMediaCache> open(Directory parent,
      {int maximumBytes = 128 * 1024 * 1024, CancellationToken? cancellationToken}) async {
    if (maximumBytes <= 0) throw RangeError.value(maximumBytes, 'maximumBytes');
    cancellationToken?.throwIfCancelled();
    await parent.create(recursive: true);
    cancellationToken?.throwIfCancelled();
    final directory = await parent.createTemp('media-session-');
    try {
      cancellationToken?.throwIfCancelled();
      return SpotifyMediaCache._(directory, maximumBytes,
        MergedCancellationToken([?cancellationToken]));
    } catch (_) {
      try { await directory.delete(); }
      on FileSystemException { /* The enclosing streaming directory owns it. */ }
      rethrow;
    }
  }

  Future<SpotifyCachedAudio?> read(List<int> fileId, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (_closed) return null;
    // Original normal-source admission skips the all-zero20-byte identity.
    final key = _key(fileId);
    if (key == '0000000000000000000000000000000000000000') return null;
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    entry.readers++;
    var valid = false;
    try { valid = await entry.file.length() == entry.length; }
    on FileSystemException { /* Missing or incomplete buffers are cache misses. */ }
    if (!valid) {
      _forget(key, entry);
      await _release(entry);
      cancellationToken?.throwIfCancelled();
      return null;
    }
    if (_closed || cancellationToken?.isCancelled == true) {
      await _release(entry);
      cancellationToken?.throwIfCancelled();
      return null;
    }
    return SpotifyCachedAudio._(entry.file, entry.length, () => _release(entry));
  }

  /// Cache failures do not interrupt or repeat a successful media download.
  Stream<List<int>> capture(List<int> fileId, Stream<List<int>> input,
      {required int length, CancellationToken? cancellationToken}) async* {
    cancellationToken?.throwIfCancelled();
    final key = _key(fileId);
    final fills = _fills ??= <String>{};
    if (_closed || length <= 0 || length > maximumBytes || _entries.containsKey(key) ||
        key == '0000000000000000000000000000000000000000' || !fills.add(key)) {
      yield* input;
      return;
    }
    // Reserve before the first await: a second fill cannot duplicate the
    // selected file or claim bytes already promised to a pending writer.
    _reservedBytes += length;
    final token = MergedCancellationToken([_lifetime, ?cancellationToken]);
    final finished = Completer<void>();
    _writers.add(finished.future);
    File? file;
    RandomAccessFile? output;
    StreamIterator<List<int>>? reader;
    Future<void>? readerCancellation;
    Future<void> cancelInput() {
      final current = reader;
      if (current == null) return Future<void>.value();
      final pending = readerCancellation ??= current.cancel();
      pending.ignore();
      return pending;
    }
    var failed = false, complete = false, received = 0, tracked = true;
    try {
      await _trim();
      token.throwIfCancelled();
      if (_bytes + _reservedBytes > maximumBytes) {
        _reservedBytes -= length;
        fills.remove(key);
        _writers.remove(finished.future);
        finished.complete();
        tracked = false;
        yield* input;
        return;
      }
      try {
        file = File('${directory.path}/$key-${++_fileSerial}.buffer');
        output = await file.open(mode: FileMode.write);
      } on FileSystemException { failed = true; }
      token.throwIfCancelled();
      reader = StreamIterator(input);
      while (true) {
        token.throwIfCancelled();
        if (!await reader.moveNext().asCancellable(token,
            onCancel: () { unawaited(cancelInput()); })) { break; }
        final chunk = reader.current;
        received += chunk.length;
        // Invalid length cannot grow a cache file beyond its reservation.
        if (received > length) failed = true;
        if (!failed) {
          // Await each bounded write rather than queuing an entire song in
          // an IOSink when the disk is slower than the source stream.
          try { await output?.writeFrom(chunk); }
          on FileSystemException { failed = true; }
        }
        token.throwIfCancelled();
        yield chunk;
      }
      complete = received == length;
    } finally {
      if (tracked) {
        try {
          try { await cancelInput(); }
          finally {
            try { await output?.close(); }
            on FileSystemException { failed = true; }
          }
        } finally {
          // Move the reservation to physical-file accounting before any
          // await. Removed or failed files stay charged until deletion ends.
          _reservedBytes -= length;
          try {
            if (file != null) {
              final entry = _CachedMedia(file, length, key: key);
              _bytes += length;
              if (complete && !failed && !_closed && !token.isCancelled && !_entries.containsKey(key)) {
                _entries[key] = entry;
                await _trim();
              } else { await _discard(entry); }
            }
          } finally {
            fills.remove(key);
            _writers.remove(finished.future);
            finished.complete();
            await _removeEmptyDirectory();
          }
        }
      }
    }
  }

  void _forget(String key, _CachedMedia entry) {
    if (identical(_entries[key], entry)) _entries.remove(key);
    entry.removed = true;
  }

  Future<void> _release(_CachedMedia entry) async {
    entry.readers--;
    if (entry.readers == 0 && (entry.removed || _closed)) {
      // A close can overlap a reader's stat/open handoff. It cannot unlink
      // the file until that last reader has released its lease.
      final key = entry.key ?? _entries.entries.where((item) => identical(item.value, entry)).firstOrNull?.key;
      if (key != null) _forget(key, entry);
      await _discard(entry);
    }
    await _trim();
    await _removeEmptyDirectory();
  }

  Future<void> _trim() async {
    // Join an earlier delete before choosing more victims. Concurrent
    // admissions must not evict extra files against stale charged bytes.
    final pending = _trimming;
    if (pending != null) await pending;
    await (_trimming ??= _trimEntries().whenComplete(() { _trimming = null; }));
  }

  Future<void> _trimEntries() async {
    for (final key in _entries.keys.toList()) {
      if (!_closed && _bytes + _reservedBytes <= maximumBytes) break;
      final entry = _entries[key];
      if (entry == null || entry.readers != 0) continue;
      _forget(key, entry);
      await _discard(entry);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _lifetime.cancel();
    await Future.wait(_writers.toList());
    await _trim();
    await _removeEmptyDirectory();
  }

  Future<void> _removeEmptyDirectory() async {
    if (!_closed || _entries.isNotEmpty || _writers.isNotEmpty || _bytes != 0) return;
    try { await directory.delete(); }
    on FileSystemException { /* A leased or incomplete file may still exist. */ }
  }

  Future<void> _discard(_CachedMedia entry) => entry.removing ??= _deleteCharged(entry);

  Future<void> _deleteCharged(_CachedMedia entry) async {
    try { await entry.file.delete(); }
    on FileSystemException {
      try {
        if (await FileSystemEntity.type(entry.file.path, followLinks: false) == FileSystemEntityType.notFound) {
          _bytes -= entry.length;
          return;
        }
      } on FileSystemException { /* An inaccessible file remains charged. */ }
      // Fail closed for cache admission. Startup reconciliation owns this
      // abandoned file; forgetting its bytes could allow unbounded growth.
      cleanupFailures++;
      return;
    }
    _bytes -= entry.length;
  }

  static String _key(List<int> bytes) {
    if (bytes.length != 20 || bytes.any((value) => value < 0 || value > 255)) {
      throw ArgumentError('An audio file ID must contain 20 octets');
    }
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

class _CachedMedia {
  _CachedMedia(this.file, this.length, {this.key});
  final File file;
  final int length;
  final String? key;
  int readers = 0;
  bool removed = false;
  Future<void>? removing;
}

final class SpotifyCachedAudio {
  SpotifyCachedAudio._(this.file, this.length, this._release);
  final File file;
  final int length;
  final Future<void> Function() _release;
  Future<void>? _closing;
  Stream<List<int>> openRead() => file.openRead();
  Future<void> close() => _closing ??= _release();
}
