/// Original rootlist101b20fbc/101b21510/101b23a48/101b23ce4.
/// Marker names use form escaping: '+' means space, '%2B' means literal plus.
/// Native markers and canonical navigation URIs are separate representations.
class NativeRootlistFolderMarker {
  const NativeRootlistFolderMarker({required this.id, required this.opens, required this.name});
  final String id, name;
  final bool opens;

  static NativeRootlistFolderMarker? parse(String value) {
    final match = RegExp(r'^spotify:(start|end)-group:([0-9a-fA-F]{1,16})(?::(.*))?$').firstMatch(value);
    if (match == null) return null;
    final opens = match[1] == 'start';
    if (opens && match[3] == null || !opens && match[3] != null) return null;
    return NativeRootlistFolderMarker(id: match[2]!.toLowerCase().padLeft(16, '0'), opens: opens,
      name: opens ? Uri.decodeQueryComponent(match[3]!) : '');
  }
}

String nativeRootlistFolderUri(String username, String id) =>
  'spotify:user:${Uri.encodeComponent(username)}:folder:${id.toLowerCase().padLeft(16, '0')}';

String? nativeRootlistCanonicalFolderUri(String value, String username) {
  final match = RegExp(r'^spotify:user:([^:]+):folder:([0-9a-fA-F]{1,16})$').firstMatch(value);
  if (match == null || Uri.decodeComponent(match[1]!) != username) return null;
  return nativeRootlistFolderUri(username, match[2]!);
}
