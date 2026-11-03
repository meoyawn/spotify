import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'native_playplay_unwrap.dart';

Future<void> _musicKeyWarmUpLane = Future<void>.value();
Future<void>? _musicKeyWarmUp;
CancellationToken? _musicKeyWarmUpCancellation;
var _musicKeyRequested = false;

Future<Uint8List> _unwrapMusicKeyInIsolate(Uint8List obfuscated, CancellationToken? token) =>
    CancellableIsolate.run(() => NativePlayPlayUnwrap.unwrapContentKey(obfuscated), token);

/// A fresh Dart isolate keeps proprietary arithmetic off the Flutter/audio
/// event loop. Only obfuscated input and the16-byte result cross this boundary;
/// no session, native handles or request closures are captured. Cancellation
/// kills only this pure arithmetic isolate.
Future<Uint8List> unwrapNativePlayPlayMusicKey(Uint8List obfuscated, {CancellationToken? cancellationToken}) {
  cancellationToken?.throwIfCancelled();
  _musicKeyRequested = true;
  _musicKeyWarmUpCancellation?.cancel();
  return _unwrapMusicKeyInIsolate(obfuscated, cancellationToken);
}

/// Moves cold JIT work before playback using at most four fixed synthetic
/// inputs. Results are cleared here, never returned, admitted or cached. This
/// only warms CPU arithmetic; it cannot send a request or touch an account.
/// New real-key work cancels the running sample and remaining samples.
Future<void> warmNativePlayPlayMusicKeyWorker({CancellationToken? cancellationToken}) {
  cancellationToken?.throwIfCancelled();
  if (_musicKeyRequested) return Future<void>.value();
  final existing = _musicKeyWarmUp;
  if (existing != null) return existing;
  final cancellation = CancellationToken();
  _musicKeyWarmUpCancellation = cancellation;
  final token = MergedCancellationToken([cancellation, ?cancellationToken]);
  late final Future<void> pending;
  pending = _musicKeyWarmUpLane.then((_) async {
    try {
      for (var sample = 0; sample < 4; sample++) {
        token.throwIfCancelled();
        if (_musicKeyRequested) return;
        final input = Uint8List(16);
        for (var i = 0; i < input.length; i++) {
          input[i] = switch (sample) {
            0 => 0, 1 => i, 2 => 255 - i, _ => 0xa5,
          };
        }
        try {
          final key = await _unwrapMusicKeyInIsolate(input, token);
          key.fillRange(0, key.length, 0);
        } finally {
          input.fillRange(0, input.length, 0);
        }
      }
    } catch (_) {
      if (token.isCancelled) {
        if (identical(_musicKeyWarmUp, pending)) _musicKeyWarmUp = null;
        return;
      }
      if (identical(_musicKeyWarmUp, pending)) _musicKeyWarmUp = null;
      rethrow;
    }
  });
  _musicKeyWarmUp = pending;
  // Serialize warm-up generations even if hot reload cancels a running sample.
  // Its error still reaches the caller; a failed warm-up cannot poison a retry.
  _musicKeyWarmUpLane = pending.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  return pending;
}

/// Runtime shutdown/hot reload cancels queued and running warm-up arithmetic,
/// then permits a later warm-up with current Dart code.
/// This does not retain or wait for actual playback keys.
Future<void> stopNativePlayPlayMusicKeyWarmUp() {
  _musicKeyWarmUpCancellation?.cancel(); _musicKeyWarmUpCancellation = null;
  _musicKeyWarmUp = null;
  _musicKeyRequested = false;
  return _musicKeyWarmUpLane;
}
