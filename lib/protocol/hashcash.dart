import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class HashcashSolution {
  HashcashSolution(List<int> suffix, this.trials, this.elapsed, {int? elapsedNanoseconds})
    : suffix = Uint8List.fromList(suffix).asUnmodifiableView(),
      elapsedNanoseconds = elapsedNanoseconds ?? elapsed.inMicroseconds * 1000;
  final Uint8List suffix;
  final int trials;
  final Duration elapsed;
  /// The solver measures this directly from ticks or the supplied ns clock.
  /// Legacy hand-constructed solutions retain their Duration precision unless
  /// their owner supplies this exact value.
  final int elapsedNanoseconds;
  String get suffixHex => suffix.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

/// Port of original native loop 0x1017cd170. SHA-1 is provided by package:crypto.
HashcashSolution solveHashcashSync({required List<int> prefix, required int difficulty,
    List<int> context = const [], int Function()? nowNanoseconds}) {
  final seed = sha1.convert(context).bytes;
  final message = Uint8List(prefix.length + 16)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length, prefix.length + 8, seed, 12);
  final bytes = ByteData.sublistView(message);
  final mask = (1 << (difficulty & 31)) - 1;
  var trials = 0;
  final clock = nowNanoseconds == null ? (Stopwatch()..start()) : null;
  final startedNanoseconds = nowNanoseconds?.call();
  while (true) {
    final digest = sha1.convert(message).bytes;
    final tail = digest[16] << 24 | digest[17] << 16 | digest[18] << 8 | digest[19];
    trials++;
    if ((tail & mask) == 0) {
      clock?.stop();
      final elapsedNanoseconds = nowNanoseconds == null
        ? (BigInt.from(clock!.elapsedTicks) * BigInt.from(1000000000) ~/ BigInt.from(clock.frequency)).toInt()
        : (nowNanoseconds() - startedNanoseconds!).toSigned(64);
      return HashcashSolution(message.sublist(prefix.length), trials,
        clock?.elapsed ?? Duration(microseconds: elapsedNanoseconds ~/ 1000),
        elapsedNanoseconds: elapsedNanoseconds);
    }
    // Both big-endian words increment independently, including 64-bit wrap.
    for (final start in [prefix.length, prefix.length + 8]) {
      for (var i = start + 7; i >= start; i--) {
        final next = bytes.getUint8(i) + 1;
        bytes.setUint8(i, next);
        if (next <= 255) {
          break;
        }
      }
    }
  }
}

/// The CPU work remains in this process and does not block Flutter's UI isolate.
Future<HashcashSolution> solveHashcash({required List<int> prefix, required int difficulty,
    List<int> context = const []}) => Isolate.run(() => solveHashcashSync(
      prefix: prefix, difficulty: difficulty, context: context));
