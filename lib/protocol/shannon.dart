// Adapted from shannon 0.2.0, Copyright (c) 2016 Paul Lietar.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import 'dart:typed_data';

/// Shannon stream encryption and plaintext authentication for AP packet bytes.
///
/// [nonce] starts a message with a big-endian 32-bit packet counter. Encrypt or
/// decrypt that message in any fragments, then call [finish] to obtain its MAC.
/// A new nonce restores the keyed state and discards partial message buffers.
/// This primitive neither allocates packet counters nor verifies received MACs.
///
/// Partial words follow the published C reference: authenticate a buffered word
/// once it is complete. The Rust 0.2.0 crate incorrectly authenticates it after
/// each continuation byte. See reverse-engineering/fixtures/shannon.json for independent
/// reference provenance, AP header split agreement and the crate discrepancy.
final class ShannonCipher {
  ShannonCipher(List<int> key) {
    for (final byte in key) {
      RangeError.checkValueInInterval(byte, 0, 255, 'key byte');
    }
    _register[0] = _register[1] = 1;
    for (var i = 2; i < _words; i++) {
      _register[i] = _register[i - 1] + _register[i - 2];
    }
    _loadKey(key);
    _constant = _register[0];
    _initial.setAll(0, _register);
  }

  static const _words = 16;
  static const _keyPosition = 13;
  static const _initialConstant = 0x6996c53a;
  static const _wordMask = 0xffffffff;

  final _register = Uint32List(_words);
  final _crc = Uint32List(_words);
  final _initial = Uint32List(_words);
  var _constant = _initialConstant;
  var _streamBuffer = 0;
  var _macBuffer = 0;
  var _bufferBits = 0;

  /// Uses exactly four nonce bytes in network order. The caller owns rollover.
  void nonce(int nonce32) {
    RangeError.checkValueInInterval(nonce32, 0, _wordMask, 'nonce32');
    _register.setAll(0, _initial);
    _constant = _initialConstant;
    _loadKey([
      nonce32 >>> 24, (nonce32 >>> 16) & 255,
      (nonce32 >>> 8) & 255, nonce32 & 255,
    ]);
    _constant = _register[0];
    _bufferBits = 0;
  }

  void encrypt(Uint8List bytes) => _process(bytes, decrypt: false);
  void decrypt(Uint8List bytes) => _process(bytes, decrypt: true);

  /// Finalizes this message and returns [length] MAC bytes (four for AP packets).
  /// Call [nonce] before processing a subsequent message.
  Uint8List finish({int length = 4}) {
    RangeError.checkNotNegative(length, 'length');
    final output = Uint8List(length);
    if (_bufferBits != 0) _macWord(_macBuffer);
    _cycle();
    _register[_keyPosition] ^= _initialConstant ^ (_bufferBits << 3);
    _bufferBits = 0;
    for (var i = 0; i < _words; i++) {
      _register[i] ^= _crc[i];
    }
    _diffuse();
    for (var offset = 0; offset < length; offset += 4) {
      _cycle();
      for (var byte = 0; byte < 4 && offset + byte < length; byte++) {
        output[offset + byte] = (_streamBuffer >>> (byte * 8)) & 255;
      }
    }
    return output;
  }

  void _process(Uint8List bytes, {required bool decrypt}) {
    var offset = 0;
    if (_bufferBits != 0) {
      while (_bufferBits != 0 && offset < bytes.length) {
        _partialByte(bytes, offset++, decrypt);
      }
      if (_bufferBits != 0) return;
      _macWord(_macBuffer);
    }
    final words = ByteData.sublistView(bytes);
    while (offset + 4 <= bytes.length) {
      _cycle();
      final word = words.getUint32(offset, Endian.little);
      final plaintext = decrypt ? word ^ _streamBuffer : word;
      _macWord(plaintext);
      words.setUint32(offset, decrypt ? plaintext : word ^ _streamBuffer, Endian.little);
      offset += 4;
    }
    if (offset < bytes.length) {
      _cycle();
      _macBuffer = 0;
      _bufferBits = 32;
      while (offset < bytes.length) {
        _partialByte(bytes, offset++, decrypt);
      }
    }
  }

  void _partialByte(Uint8List bytes, int offset, bool decrypt) {
    final shift = 32 - _bufferBits;
    final streamByte = (_streamBuffer >>> shift) & 255;
    final plaintext = decrypt ? bytes[offset] ^ streamByte : bytes[offset];
    _macBuffer ^= plaintext << shift;
    bytes[offset] = decrypt ? plaintext : plaintext ^ streamByte;
    _bufferBits -= 8;
  }

  void _loadKey(List<int> key) {
    for (var offset = 0; offset < key.length; offset += 4) {
      var word = 0;
      for (var byte = 0; byte < 4 && offset + byte < key.length; byte++) {
        word |= key[offset + byte] << (byte * 8);
      }
      _register[_keyPosition] ^= word;
      _cycle();
    }
    _register[_keyPosition] ^= key.length & _wordMask;
    _cycle();
    _crc.setAll(0, _register);
    _diffuse();
    for (var i = 0; i < _words; i++) {
      _register[i] ^= _crc[i];
    }
  }

  void _macWord(int word) {
    final next = _crc[0] ^ _crc[2] ^ _crc[15] ^ word;
    for (var i = 1; i < _words; i++) {
      _crc[i - 1] = _crc[i];
    }
    _crc[_words - 1] = next;
    _register[_keyPosition] ^= word;
  }

  void _diffuse() {
    for (var i = 0; i < _words; i++) { _cycle(); }
  }

  void _cycle() {
    var feedback = _register[12] ^ _register[13] ^ _constant;
    feedback = _sbox1(feedback) ^ _rotateLeft(_register[0], 1);
    for (var i = 1; i < _words; i++) {
      _register[i - 1] = _register[i];
    }
    _register[_words - 1] = feedback;
    final nonlinear = _sbox2(_register[2] ^ _register[15]);
    _register[0] ^= nonlinear;
    _streamBuffer = nonlinear ^ _register[8] ^ _register[12];
  }

  static int _rotateLeft(int word, int bits) =>
    ((word << bits) | (word >>> (32 - bits))) & _wordMask;

  static int _sbox1(int word) {
    word ^= _rotateLeft(word, 5) | _rotateLeft(word, 7);
    return word ^ (_rotateLeft(word, 19) | _rotateLeft(word, 22));
  }

  static int _sbox2(int word) {
    word ^= _rotateLeft(word, 7) | _rotateLeft(word, 22);
    return word ^ (_rotateLeft(word, 5) | _rotateLeft(word, 19));
  }
}
