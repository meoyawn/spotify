import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Original AP loop 0x101904a3c. This variant seeds its counters with a keyed
/// transcript and compares a server target; Login5 uses a different variant.
Uint8List solveNativeApHashcashSync({required List<int> clientHello,
    required List<int> serverResponse, required List<int> prefix,
    required int difficulty, required int target}) {
  RangeError.checkValueInInterval(difficulty, 0, 255, 'difficulty');
  RangeError.checkValueInInterval(target, 0, 0xffffffff, 'target');
  final seed = Hmac(sha1, _seedKey).convert([...clientHello, ...serverResponse]).bytes;
  final message = Uint8List(prefix.length + 16)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length, prefix.length + 8, seed);
  final mask = (1 << (difficulty & 31)) - 1;
  while (true) {
    final digest = sha1.convert(message).bytes;
    final tail = ByteData.sublistView(Uint8List.fromList(digest)).getUint32(16, Endian.big);
    if (((tail ^ target) & mask) == 0) {
      return Uint8List.fromList(message.sublist(prefix.length)).asUnmodifiableView();
    }
    // The original increments both big-endian uint64 words independently.
    for (final start in [prefix.length, prefix.length + 8]) {
      for (var i = start + 7; i >= start; i--) {
        final value = message[i] + 1;
        message[i] = value;
        if (value <= 255) break;
      }
    }
  }
}

/// Keep CPU work in the application's process without blocking Flutter frames.
Future<Uint8List> solveNativeApHashcash({required List<int> clientHello,
    required List<int> serverResponse, required List<int> prefix,
    required int difficulty, required int target}) => Isolate.run(() =>
  solveNativeApHashcashSync(clientHello: clientHello, serverResponse: serverResponse,
    prefix: prefix, difficulty: difficulty, target: target));

// Exact 20-byte constant at original VA 0x1022a8620, also captured by the
// unchanged native-loop oracle in reverse-engineering/fixtures/native-ap-hashcash.json.
const _seedKey = <int>[0xa3, 0xad, 0xb1, 0x31, 0xab, 0x58, 0x45, 0x07, 0xcb, 0x7a,
  0x68, 0xae, 0xe1, 0xa5, 0xf9, 0x0b, 0x4d, 0x7f, 0x07, 0x11];
