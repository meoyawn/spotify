import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import 'generated/es_prefs.pb.dart' as proto;
import 'prefs_codec.dart';
import 'prefs_store.dart';

typedef PrefsFlushCancel = void Function();
/// The owning task runner must enqueue the callback asynchronously.
typedef PrefsFlushSchedule = PrefsFlushCancel Function(void Function() callback);

/// Native selectors compare a masked value; scopes are not any-bit filters.
class PrefsScope {
  const PrefsScope({required this.mask, required this.value});
  static const desktop = PrefsScope(mask: 0x1c, value: 4);
  static const authenticated = PrefsScope(mask: 0x1c, value: 8);
  final int mask, value;
  bool matches(int flags) => (flags & mask) == value;
}

/// Native prefs file ownership using an explicitly supplied app-owned path.
/// Await [open] before exposing the store to other callers. No account tier,
/// original profile path, helper process or remote service is consulted.
class PrefsPersistence {
  PrefsPersistence._(this.store, this.file, this.scope, this._schedule);
  static const readLimit = 0x100000;
  final PrefsStore store;
  final File file;
  final PrefsScope scope;
  final PrefsFlushSchedule _schedule;
  StreamSubscription<PrefsChange>? _subscription;
  PrefsFlushCancel? _cancelScheduled;
  Future<bool>? _flushing;
  bool _dirty = false;
  bool _closing = false;
  bool _closed = false;
  bool _loadSucceeded = false;
  int _generation = 0;
  int _attemptGeneration = 0;
  Object? _lastError;

  bool get dirty => _dirty;
  bool get loadSucceeded => _loadSucceeded;
  Object? get lastError => _lastError;

  static Future<PrefsPersistence> open({required PrefsStore store, required File file,
      required PrefsScope scope, PrefsFlushSchedule? schedule, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final owner = PrefsPersistence._(store, file, scope, schedule ?? _eventQueue);
    owner._loadSucceeded = await owner._load(cancellationToken);
    cancellationToken?.throwIfCancelled();
    owner._subscription = store.changes.listen(owner._onChange);
    return owner;
  }

  Future<bool> _load(CancellationToken? cancellationToken) async {
    RandomAccessFile? handle;
    try {
      cancellationToken?.throwIfCancelled();
      handle = await file.open();
      cancellationToken?.throwIfCancelled();
      final length = await handle.length();
      cancellationToken?.throwIfCancelled();
      if (length >= readLimit) {
        _lastError = FileSystemException('Preference file must be smaller than 1 MiB', file.path);
        return false;
      }
      final bytes = await handle.read(length);
      cancellationToken?.throwIfCancelled();
      if (bytes.length != length) {
        _lastError = FileSystemException('Preference file changed during read', file.path);
        return false;
      }
      final entries = PrefsCodec.decode(bytes).map((entry) => entry.toProtobuf()).toList();
      for (final entry in entries) {
        if (entry.value.whichValue() != proto.Value_Value.notSet) {
          store.register(entry.key, entry.value, flags: 0x100);
        }
      }
      _lastError = null;
      return true;
    } on FileSystemException catch (error) {
      _lastError = error;
      return false;
    } on FormatException catch (error) {
      // The raw codec retains arbitrary bytes; the protobuf bridge requires UTF-8.
      _lastError = error;
      return false;
    } finally {
      await _closeFile(handle);
    }
  }

  void _onChange(PrefsChange change) {
    if (_closed || !scope.matches(change.flags)) return;
    _generation++;
    _dirty = true;
    if (!_closing && _flushing == null) _enqueue();
  }

  void _enqueue() {
    if (_cancelScheduled != null || _closed || _closing) return;
    _cancelScheduled = _schedule(() {
      _cancelScheduled = null;
      unawaited(flush());
    });
  }

  /// Coalesces concurrent callers and writes newer mutations before completing.
  /// An I/O failure leaves dirty state available for an explicit or later retry.
  Future<bool> flush() {
    _cancelScheduled?.call();
    _cancelScheduled = null;
    if (_flushing != null) return _flushing!;
    if (!_dirty) return Future.value(true);
    final completion = Completer<bool>();
    _flushing = completion.future;
    unawaited(_writeUntilCurrent().then((success) {
      _flushing = null;
      completion.complete(success);
      if (!success && _generation != _attemptGeneration && !_closing && !_closed) _enqueue();
    }, onError: (Object error, StackTrace stack) {
      _flushing = null;
      completion.completeError(error, stack);
    }));
    return completion.future;
  }

  Future<bool> _writeUntilCurrent() async {
    while (_dirty) {
      final generation = _generation;
      _attemptGeneration = generation;
      final records = store.records().where((record) => scope.matches(record.flags)).toList();
      final bytes = PrefsCodec.encode(records.map((record) => PrefsDiskEntry.fromProtobuf(
        record.key, record.overrideValue ?? record.defaultValue, flags: record.flags)));
      final durable = records.any((record) => (record.flags & 0x1000) != 0);
      if (!await _replace(bytes, durable: durable)) return false;
      if (_generation == generation) _dirty = false;
    }
    return true;
  }

  Future<bool> _replace(List<int> bytes, {required bool durable}) async {
    RandomAccessFile? handle;
    final temporary = File('${file.path}.tmp');
    try {
      handle = await temporary.open(mode: FileMode.write);
      await handle.writeFrom(bytes);
      await _closeFile(handle);
      handle = null;
      await temporary.rename(file.path);
      if (durable) {
        RandomAccessFile? finalFile;
        try {
          finalFile = await file.open();
          await finalFile.flush();
        } on FileSystemException {
          // Native post-rename fsync is best effort and does not change success.
        } finally {
          await _closeFile(finalFile);
        }
      }
      _lastError = null;
      return true;
    } on FileSystemException catch (error) {
      _lastError = error;
      return false;
    } finally {
      await _closeFile(handle);
    }
  }

  /// Cancels queued work, drains current mutations, and releases its listener.
  /// The store remains owned by its caller. Failed writes are reported as false.
  Future<bool> close() async {
    if (_closed) return !_dirty;
    _closing = true;
    _cancelScheduled?.call();
    _cancelScheduled = null;
    bool success;
    do {
      success = await flush();
    } while (success && _dirty);
    _closed = true;
    await _subscription?.cancel();
    return success;
  }
}

PrefsFlushCancel _eventQueue(void Function() callback) {
  final timer = Timer(Duration.zero, callback);
  return timer.cancel;
}

Future<void> _closeFile(RandomAccessFile? file) async {
  try {
    await file?.close();
  } on FileSystemException {
    // Native close status is ignored by both read and write helpers.
  }
}
