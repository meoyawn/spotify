import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// Static Dart translation of bounded proprietary Spotify arithmetic. Generated
// blocks contain expressions and fixed control flow, never ARM instruction data.
// Source: bf8772d90de830d5223f72584574f8bf04e7fc520f546c2fc1e3271cedef8fca.
// BEGIN GENERATED PARTS
part 'native_playplay_math/data.dart';
part 'native_playplay_math/dispatch.dart';
part 'native_playplay_math/blocks_10048e.dart';
part 'native_playplay_math/blocks_10048f.dart';
part 'native_playplay_math/blocks_100490.dart';
part 'native_playplay_math/blocks_100491.dart';
part 'native_playplay_math/blocks_100492.dart';
part 'native_playplay_math/blocks_100493.dart';
part 'native_playplay_math/blocks_100494.dart';
part 'native_playplay_math/blocks_100495.dart';
part 'native_playplay_math/blocks_100496.dart';
part 'native_playplay_math/blocks_100497.dart';
part 'native_playplay_math/blocks_100498.dart';
part 'native_playplay_math/blocks_100499.dart';
part 'native_playplay_math/blocks_10049a.dart';
part 'native_playplay_math/blocks_10049b.dart';
part 'native_playplay_math/blocks_10049c.dart';
part 'native_playplay_math/blocks_10049d.dart';
part 'native_playplay_math/blocks_10049e.dart';
part 'native_playplay_math/blocks_10049f.dart';
part 'native_playplay_math/blocks_1004a0.dart';
part 'native_playplay_math/blocks_1004a1.dart';
part 'native_playplay_math/blocks_1004a2.dart';
part 'native_playplay_math/blocks_1004a3.dart';
part 'native_playplay_math/blocks_1004a4.dart';
part 'native_playplay_math/blocks_1004a5.dart';
part 'native_playplay_math/blocks_1004a6.dart';
part 'native_playplay_math/blocks_1004a7.dart';
part 'native_playplay_math/blocks_1004a8.dart';
part 'native_playplay_math/blocks_1004a9.dart';
part 'native_playplay_math/blocks_1004aa.dart';
part 'native_playplay_math/blocks_1004ab.dart';
part 'native_playplay_math/blocks_1004ac.dart';
part 'native_playplay_math/blocks_1004ad.dart';
part 'native_playplay_math/blocks_1004ae.dart';
part 'native_playplay_math/blocks_1004af.dart';
part 'native_playplay_math/blocks_1004b0.dart';
part 'native_playplay_math/blocks_1004b1.dart';
part 'native_playplay_math/blocks_1004b2.dart';
part 'native_playplay_math/blocks_1004b3.dart';
part 'native_playplay_math/blocks_1004b4.dart';
part 'native_playplay_math/blocks_1004b5.dart';
part 'native_playplay_math/blocks_1004b6.dart';
part 'native_playplay_math/blocks_1004b7.dart';
part 'native_playplay_math/blocks_1004b8.dart';
part 'native_playplay_math/blocks_1004b9.dart';
part 'native_playplay_math/blocks_1004ba.dart';
part 'native_playplay_math/blocks_1004bb.dart';
part 'native_playplay_math/blocks_1004bc.dart';
part 'native_playplay_math/blocks_1004bf.dart';
part 'native_playplay_math/blocks_1004c0.dart';
part 'native_playplay_math/blocks_1004c1.dart';
part 'native_playplay_math/blocks_1004c2.dart';
part 'native_playplay_math/blocks_1004c3.dart';
part 'native_playplay_math/blocks_1004c4.dart';
part 'native_playplay_math/blocks_1004c5.dart';
part 'native_playplay_math/blocks_1004c6.dart';
part 'native_playplay_math/blocks_1004c7.dart';
part 'native_playplay_math/blocks_1004c8.dart';
part 'native_playplay_math/blocks_1004c9.dart';
part 'native_playplay_math/blocks_1004ca.dart';
part 'native_playplay_math/blocks_1004cb.dart';
part 'native_playplay_math/blocks_1004cc.dart';
part 'native_playplay_math/blocks_1004cd.dart';
part 'native_playplay_math/blocks_1004ce.dart';
part 'native_playplay_math/blocks_1004cf.dart';
part 'native_playplay_math/blocks_1004d0.dart';
part 'native_playplay_math/blocks_1004d1.dart';
part 'native_playplay_math/blocks_1004d2.dart';
part 'native_playplay_math/blocks_1004d3.dart';
part 'native_playplay_math/blocks_1004d4.dart';
part 'native_playplay_math/blocks_1004d5.dart';
part 'native_playplay_math/blocks_1004d6.dart';
part 'native_playplay_math/blocks_101c85.dart';
part 'native_playplay_math/blocks_101c86.dart';
part 'native_playplay_math/blocks_101f78.dart';
// END GENERATED PARTS

