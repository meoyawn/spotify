import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';

/// Attaches resource cleanup to a package token and detaches on completion.
/// [signal] is only a bridge for standard APIs requiring an abort Future.
class CancellationRegistration with Cancellable {
  CancellationRegistration(CancellationToken? token, {void Function(Exception)? onCancel})
      : _onCancel = onCancel { maybeAttach(token); }

  void Function(Exception)? _onCancel;
  Completer<void>? _signal;

  Future<void> get signal => isCancelled ? Future<void>.value()
    : (_signal ??= Completer<void>()).future;

  @override
  void onCancel(Exception cancelException) {
    super.onCancel(cancelException);
    final callback = _onCancel;
    _onCancel = null;
    final signal = _signal;
    if (signal != null && !signal.isCompleted) signal.complete();
    callback?.call(cancelException);
  }

  void dispose() { _onCancel = null; detach(); }
}
