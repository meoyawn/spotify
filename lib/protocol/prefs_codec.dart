import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import 'generated/es_prefs.pb.dart' as proto;

enum PrefsDiskKind { unset, boolean, number, string }

/// The native disk format contains byte strings, independently of protobuf's
/// UTF-8 text contract. Byte getters return copies.
class PrefsDiskValue {
  PrefsDiskValue.unset() : kind = PrefsDiskKind.unset, boolean = null, number = null, _bytes = null;
  PrefsDiskValue.boolean(bool value) : kind = PrefsDiskKind.boolean, boolean = value, number = null, _bytes = null;
  PrefsDiskValue.number(int value) : kind = PrefsDiskKind.number, boolean = null, number = value.toSigned(32), _bytes = null;
  PrefsDiskValue.string(List<int> bytes) : kind = PrefsDiskKind.string, boolean = null, number = null,
    _bytes = Uint8List.fromList(bytes);
  final PrefsDiskKind kind;
  final bool? boolean;
  final int? number;
  final Uint8List? _bytes;
  Uint8List get stringBytes => Uint8List.fromList(_bytes ?? const []);

  factory PrefsDiskValue.fromProtobuf(proto.Value value) => switch (value.whichValue()) {
    proto.Value_Value.bool_2 => PrefsDiskValue.boolean(value.bool_2),
    proto.Value_Value.number => PrefsDiskValue.number(value.number.toInt()),
    proto.Value_Value.string => PrefsDiskValue.string(utf8.encode(value.string)),
    proto.Value_Value.notSet => PrefsDiskValue.unset(),
  };

  /// Invalid UTF-8 is reported at this explicit bridge; the raw codec retains it.
  proto.Value toProtobuf() => switch (kind) {
    PrefsDiskKind.boolean => proto.Value(bool_2: boolean!),
    PrefsDiskKind.number => proto.Value(number: Int64(number!)),
    PrefsDiskKind.string => proto.Value(string: utf8.decode(_bytes!)),
    PrefsDiskKind.unset => proto.Value(),
  };
}

class PrefsDiskEntry {
  PrefsDiskEntry(List<int> key, this.value, {this.flags = 0x100}) : _key = Uint8List.fromList(key);
  final Uint8List _key;
  final PrefsDiskValue value;
  final int flags;
  Uint8List get keyBytes => Uint8List.fromList(_key);

  factory PrefsDiskEntry.fromProtobuf(String key, proto.Value value, {int flags = 0x100}) =>
    PrefsDiskEntry(utf8.encode(key), PrefsDiskValue.fromProtobuf(value), flags: flags);

  MapEntry<String, proto.Value> toProtobuf() => MapEntry(utf8.decode(_key), value.toProtobuf());
}

/// Proprietary line grammar at 0x101b8f67c and byte writer at 0x101b8ffa0.
class PrefsCodec {
  static List<PrefsDiskEntry> decode(List<int> input) {
    final result = <PrefsDiskEntry>[];
    var start = 0;
    for (var end = 0; end <= input.length; end++) {
      if (end < input.length && input[end] != 10) continue;
      final line = input.sublist(start, end);
      start = end + 1;
      final separator = line.indexOf(61);
      if (separator < 0) continue;
      var key = _trim(line.sublist(0, separator));
      final token = _trim(line.sublist(separator + 1));
      if (key.isEmpty || token.isEmpty) continue;
      final value = _decodeValue(token);
      if (value == null) continue;
      final nul = key.indexOf(0);
      if (nul >= 0) key = key.sublist(0, nul);
      result.add(PrefsDiskEntry(key, value));
    }
    return List.unmodifiable(result);
  }

  static Uint8List encode(Iterable<PrefsDiskEntry> entries) {
    final output = BytesBuilder(copy: false);
    for (final entry in entries) {
      if ((entry.flags & 0x100) == 0) continue;
      output.add(entry._key);
      output.addByte(61);
      switch (entry.value.kind) {
        case PrefsDiskKind.unset:
          break;
        case PrefsDiskKind.boolean:
          output.add(ascii.encode(entry.value.boolean! ? 'true\n' : 'false\n'));
        case PrefsDiskKind.number:
          output.add(ascii.encode('${entry.value.number!}\n'));
        case PrefsDiskKind.string:
          output.addByte(34);
          for (final byte in entry.value._bytes!) {
            if (byte == 34 || byte == 92) {
              output.add([92, byte]);
            } else if (byte == 9 || byte == 10 || byte == 13) {
              output.add([92, byte + 97]);
            } else if (byte < 32 || byte == 127) {
              output.add(ascii.encode('\\x${byte.toRadixString(16).padLeft(2, '0')}'));
            } else {
              output.addByte(byte);
            }
          }
          output.add([34, 10]);
      }
    }
    return output.takeBytes();
  }
}

List<int> _trim(List<int> bytes) {
  var start = 0;
  var end = bytes.length;
  bool whitespace(int byte) => byte == 32 || (byte >= 9 && byte <= 13);
  while (start < end && whitespace(bytes[start])) { start++; }
  while (start < end && whitespace(bytes[end - 1])) { end--; }
  return bytes.sublist(start, end);
}

PrefsDiskValue? _decodeValue(List<int> token) {
  if (token.first == 34) {
    final output = BytesBuilder(copy: false);
    for (var i = 1; i < token.length; i++) {
      final byte = token[i];
      if (byte == 34) return i == token.length - 1 ? PrefsDiskValue.string(output.takeBytes()) : null;
      if (byte == 92) {
        if (++i >= token.length) return null;
        final escaped = token[i];
        if (escaped == 106 || escaped == 107 || escaped == 110) {
          output.addByte(escaped - 97);
        } else if (escaped == 34 || escaped == 92) {
          output.addByte(escaped);
        } else if (escaped == 120 && i + 2 < token.length) {
          final hex = String.fromCharCodes(token.sublist(i + 1, i + 3));
          if (!_hexPair.hasMatch(hex)) return null;
          output.addByte(int.parse(hex, radix: 16));
          i += 2;
        } else {
          return null;
        }
      } else if (byte < 32 || byte == 127) {
        return null;
      } else {
        output.addByte(byte);
      }
    }
    return null;
  }
  final text = String.fromCharCodes(token);
  if (text == 'true') return PrefsDiskValue.boolean(true);
  if (text == 'false') return PrefsDiskValue.boolean(false);
  if (token.first != 45 && (token.first < 48 || token.first > 57)) return null;
  final negative = token.first == 45;
  var digits = negative ? text.substring(1) : text;
  var radix = 10;
  if (digits.startsWith('0x') || digits.startsWith('0X')) {
    radix = 16;
    digits = digits.substring(2);
  } else if (digits.startsWith('0')) {
    radix = 8;
  }
  if (!_numericDigits.hasMatch(digits)) return null;
  final magnitude = BigInt.tryParse(digits, radix: radix);
  if (magnitude == null) return null;
  var number = negative ? -magnitude : magnitude;
  if (number > _longMax) number = _longMax;
  if (number < _longMin) number = _longMin;
  return PrefsDiskValue.number(number.toSigned(32).toInt());
}

final _hexPair = RegExp(r'^[0-9a-fA-F]{2}$');
final _numericDigits = RegExp(r'^[0-9a-fA-F]+$');
final _longMax = (BigInt.one << 63) - BigInt.one;
final _longMin = -(BigInt.one << 63);
