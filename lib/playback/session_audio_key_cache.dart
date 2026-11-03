import 'dart:typed_data';

/// Successful streaming admissions survive decoder/PCM eviction. Ownership is
/// one live account session; entries never reach disk. The explicit Dart entry
/// budget is not an inferred original default or license lifetime.
class SessionAudioKeyCache {
  SessionAudioKeyCache({this.maximumKeys = 128}) {
    if (maximumKeys <= 0) throw ArgumentError.value(maximumKeys, 'maximumKeys');
  }
  final int maximumKeys;
  final _entries = <String, Uint8List>{};
  bool _closed = false;
  int hits = 0;

  Uint8List? read(List<int> fileId20) {
    if (_closed) throw StateError('The audio-key session is closed');
    final id = _identity(fileId20);
    final value = _entries.remove(id);
    if (value == null) return null;
    hits++;
    _entries[id] = value;
    return Uint8List.fromList(value);
  }

  void admit(List<int> fileId20, List<int> key16) {
    if (_closed) throw StateError('The audio-key session is closed');
    if (key16.length != 16 || key16.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('A successful audio admission must contain16 key octets');
    }
    final id = _identity(fileId20);
    final previous = _entries.remove(id);
    previous?.fillRange(0, previous.length, 0);
    _entries[id] = Uint8List.fromList(key16);
    while (_entries.length > maximumKeys) { _invalidateHex(_entries.keys.first); }
  }

  void invalidate(List<int> fileId20) => _invalidateHex(_identity(fileId20));

  void _invalidateHex(String id) {
    final value = _entries.remove(id);
    value?.fillRange(0, value.length, 0);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final value in _entries.values) { value.fillRange(0, value.length, 0); }
    _entries.clear();
  }

  static String _identity(List<int> bytes) {
    if (bytes.length != 20 || bytes.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('An audio file identity must contain20 octets');
    }
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
