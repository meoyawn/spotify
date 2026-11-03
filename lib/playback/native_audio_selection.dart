import 'dart:typed_data';

/// One already ordered native file candidate. Keep the raw format number so
/// newer/reserved formats are not converted to a generated enum's default.
final class NativeAudioFileCandidate {
  NativeAudioFileCandidate({required List<int> fileId, required this.format})
    : fileId = Uint8List.fromList(_fileId(fileId)).asUnmodifiableView() {
    RangeError.checkValueInInterval(format, -0x80000000, 0x7fffffff, 'format');
  }
  final Uint8List fileId;
  final int format;
}

/// Native file-candidate filtering at 0x10129a0b8..0x10129a1ac/0x10129a274.
///
/// The caller supplies actual native account/backend flags and candidates in
/// the already established native strategy/bitrate order. This does not choose
/// Free defaults, infer entitlements or implement the preceding bitrate rank.
/// Flag names retain owner offsets until their producers are established.
final class NativeAudioFormatPolicy {
  const NativeAudioFormatPolicy({required this.nativeFlag50,
    required this.nativeFlag51, required this.nativeFlag52,
    required this.supportsFormat});

  final bool nativeFlag50, nativeFlag51, nativeFlag52;
  /// Native owner+0x30 virtual+0x10 checks the decoder/backend capability for
  /// the raw format. Unknown values remain available to that real capability
  /// decision; their mere presence does not grant playback permission.
  final bool Function(int format) supportsFormat;

  NativeAudioFileCandidate? selectOrdered(Iterable<NativeAudioFileCandidate> files) {
    for (final file in files) {
      final format = file.format;
      if (!supportsFormat(format)) continue;
      if (!nativeFlag50 && (format == 22 || format == 57)) continue;
      if (!nativeFlag52 && format == 57) continue;
      if (!nativeFlag51 && (format == 18 || format == 19 || format == 20)) continue;
      return file;
    }
    return null;
  }
}

List<int> _fileId(List<int> value) {
  if (value.length != 20 || value.any((byte) => byte < 0 || byte > 255)) {
    throw ArgumentError('A native audio file ID must contain exactly 20 octets');
  }
  return value;
}
