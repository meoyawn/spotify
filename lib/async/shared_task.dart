import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';

/// One computation with independently cancellable readers. The last reader
/// abandoning an unfinished task cancels its actual work through [token].
class SharedTask<T> {
  SharedTask(Future<T> Function(CancellationToken) run, {FutureOr<void> Function(T)? onAbandoned}) {
    _result = Future<T>.microtask(() { token.throwIfCancelled(); return run(token); }).then((value) async {
      try {
        if (token.isCancelled) { await onAbandoned?.call(value); token.throwIfCancelled(); }
        return value;
      } finally { isComplete = true; }
    }, onError: (Object error, StackTrace stack) {
      isComplete = true;
      Error.throwWithStackTrace(error, stack);
    });
  }

  final token = CancellationToken();
  late final Future<T> _result;
  var isComplete = false;
  var _readers = 0;

  /// Allows an owner's sequencing lane to join cleanup without retaining a reader.
  Future<T> get completion => _result;

  Future<T> wait(CancellationToken? cancellationToken) async {
    cancellationToken?.throwIfCancelled();
    _readers++;
    try { return await _result.asCancellable(cancellationToken); }
    finally {
      _readers--;
      if (_readers == 0 && !isComplete) token.cancel();
    }
  }
}
