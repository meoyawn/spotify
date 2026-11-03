import 'dart:math';
import 'dart:typed_data';

/// The standard random-byte boundary called by the original native generator.
/// A session may supply its standard entropy provider; the default stays in
/// this process and uses Dart's cryptographically secure random source.
typedef NativePlaybackIdEntropy = List<int> Function(int byteCount);

/// Original native track constructor 100e6ab9c preserves a supplied 16-byte ID;
/// otherwise 1019f74c8 requests 16 random bytes and returns them unchanged.
/// No UUID version/variant bits, textual prefix or timestamp are introduced.
/// Queue/load ownership decides when to create/reuse this value.
class NativePlaybackId {
  factory NativePlaybackId({List<int>? given, NativePlaybackIdEntropy? entropy}) {
    final value = given ?? (entropy ?? _secureBytes)(byteLength);
    if (value.length != byteLength || value.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('A native playback ID requires exactly 16 octets');
    }
    return NativePlaybackId._(Uint8List.fromList(value).asUnmodifiableView());
  }
  NativePlaybackId._(this.bytes);
  static const byteLength = 16;
  final Uint8List bytes;
}

Uint8List _secureBytes(int count) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
}
