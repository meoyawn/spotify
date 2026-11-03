import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:pointycastle/stream/ctr.dart' show CTRStreamCipher;

/// Raw framing shared by native 0x101c6ee2c/0x101c6f224 callers. Key selection,
/// protobuf and any outer Base64 representation belong to the individual owner.
class NativeStorageFraming {
  NativeStorageFraming({Random? random}) : _random = random ?? Random.secure();
  final Random _random;

  Uint8List encrypt(List<int> key, List<int> plaintext) {
    final iv = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
    final ciphertext = _crypt(key, iv, plaintext);
    final mac = Hmac(sha1, _derive(key, 'checksum')).convert(ciphertext).bytes;
    return (BytesBuilder(copy: false)..add(iv)..add(ciphertext)..add(mac)).takeBytes();
  }

  Uint8List? decrypt(List<int> key, List<int> bytes) {
    if (bytes.length < 36) return null;
    final frame = Uint8List.fromList(bytes);
    final ciphertext = Uint8List.sublistView(frame, 16, frame.length - 20);
    final mac = Hmac(sha1, _derive(key, 'checksum')).convert(ciphertext).bytes;
    var mismatch = 0;
    for (var i = 0; i < 20; i++) { mismatch |= mac[i] ^ frame[frame.length - 20 + i]; }
    if (mismatch != 0) return null;
    return _crypt(key, Uint8List.sublistView(frame, 0, 16), ciphertext);
  }
}

List<int> _derive(List<int> key, String label) => Hmac(sha1, key).convert(ascii.encode(label)).bytes;

Uint8List _crypt(List<int> key, Uint8List iv, List<int> input) {
  final cipher = CTRStreamCipher(AESEngine())..init(true,
    ParametersWithIV(KeyParameter(Uint8List.fromList(_derive(key, 'encryption').sublist(0, 16))), iv));
  return cipher.process(Uint8List.fromList(input));
}