/// Words observed before the original 28-byte protected-result construction.
/// Their interpretation as a content AES key has not been established.
final class NativePlayPlayTransformWords {
  NativePlayPlayTransformWords._(this._bytes);
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
}

/// The original result callback receives all 28 bytes of this distinct object.
final class NativePlayPlayProtectedResult {
  NativePlayPlayProtectedResult(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 28) throw ArgumentError('The original protected result contains28 bytes');
  }
  final Uint8List bytes;
}

final class NativePlayPlayUnwrap {
  /// License response field1 to the exact16 raw bytes consumed by the original
  /// AES-128 key schedule. The transient protected28 representation is local;
  /// its standard random-device input never changes the resulting content key.
  static Uint8List unwrapContentKey(List<int> obfuscated,
      {List<int>? constants}) {
    _validate(obfuscated, constants);
    final math = _PlayPlayMath();
    math.transform(obfuscated, constants);
    math.advance(0x10048ef3c);
    final protected = math.m.bytes(math.r[29] - 0x8c, 28);
    return math.unprotect(protected);
  }

  static NativePlayPlayTransformWords transformWords(List<int> obfuscated,
      {List<int>? constants}) {
    _validate(obfuscated, constants);
    return NativePlayPlayTransformWords._(_PlayPlayMath().transform(obfuscated, constants));
  }

  static void _validate(List<int> obfuscated, List<int>? constants) {
    if (obfuscated.length != 16 || obfuscated.any((v) => v < 0 || v > 255)) {
      throw ArgumentError('The original successful response field contains16 octets');
    }
    if (constants != null && (constants.length != 3072 ||
        constants.any((v) => v < 0 || v > 255))) {
      throw ArgumentError('The proprietary constant table contains3072 octets');
    }
  }
}

final class _MathStorage {
  // A mapped page is zero-filled on first access. Most of the bounded original
  // heap reservation is untouched by one key, so mapping need not allocate it.
  final pages = <int, ByteData?>{};
  // Mapping only adds pages; these hot-page views stay valid for this key.
  var _firstPageIndex = -1, _secondPageIndex = -1;
  ByteData? _firstPage, _secondPage;
  void map(int address, int length) {
    for (var at = address & ~4095; at < address + length; at += 4096) {
      pages.putIfAbsent(at >>> 12, () => null);
    }
  }
  ByteData page(int address) {
    final index = address >>> 12;
    if (index == _firstPageIndex) return _firstPage!;
    if (index == _secondPageIndex) return _secondPage!;
    var data = pages[index];
    if (data == null) {
      if (!pages.containsKey(index)) {
        throw StateError('Unmapped original arithmetic data at0x${address.toRadixString(16)}');
      }
      data = pages[index] = ByteData(4096);
    }
    _secondPageIndex = _firstPageIndex;
    _secondPage = _firstPage;
    _firstPageIndex = index;
    _firstPage = data;
    return data;
  }
  int load(int address, int size) {
    final offset = address & 4095;
    final data = page(address);
    if (offset + size <= 4096) {
      return switch(size) {
        1 => data.getUint8(offset),
        2 => data.getUint16(offset, Endian.little),
        4 => data.getUint32(offset, Endian.little),
        8 => data.getInt64(offset, Endian.little),
        _ => throw StateError('Unsupported original data width$size'),
      };
    }
    var value = 0;
    for (var i = 0; i < size; i++) { value |= load(address + i, 1) << (8 * i); }
    return value;
  }
  void store(int address, int value, int size) {
    final offset = address & 4095;
    final data = page(address);
    if (offset + size <= 4096) {
      switch(size) {
        case 1: data.setUint8(offset, value); return;
        case 2: data.setUint16(offset, value, Endian.little); return;
        case 4: data.setUint32(offset, value, Endian.little); return;
        case 8: data.setInt64(offset, value, Endian.little); return;
      }
    }
    for (var i = 0; i < size; i++) { store(address + i, value >>> (8 * i), 1); }
  }
  Uint8List bytes(int address, int length) {
    final result = Uint8List(length);
    for (var copied = 0; copied < length;) {
      final at = address + copied, offset = at & 4095;
      final span = min(length - copied, 4096 - offset);
      final data = page(at);
      result.setRange(copied, copied + span,
          data.buffer.asUint8List(data.offsetInBytes + offset, span));
      copied += span;
    }
    return result;
  }
  void writeBytes(int address, List<int> bytes) {
    for (var copied = 0; copied < bytes.length;) {
      final at = address + copied, offset = at & 4095;
      final span = min(bytes.length - copied, 4096 - offset);
      final data = page(at);
      data.buffer.asUint8List(data.offsetInBytes + offset, span)
          .setRange(0, span, bytes, copied);
      copied += span;
    }
  }
}

