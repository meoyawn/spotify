import 'native_audio_selection.dart';

/// Online native file ranking from 0x1012980c8, its setting/class gates and
/// comparator 0x101c16fc4. Configuration producers remain caller-owned: the raw
/// class limit and setting must come from actual account/backend state.
final class NativeAudioRankPolicy {
  const NativeAudioRankPolicy({required this.nativeSetting,
    required this.nativeClassLimit});
  final int nativeSetting, nativeClassLimit;

  /// Input candidates have passed native metadata/format-presence admission.
  /// File IDs and raw format numbers are retained; this does not select an
  /// alternate item or infer Free/Premium or decoder capabilities.
  List<NativeAudioFileCandidate> order(Iterable<NativeAudioFileCandidate> files) {
    final preferences = _nativePreferences[nativeSetting];
    if (preferences == null) return const [];
    final ranked = <NativeAudioFileCandidate>[];
    for (final file in files) {
      final nativeClass = _nativeClasses[file.format];
      if (nativeClass == null || !_allowsClass(nativeClass)) continue;
      final rank = preferences.indexOf(file.format);
      if (rank < 0) continue;
      // Native sorting retains equal-format input order in original captures,
      // including repeated-file groups beyond its small-vector path.
      var index = ranked.length;
      while (index > 0 && preferences.indexOf(ranked[index - 1].format) > rank) {
        index--;
      }
      ranked.insert(index, file);
    }
    return List.unmodifiable(ranked);
  }

  bool _allowsClass(int value) => switch (nativeClassLimit) {
    0 => value == 0,
    1 => value < 2,
    2 => true,
    _ => false,
  };
}

// Original descriptor lookup 0x101c16904: raw native class at+4. Unknown
// formats have no descriptor; they are excluded by this online rank owner.
const _nativeClasses = <int, int>{
  0: 0, 1: 0, 2: 1, 8: 0, 9: 0, 16: 2,
  18: 0, 19: 0, 20: 0, 22: 2, 57: 2,
};

// Exact original preference arrays at 0x10266c158..0x10266c248. The raw
// setting is not a bitrate number and must not be inferred from account tier.
const _nativePreferences = <int, List<int>>{
  1: [8, 18, 19, 20, 9, 0, 1, 2, 22, 16],
  2: [0, 9, 1, 8, 18, 19, 20, 2, 22, 16],
  3: [1, 0, 9, 8, 18, 19, 20, 2, 22, 16],
  4: [2, 1, 0, 9, 8, 18, 19, 20, 22, 16],
  5: [22, 16, 2, 1, 0, 9, 8, 18, 19, 20],
  6: [57, 22, 16, 2, 1, 0, 9, 8, 18, 19, 20],
};
