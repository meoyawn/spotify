import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Public platform zlib1.2.12 matches both independent original startup gzip
/// uploads byte-for-byte. Dart's bundled zlib differs for these same603-byte
/// inputs, despite equal header/length. Original Library mixed batches also
/// require this standard codec. This primitive owns only
/// compression; state, protobuf construction and request policy remain Dart.
abstract final class NativeGzip {
  static final _library = DynamicLibrary.open('/usr/lib/libz.1.dylib');
  static final _version = _library.lookupFunction<Pointer<Utf8> Function(),
    Pointer<Utf8> Function()>('zlibVersion');
  static final _initialize = _library.lookupFunction<
    Int32 Function(Pointer<_ZStream>, Int32, Int32, Int32, Int32, Int32, Pointer<Utf8>, Int32),
    int Function(Pointer<_ZStream>, int, int, int, int, int, Pointer<Utf8>, int)>('deflateInit2_');
  static final _bound = _library.lookupFunction<
    UnsignedLong Function(Pointer<_ZStream>, UnsignedLong),
    int Function(Pointer<_ZStream>, int)>('deflateBound');
  static final _deflate = _library.lookupFunction<Int32 Function(Pointer<_ZStream>, Int32),
    int Function(Pointer<_ZStream>, int)>('deflate');
  static final _end = _library.lookupFunction<Int32 Function(Pointer<_ZStream>),
    int Function(Pointer<_ZStream>)>('deflateEnd');

  static Uint8List encode(List<int> bytes) {
    if (!Platform.isMacOS || sizeOf<Pointer<Void>>() != 8) {
      throw UnsupportedError('The captured native gzip codec requires the64-bit macOS zlib ABI');
    }
    final stream = calloc<_ZStream>();
    final input = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    Pointer<Uint8> output = nullptr;
    var initialized = false;
    try {
      // Standard zlib defaults: DEFLATED8, gzip windowBits31, memLevel8,
      // default strategy0, no dictionary or custom gzip header.
      final status = _initialize(stream, -1, 8, 31, 8, 0, _version(), sizeOf<_ZStream>());
      if (status != 0) throw StateError('Native gzip initialization failed ($status)');
      initialized = true;
      final bound = _bound(stream, bytes.length);
      output = calloc<Uint8>(bound);
      input.asTypedList(bytes.length).setAll(0, bytes);
      stream.ref
        ..nextIn = input
        ..availableIn = bytes.length
        ..nextOut = output
        ..availableOut = bound;
      final finish = _deflate(stream, 4); // Standard Z_FINISH.
      if (finish != 1 || stream.ref.availableIn != 0) {
        throw StateError('Native gzip encoding failed ($finish)');
      }
      return Uint8List.fromList(output.asTypedList(stream.ref.totalOut));
    } finally {
      if (initialized) _end(stream);
      if (output != nullptr) calloc.free(output);
      calloc.free(input);
      calloc.free(stream);
    }
  }
}

/// Published zlib z_stream layout for the verified64-bit Darwin ABI.
final class _ZStream extends Struct {
  external Pointer<Uint8> nextIn;
  @Uint32()
  external int availableIn;
  @UnsignedLong()
  external int totalIn;
  external Pointer<Uint8> nextOut;
  @Uint32()
  external int availableOut;
  @UnsignedLong()
  external int totalOut;
  external Pointer<Char> message;
  external Pointer<Void> state;
  external Pointer<Void> allocate;
  external Pointer<Void> free;
  external Pointer<Void> opaque;
  @Int32()
  external int dataType;
  @UnsignedLong()
  external int adler;
  @UnsignedLong()
  external int reserved;
}