final class _MathCall {
  _MathCall(this.site, this.saved, this.stack);
  final int site;
  final List<int> saved;
  final int stack;
}

final class _PlayPlayMath {
  _PlayPlayMath() {
    m.map(0x30000000, 0x200000);
    m.map(0x70000000, 0x10000);
    for (final entry in _originalDataPages.entries) {
      m.map(entry.key, 4096);
      m.writeBytes(entry.key, base64Decode(entry.value));
    }
    m.store(0x10268d888, 0x30000100, 8);
    m.store(0x30000100, 0x123456789abcdef, 8);
    stackProbe = m.load(0x10268d818, 8);
    threadBootstrap = m.load(0x1027e95d0, 8);
  }
  final m = _MathStorage();
  final r = List<int>.filled(31, 0);
  final vectors = List<Uint8List>.generate(32, (_) => Uint8List(16));
  final calls = <_MathCall>[];
  final threadSlots = <int, int>{};
  late final int stackProbe, threadBootstrap;
  var s = 0x7000eeb0, n = 0x10048e084, heap = 0x30010000;
  bool negative = false, zero = false, carry = false, overflow = false;
  (int, int)? currentException;
  Random? _random;

  Uint8List transform(List<int> obfuscated, List<int>? constants) {
    r[29] = s + 0x140;
    r[8] = s + 0x58;
    r[9] = 0x10219811c;
    r[21] = s + 0x40;
    if (constants != null) {
      r[22] = allocate(3072);
      m.writeBytes(r[22], constants);
    }
    m.writeBytes(r[29] - 0x9c, obfuscated);
    m.writeBytes(r[21], const [0x53,0x9e,0xe0,0x1a,0xb9,0x49,0x1e,0x1a,
        0x64,0xfd,0xb2,0x42,0x2e,0x86,0x59,0xd1]);
    advance(0x10048ef24);
    return m.bytes(r[29] - 0x70, 16);
  }

  Uint8List unprotect(List<int> protected) {
    r[1] = allocate(28);
    m.writeBytes(r[1], protected);
    n = 0x101c85fe8;
    calls.clear();
    advance(0x101c86940);
    return m.bytes(s + 0x28, 16);
  }

  // Generated chunks retain every original entry and count the exact number of
  // sequential original operations, including the final partial budget chunk.
  void advance(int stop) {
    var operations = 0;
    while (n != stop) {
      if (operations >= 5000000) throw StateError('Original arithmetic control flow exceeded its bound');
      while (calls.isNotEmpty && n == calls.last.site + 4) { calls.removeLast(); }
      operations += step(5000000 - operations);
    }
  }

