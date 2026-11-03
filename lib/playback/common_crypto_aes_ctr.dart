import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Int32 Function(Uint32, Uint32, Uint32, Uint32,
  Pointer<Void>, Pointer<Void>, Size, Pointer<Void>, Size, Int32, Uint32,
  Pointer<Pointer<Void>>);
typedef _Create = int Function(int, int, int, int, Pointer<Void>, Pointer<Void>,
  int, Pointer<Void>, int, int, int, Pointer<Pointer<Void>>);
typedef _UpdateNative = Int32 Function(Pointer<Void>, Pointer<Void>, Size,
  Pointer<Void>, Size, Pointer<Size>);
typedef _Update = int Function(Pointer<Void>, Pointer<Void>, int,
  Pointer<Void>, int, Pointer<Size>);
typedef _ReleaseNative = Int32 Function(Pointer<Void>);
typedef _Release = int Function(Pointer<Void>);

/// macOS's public CommonCrypto AES-128 CTR primitive, with a full big-endian
/// 128-bit counter. The caller owns stream/framing and must close this context.
///
/// ABI/constants: SDK CommonCrypto/CommonCryptor.h + CommonCryptoError.h.
/// CommonCrypto delegates CTR to corecrypto's low-64-bit counter; recreating at
/// that boundary preserves carry into the full supplied 128-bit IV:
/// https://github.com/apple/corecrypto/blob/main/ccmode/src/ccmode_ctr_crypt.c
/// No standard cryptographic implementation is copied or decompiled here.
class CommonCryptoAesCtr {
  factory CommonCryptoAesCtr({required Uint8List key, required Uint8List iv}) {
    if (key.length != 16 || iv.length != 16) {
      throw ArgumentError('AES-128 CTR requires a 16-byte key and IV');
    }
    var counter = BigInt.zero;
    for (final byte in iv) { counter = (counter << 8) | BigInt.from(byte); }
    final cipher = CommonCryptoAesCtr._(_CommonCrypto.instance, Uint8List.fromList(key), counter);
    try {
      cipher._create();
      return cipher;
    } catch (_) {
      cipher.close();
      rethrow;
    }
  }

  CommonCryptoAesCtr._(this._api, this._key, this._counter);
  final _CommonCrypto _api;
  Uint8List? _key;
  BigInt _counter;
  int _blockOffset = 0;
  bool _resetBeforeNextUpdate = false, _closed = false;
  Pointer<Void> _cryptor = nullptr;
  Pointer<Uint8> _buffer = nullptr;
  int _capacity = 0;
  final Pointer<Size> _moved = calloc<Size>();
  static final _counterRange64 = BigInt.one << 64;
  static final _counterMask64 = _counterRange64 - BigInt.one;
  static final _counterMask128 = (BigInt.one << 128) - BigInt.one;
  static const _maximumBufferLength = 256 * 1024;

  void _create() {
    Pointer<Uint8> nativeKey = nullptr, nativeIV = nullptr;
    Pointer<Pointer<Void>> result = nullptr;
    try {
      nativeKey = calloc<Uint8>(16);
      nativeIV = calloc<Uint8>(16);
      result = calloc<Pointer<Void>>();
      nativeKey.asTypedList(16).setAll(0, _key!);
      var value = _counter;
      final iv = nativeIV.asTypedList(16);
      for (var index = 15; index >= 0; index--) {
        iv[index] = (value & BigInt.from(255)).toInt();
        value >>= 8;
      }
      // kCCEncrypt=0 (CTR is symmetric), kCCModeCTR=4, kCCAlgorithmAES=0,
      // ccNoPadding=0, default rounds=0, kCCModeOptionCTR_BE=2.
      final status = _api.create(0, 4, 0, 0, nativeIV.cast(), nativeKey.cast(),
        16, nullptr, 0, 0, 2, result);
      if (status != 0 || result.value == nullptr) {
        if (result.value != nullptr) _api.release(result.value);
        throw StateError('CommonCrypto AES-CTR creation failed ($status)');
      }
      _cryptor = result.value;
      _resetBeforeNextUpdate = false;
    } finally {
      if (nativeKey != nullptr) {
        nativeKey.asTypedList(16).fillRange(0, 16, 0);
        calloc.free(nativeKey);
      }
      if (nativeIV != nullptr) {
        nativeIV.asTypedList(16).fillRange(0, 16, 0);
        calloc.free(nativeIV);
      }
      if (result != nullptr) calloc.free(result);
    }
  }

