import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'package:pointycastle/block/aes.dart' show AESEngine;
import 'package:pointycastle/stream/ctr.dart' show CTRStreamCipher;

import 'common_crypto_aes_ctr.dart';

/// Spotify file framing from librespot audio/src/decrypt.rs and
/// playback/src/player.rs (reference revision 99b6088bf3ea028f90192676ac1a337fa4b2ed12).
/// CommonCrypto supplies macOS AES-128/CTR; PointyCastle is the other-platform
/// fallback. Both use the same full big-endian 128-bit counter and framing.
/// The caller must obtain an authorized key and enforce playback entitlements;
/// this component performs no key acquisition or network operation.
class SpotifyAudioDecryptor {
  SpotifyAudioDecryptor.encrypted(List<int> key) : _key = _validatedKey(key);
  const SpotifyAudioDecryptor.unencrypted() : _key = null;

  final Uint8List? _key;
  static final BigInt _initialCounter = BigInt.parse('72e067fbddcbcf77ebe8bc643f630d93', radix: 16);
  static const int _spotifyOggHeaderLength = 0xa7;

  /// [byteOffset] is the absolute offset in the original encrypted file, before
  /// any Ogg header removal. Each call has independent cipher/stream state.
  ///
  /// Set [spotifyOgg] only for a Spotify Ogg source: decrypted absolute bytes
  /// 0..166 are then omitted, including when a range begins inside that header.
  /// A finite range need not start or end on an AES block boundary. Stream
  /// errors/cancellation and backpressure retain ordinary Dart stream behavior.
  Stream<Uint8List> transform(Stream<List<int>> source, {int byteOffset = 0,
    bool spotifyOgg = false}) {
    if (byteOffset < 0) throw RangeError.value(byteOffset, 'byteOffset', 'Must be nonnegative');
    final key = _key;
    Uint8List? iv;
    if (key != null) {
      var counter = _initialCounter + BigInt.from(byteOffset ~/ 16);
      if (counter.bitLength > 128) throw RangeError.value(byteOffset, 'byteOffset', 'AES counter overflow');
      iv = Uint8List(16);
      for (var i = 15; i >= 0; i--) { iv[i] = (counter & BigInt.from(255)).toInt(); counter >>= 8; }
    }
    final skip = spotifyOgg && byteOffset < _spotifyOggHeaderLength
      ? _spotifyOggHeaderLength - byteOffset : 0;
    return _transform(source, key, iv, byteOffset % 16, skip);
  }

  Stream<Uint8List> _transform(Stream<List<int>> source, Uint8List? key,
    Uint8List? iv, int discard, int skip) async* {
    CommonCryptoAesCtr? native;
    CTRStreamCipher? cipher;
    try {
      // Allocate only when listened to, so an unused transform never owns a
      // native handle. Each subscription/call owns a separate cipher context.
      if (key != null) {
        if (Platform.isMacOS) { native = CommonCryptoAesCtr(key: key, iv: iv!); }
        else { cipher = CTRStreamCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(key), iv!)); }
        if (discard != 0) {
          final padding = Uint8List(discard);
          final ignored = native?.process(padding) ?? cipher!.process(padding);
          ignored.fillRange(0, ignored.length, 0);
        }
      }
      await for (final chunk in source) {
        final input = _validatedBytes(chunk);
        final output = native?.process(input) ?? cipher?.process(input) ?? Uint8List.fromList(input);
        if (skip >= output.length) { skip -= output.length; continue; }
        if (skip > 0) {
          yield Uint8List.sublistView(output, skip);
          skip = 0;
        } else if (output.isNotEmpty) {
          yield output;
        }
      }
    } finally {
      native?.close();
      if (iv != null) iv.fillRange(0, iv.length, 0);
    }
  }
}

Uint8List _validatedKey(List<int> key) {
  if (key.length != 16) throw ArgumentError.value(key.length, 'key.length', 'An authorized 16-byte audio key is required');
  return Uint8List.fromList(_validatedBytes(key)).asUnmodifiableView();
}

Uint8List _validatedBytes(List<int> bytes) {
  if (bytes is Uint8List) return bytes;
  for (final value in bytes) {
    if (value < 0 || value > 255) throw ArgumentError.value(value, 'byte', 'Must be an octet');
  }
  return Uint8List.fromList(bytes);
}
