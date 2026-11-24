// ignore_for_file: implementation_imports
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:protoc_plugin/src/gen/google/protobuf/descriptor.pb.dart';

/// Emits descriptor-confirmed proto3 syntax and implicit scalar presence for
/// the exact recovered schemas. Full standard descriptors are needed because
/// Dart BuilderInfo does not retain synthetic oneof/proto3_optional metadata
/// for every field. Reconstructed schemas and proto2 fields stay unlisted.
///
/// Usage: dart run tools/generate_proto3_presence.dart [output.dart]
void main(List<String> arguments) {
  if (arguments.length > 1) {
    stderr.writeln('Usage: dart run tools/generate_proto3_presence.dart [output.dart]');
    exit(64);
  }
  final root = File.fromUri(Platform.script).parent.parent.path;
  final manifest = jsonDecode(File('$root/proto/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  final descriptorSha256 = (manifest['descriptorSet'] as Map)['sha256'] as String;
  final (messages, scalars) = _proto3Presence(_verifiedDescriptorSet(root, manifest));
  final data = StringBuffer()
    ..writeln('// Generated code. Do not modify.')
    ..writeln('// Descriptor-confirmed proto3 syntax and scalar presence from exact schemas.')
    ..writeln('// Exact descriptor set SHA-256: $descriptorSha256')
    ..writeln('// Reconstructed schemas and proto2 fields are deliberately unlisted.')
    ..writeln('// Implicit scalar fields exclude repeated, message/group, oneof and proto3_optional.')
    ..writeln('const nativeProto3ImplicitScalars = <String, Set<int>>{');
  for (final name in scalars.keys.toList()..sort()) {
    data.writeln('  ${jsonEncode(name)}: <int>{${scalars[name]!.join(', ')}},');
  }
  data
    ..writeln('};')
    ..writeln()
    ..writeln('const nativeProto3Messages = <String>{');
  for (final name in messages) {
    data.writeln('  ${jsonEncode(name)},');
  }
  data.writeln('};');
  if (arguments.isEmpty) {
    stdout.write(data);
  } else {
    File(arguments.single).writeAsStringSync(data.toString());
  }
}

(List<String>, Map<String, List<int>>) _proto3Presence(FileDescriptorSet set) {
  final messages = <String>[];
  final scalars = <String, List<int>>{};
  void visit(String prefix, List<DescriptorProto> types) {
    for (final message in types) {
      final name = prefix.isEmpty ? message.name : '$prefix.${message.name}';
      messages.add(name);
      final numbers = [
        for (final field in message.field)
          if (field.label != FieldDescriptorProto_Label.LABEL_REPEATED && !field.hasOneofIndex() &&
              !field.proto3Optional && field.type != FieldDescriptorProto_Type.TYPE_MESSAGE &&
              field.type != FieldDescriptorProto_Type.TYPE_GROUP)
            field.number,
      ]..sort();
      if (numbers.isNotEmpty) scalars[name] = numbers;
      visit(name, message.nestedType);
    }
  }
  for (final file in set.file) {
    if (file.syntax == 'proto3') visit(file.package, file.messageType);
  }
  return (messages..sort(), scalars);
}

FileDescriptorSet _verifiedDescriptorSet(String root, Map<String, dynamic> manifest) {
  final artifact = manifest['descriptorSet'] as Map<String, dynamic>;
  if (manifest['schemaVersion'] != 1) throw StateError('Unsupported manifest schemaVersion');
  if (artifact['path'] != 'reverse-engineering/protobuf/original.pbdesc') {
    throw StateError('Descriptor set path is outside the selected artifact location');
  }
  final raw = File('$root/${artifact['path']}').readAsBytesSync();
  if (sha256.convert(raw).toString() != artifact['sha256']) throw StateError('Descriptor set digest changed');
  final set = FileDescriptorSet.fromBuffer(raw);
  final records = (manifest['files'] as List).cast<Map<String, dynamic>>();
  if (set.file.length != records.length) throw StateError('Descriptor set and manifest file counts differ');
  for (final (index, record) in records.indexed) {
    final name = record['file'] as String;
    if (record['sourcePath'] != 'proto/source/$name') throw StateError('Source path does not match $name');
    final start = record['descriptorSetOffset'] as int, end = start + (record['length'] as int);
    if (start < 0 || end < start || end > raw.length ||
        sha256.convert(raw.sublist(start, end)).toString() != record['sha256']) {
      throw StateError('Descriptor $name raw-byte digest or set offset is invalid');
    }
    final file = set.file[index];
    final dependencies = (record['dependencies'] as List? ?? const []).cast<String>();
    if (file.name != name || file.package != record['package'] ||
        file.dependency.length != dependencies.length ||
        !file.dependency.indexed.every((entry) => entry.$2 == dependencies[entry.$1])) {
      throw StateError('Descriptor $name metadata disagrees with the manifest');
    }
    final sourceSha256 = record['sourceSha256'] as String?;
    if (sourceSha256 != null && sourceSha256.isNotEmpty &&
        sha256.convert(File('$root/${record['sourcePath']}').readAsBytesSync()).toString() != sourceSha256) {
      throw StateError('Printed source ${record['sourcePath']} digest changed');
    }
  }
  return set;
}