  void call(int site, int destination) {
    calls.add(_MathCall(site, List<int>.of(r.sublist(19, 31)), s));
    r[30] = site + 4;
    n = destination;
  }
  void throwOriginal(int object, int type) {
    for (var i = calls.length - 1; i >= 0; i--) {
      final frame = calls[i];
      final handler = _originalCatches[frame.site]?[type];
      if (handler == null) continue;
      calls.removeRange(i, calls.length);
      for (var j = 0; j < frame.saved.length; j++) { r[19 + j] = frame.saved[j]; }
      s = frame.stack;
      r[0] = object; r[1] = handler.$2; n = handler.$1;
      currentException = (object, type);
      return;
    }
    throw StateError('No recovered original catch for0x${type.toRadixString(16)}');
  }
  int allocate(int length) {
    final result = heap;
    heap += ((length < 1 ? 1 : length) + 15) & ~15;
    if (heap >= 0x30200000) throw StateError('Original arithmetic storage exceeded its bound');
    for (var i = 0; i < length; i++) { m.store(result + i, 0, 1); }
    return result;
  }
  int rotate(int value, int amount, int width) {
    amount &= width - 1;
    if (width == 32) value &= 0xffffffff;
    if (amount == 0) return value;
    final result = (value >>> amount) | (value << (width - amount));
    return width == 32 ? result & 0xffffffff : result;
  }
  bool unsignedLess(int a, int b) => (a ^ 0x8000000000000000) < (b ^ 0x8000000000000000);
  void compare(int a, int b, int width, bool addition) {
    final sign = width == 32 ? 0x80000000 : 0x8000000000000000;
    if (width == 32) { a &= 0xffffffff; b &= 0xffffffff; }
    var result = addition ? a + b : a - b;
    if (width == 32) result &= 0xffffffff;
    negative = (result & sign) != 0;
    zero = result == 0;
    carry = width == 32 ? (addition ? a + b > 0xffffffff : a >= b)
        : (addition ? unsignedLess(result, a) : !unsignedLess(a, b));
    overflow = addition ? ((a ^ result) & (b ^ result) & sign) != 0
        : ((a ^ b) & (a ^ result) & sign) != 0;
  }
  void logicalFlags(int value, int width) {
    if (width == 32) value &= 0xffffffff;
    negative = ((value >>> (width - 1)) & 1) != 0;
    zero = value == 0; carry = false; overflow = false;
  }
  bool condition(String name) => switch(name) {
    'eq' => zero, 'ne' => !zero, 'lo' => !carry, 'hs' => carry,
    'hi' => carry && !zero, 'ls' => !carry || zero, 'lt' => negative != overflow,
    'ge' => negative == overflow, 'le' => zero || negative != overflow,
    'gt' => !zero && negative == overflow, 'mi' => negative, 'pl' => !negative,
    _ => throw StateError('Unsupported original condition$name'),
  };
  int udiv(int a, int b, int width) {
    if (b == 0) return 0;
    if (width == 32) return (a & 0xffffffff) ~/ (b & 0xffffffff);
    return (BigInt.from(a).toUnsigned(64) ~/ BigInt.from(b).toUnsigned(64)).toInt();
  }
  int sdiv(int a, int b, int width) => b == 0 ? 0 : a.toSigned(width) ~/ b.toSigned(width);
  int umulh(int a, int b) => ((BigInt.from(a).toUnsigned(64) *
      BigInt.from(b).toUnsigned(64)) >> 64).toInt();
  void loadVector(int register, int address, int length) {
    vectors[register] = Uint8List(16)..setRange(0, length, m.bytes(address, length));
  }
  void storeVector(int register, int address, int length) {
    m.writeBytes(address, vectors[register].sublist(0, length));
  }
  void duplicateVector(int register, int value) {
    final data = ByteData.sublistView(vectors[register]);
    for (var i = 0; i < 4; i++) { data.setUint32(i * 4, value, Endian.little); }
  }
  void addVector(int destination, int a, int b) {
    final left = ByteData.sublistView(vectors[a]), right = ByteData.sublistView(vectors[b]);
    final result = Uint8List(16), data = ByteData(16);
    for (var i = 0; i < 4; i++) {
      data.setUint32(i * 4, left.getUint32(i * 4, Endian.little) +
          right.getUint32(i * 4, Endian.little), Endian.little);
    }
    result.setAll(0, data.buffer.asUint8List()); vectors[destination] = result;
  }
  void external() {
    final a = r[0], b = r[1], c = r[2];
    if (n == stackProbe) { n = r[30]; return; }
    if (n == threadBootstrap) {
      r[0] = threadSlots.putIfAbsent(a, () => allocate(32)); n = r[30]; return;
    }
    switch(n) {
      case 0x1004d7b58: case 0x101d02310:
        for (var i = 0; i < b; i++) {
          m.store(a + i, (_random ??= Random.secure()).nextInt(256), 1);
        }
        break;
      case 0x101fd1690: case 0x101fd169c: case 0x101fd1e94:
        break;
      case 0x101fd16a8:
        r[0] = (_random ??= Random.secure()).nextInt(0x100000000); break;
      case 0x101fd24a0: case 0x101fd24ac:
        m.writeBytes(a, m.bytes(b, c)); break;
      case 0x101fd24b8:
        for (var i = 0; i < c; i++) { m.store(a + i, b, 1); } break;
      case 0x101fd1cf0: case 0x101fd247c: case 0x101fd1ccc:
        r[0] = allocate(a); break;
      case 0x101fd1f54:
        r[0] = allocate(a * b); break;
      case 0x101fd1d2c:
        r[0] = allocate(a); break;
      case 0x101fd1da4:
        throwOriginal(a, b); return;
      case 0x101fd1d98: case 0x101fd11f8:
        final exception = currentException;
        if (exception == null) throw StateError('Original exception resumed without an active object');
        throwOriginal(exception.$1, exception.$2); return;
      case 0x101fd1d80:
        r[0] = m.load(a, 1) == 0 ? 1 : 0; break;
      case 0x101fd1d8c:
        m.store(a, 1, 1); break;
      case 0x101fd1d44: case 0x101fd1d50:
      case 0x101fd19b4: case 0x101fd19c0: case 0x101fd19d8:
      case 0x101fd1cc0: case 0x101fd17b0: case 0x101fd17bc:
        break;
      default: throw StateError('Unrecovered original arithmetic import0x${n.toRadixString(16)}');
    }
    n = r[30];
  }
}