  Uint8List process(Uint8List input) {
    if (_closed) throw StateError('CommonCrypto AES-CTR context is closed');
    if (input.isEmpty) return Uint8List(0);
    final capacity = input.length < _maximumBufferLength ? input.length : _maximumBufferLength;
    if (capacity > _capacity) {
      final replacement = calloc<Uint8>(capacity);
      if (_buffer != nullptr) {
        _buffer.asTypedList(_capacity).fillRange(0, _capacity, 0);
        calloc.free(_buffer);
      }
      _buffer = replacement;
      _capacity = capacity;
    }
    final result = Uint8List(input.length);
    try {
      var offset = 0;
      while (offset < input.length) {
        if (_resetBeforeNextUpdate) {
          _api.release(_cryptor);
          _cryptor = nullptr;
          _create();
        }
        var count = input.length - offset;
        if (count > _capacity) count = _capacity;
        final untilCounterCarry = (_counterRange64 - (_counter & _counterMask64)) *
          BigInt.from(16) - BigInt.from(_blockOffset);
        if (BigInt.from(count) > untilCounterCarry) count = untilCounterCarry.toInt();
        final buffer = _buffer.asTypedList(count);
        buffer.setRange(0, count, input, offset);
        _moved.value = 0;
        // The public API explicitly permits in-place CTR updates and emits
        // exactly one output byte per input byte, including partial blocks.
        final status = _api.update(_cryptor, _buffer.cast(), count,
          _buffer.cast(), _capacity, _moved);
        if (status != 0 || _moved.value != count) {
          throw StateError('CommonCrypto AES-CTR update failed ($status, ${_moved.value}/$count bytes)');
        }
        result.setRange(offset, offset + count, buffer);
        buffer.fillRange(0, count, 0);
        final consumed = _blockOffset + count;
        _counter = (_counter + BigInt.from(consumed ~/ 16)) & _counterMask128;
        _blockOffset = consumed % 16;
        _resetBeforeNextUpdate = BigInt.from(count) == untilCounterCarry;
        offset += count;
      }
      return result;
    } catch (_) {
      close();
      rethrow;
    } finally {
      if (_buffer != nullptr) _buffer.asTypedList(_capacity).fillRange(0, _capacity, 0);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // CommonCrypto Release clears its key schedule and disposes the context.
    if (_cryptor != nullptr) { _api.release(_cryptor); _cryptor = nullptr; }
    final key = _key;
    if (key != null) key.fillRange(0, key.length, 0);
    _key = null;
    _counter = BigInt.zero;
    if (_buffer != nullptr) {
      _buffer.asTypedList(_capacity).fillRange(0, _capacity, 0);
      calloc.free(_buffer);
      _buffer = nullptr;
      _capacity = 0;
    }
    _moved.value = 0;
    calloc.free(_moved);
  }
}

class _CommonCrypto {
  _CommonCrypto(DynamicLibrary library)
    : create = library.lookupFunction<_CreateNative, _Create>('CCCryptorCreateWithMode'),
      update = library.lookupFunction<_UpdateNative, _Update>('CCCryptorUpdate'),
      release = library.lookupFunction<_ReleaseNative, _Release>('CCCryptorRelease');
  // This public SDK install-name resides in macOS's dyld shared cache. Do not
  // require an ordinary filesystem entry before opening the system library.
  static final instance = _CommonCrypto(DynamicLibrary.open('/usr/lib/system/libcommonCrypto.dylib'));
  final _Create create;
  final _Update update;
  final _Release release;
}
