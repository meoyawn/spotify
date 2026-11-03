import 'dart:convert';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart' show Int64;
import 'package:protobuf/protobuf.dart';

import 'generated/native_proto3_presence.dart';

/// Native proto3 serializers omit ordinary default scalars even when setters
/// allocated has-bits. Dart protobuf retains that explicit setter presence.
/// The original message remains unchanged; oneof and submessage presence stay.
/// Only fields confirmed by the exact recovered descriptors are transformed.
Uint8List nativeProto3Bytes(GeneratedMessage message) {
  final copy = message.deepCopy();
  _omitDefaults(copy);
  return copy.writeToBuffer();
}

void _omitDefaults(GeneratedMessage message) {
  final implicitScalars = nativeProto3ImplicitScalars[message.info_.qualifiedMessageName];
  for (final field in message.info_.fieldInfo.values) {
    final value = message.getField(field.tagNumber);
    if (value is GeneratedMessage && message.hasField(field.tagNumber)) {
      _omitDefaults(value);
    } else if (value is Iterable) {
      for (final child in value.whereType<GeneratedMessage>()) { _omitDefaults(child); }
    } else if (value is Map) {
      for (final child in value.values.whereType<GeneratedMessage>()) { _omitDefaults(child); }
    }
    // Dart's BuilderInfo drops the synthetic oneof for proto3 optional fields.
    // Only the exact descriptor can establish implicit scalar presence.
    if (implicitScalars?.contains(field.tagNumber) != true) continue;
    final isDefault = value == false || value == '' || value is int && value == 0 ||
      value is Int64 && value == Int64.ZERO || value is double && value == 0 && !value.isNegative ||
      value is ProtobufEnum && value.value == 0 || value is List<int> && value.isEmpty;
    if (isDefault) message.clearField(field.tagNumber);
  }
}

/// Native proto3 strings reject malformed UTF-8. Dart protobuf's readString
/// permits it, so validate known auth-schema strings using its public reader
/// before generated parsing. Unknown fields remain owned by standard parsing.
void validateNativeProto3Strings(List<int> bytes, GeneratedMessage schema) {
  final reader = CodedBufferReader(bytes);
  while (true) {
    final tag = reader.readTag();
    if (tag == 0) return;
    final field = schema.info_.fieldInfo[tag >> 3];
    if ((tag & 7) == 2 && field != null) {
      if (PbFieldType.baseType(field.type) == PbFieldType.STRING_BIT) {
        utf8.decode(reader.readBytes());
        continue;
      }
      if (field.subBuilder case final builder?) {
        validateNativeProto3Strings(reader.readBytes(), builder());
        continue;
      }
    }
    if (!reader.skipField(tag)) return;
  }
}
