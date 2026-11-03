import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';

/// Ordinary music branch of original 0x10048c604. Cache identity, clock and
/// source interactivity belong to its caller. This encoder performs no I/O.
final class NativePlayPlayLicenseBody {
  NativePlayPlayLicenseBody({required List<int> cacheId,
    required this.timestampSeconds, required this.nativeInteractivity})
    : cacheId = Uint8List.fromList(cacheId).asUnmodifiableView() {
    if (cacheId.any((value) => value < 0 || value > 255)) {
      throw ArgumentError('PlayPlay cache identity must contain octets');
    }
    if (timestampSeconds < 0) throw ArgumentError.value(timestampSeconds, 'timestampSeconds');
  }

  final Uint8List cacheId;
  final int timestampSeconds, nativeInteractivity;

  // Exact original getters 1004d69e0/1004d69e8/1004d69f0, not an upstream token.
  static const version = 5;
  static const _token = <int>[0x02, 0xa2, 0x66, 0xc4, 0xcd, 0xd3, 0xd0, 0x8b,
    0x5e, 0x0f, 0x13, 0xea, 0xac, 0x0f, 0x78, 0x24];

  Uint8List encode() {
    final writer = CodedBufferWriter();
    writer.writeField(1, PbFieldType.O3, version);
    writer.writeField(2, PbFieldType.OY, _token);
    if (cacheId.isNotEmpty) writer.writeField(3, PbFieldType.OY, cacheId);
    writer.writeField(4, PbFieldType.O3, nativeInteractivity == 0 ? 1 : nativeInteractivity == 2 ? 3 : 2);
    writer.writeField(5, PbFieldType.O3, 1);
    if (timestampSeconds != 0) writer.writeField(6, PbFieldType.O6, Int64(timestampSeconds));
    return writer.toBuffer();
  }
}
