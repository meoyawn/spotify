import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _Start = Void Function(Pointer<Void>, Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _End = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _Text = Void Function(Pointer<Void>, Pointer<Utf8>, Int);

/// Standard Expat SAX interface. The system parser handles XML syntax and
/// encodings; application callbacks and all Spotify projection remain Dart.
/// No external-entity handler is installed, so this primitive performs no I/O.
bool parseExpatXml(List<int> bytes, {required void Function(String, Map<String, String>) onStart,
  required void Function(String) onEnd, required void Function(String) onText}) {
  if (bytes.length > 0x7fffffff) throw ArgumentError('XML input exceeds native int length');
  final api = _Expat.instance;
  final parser = api.create(nullptr);
  if (parser == nullptr) throw StateError('Expat could not allocate a parser');
  Object? failure;
  StackTrace? failureStack;
  void callback(void Function() action) {
    if (failure != null) return;
    try { action(); }
    catch (error, stack) { failure = error; failureStack = stack; }
  }
  final start = NativeCallable<_Start>.isolateLocal((Pointer<Void> user, Pointer<Utf8> name,
    Pointer<Pointer<Utf8>> attributes) {
    callback(() {
      final values = <String, String>{};
      for (var i = 0; attributes[i] != nullptr; i += 2) {
        values[attributes[i].toDartString()] = attributes[i + 1].toDartString();
      }
      onStart(name.toDartString(), values);
    });
  });
  final end = NativeCallable<_End>.isolateLocal((Pointer<Void> user, Pointer<Utf8> name) {
    callback(() => onEnd(name.toDartString()));
  });
  final text = NativeCallable<_Text>.isolateLocal((Pointer<Void> user, Pointer<Utf8> data, int length) {
    callback(() => onText(data.toDartString(length: length)));
  });
  final input = calloc<Uint8>(bytes.length + 1);
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    api.elements(parser, start.nativeFunction, end.nativeFunction);
    api.characters(parser, text.nativeFunction);
    final status = api.parse(parser, input.cast(), bytes.length, 1);
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    return status == 1; // XML_STATUS_OK.
  } finally {
    api.free(parser);
    calloc.free(input);
    start.close(); end.close(); text.close();
  }
}

class _Expat {
  _Expat(DynamicLibrary library)
    : create = library.lookupFunction<Pointer<Void> Function(Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>)>('XML_ParserCreate'),
      free = library.lookupFunction<Void Function(Pointer<Void>),
        void Function(Pointer<Void>)>('XML_ParserFree'),
      elements = library.lookupFunction<Void Function(Pointer<Void>, Pointer<NativeFunction<_Start>>,
          Pointer<NativeFunction<_End>>),
        void Function(Pointer<Void>, Pointer<NativeFunction<_Start>>, Pointer<NativeFunction<_End>>)>(
          'XML_SetElementHandler'),
      characters = library.lookupFunction<Void Function(Pointer<Void>, Pointer<NativeFunction<_Text>>),
        void Function(Pointer<Void>, Pointer<NativeFunction<_Text>>)>(
          'XML_SetCharacterDataHandler'),
      parse = library.lookupFunction<Int Function(Pointer<Void>, Pointer<Utf8>, Int, Int),
        int Function(Pointer<Void>, Pointer<Utf8>, int, int)>('XML_Parse');

  static final instance = _Expat(DynamicLibrary.open(Platform.isMacOS
    ? '/usr/lib/libexpat.1.dylib' : Platform.isLinux ? 'libexpat.so.1'
    : throw UnsupportedError('A system Expat library is required')));
  final Pointer<Void> Function(Pointer<Utf8>) create;
  final void Function(Pointer<Void>) free;
  final void Function(Pointer<Void>, Pointer<NativeFunction<_Start>>, Pointer<NativeFunction<_End>>) elements;
  final void Function(Pointer<Void>, Pointer<NativeFunction<_Text>>) characters;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, int) parse;
}
