enum PlaylistSyncMode { read, changes, diff }

class PlaylistSyncRoute {
  const PlaylistSyncRoute({required this.path, required this.method});
  final String path;
  final String method;
  Map<String, Object?> toJson() => {'path': path, 'method': method};

  /// Original query helper preserves existing bytes and duplicate entries.
  PlaylistSyncRoute withQuery(Iterable<MapEntry<String, String>> values) {
    final separator = path.indexOf('?');
    final base = separator < 0 ? path : path.substring(0, separator);
    final existing = separator < 0 ? '' : path.substring(separator + 1);
    final fields = [if (existing.isNotEmpty) existing,
      for (final entry in values) '${_encode(entry.key)}=${_encode(entry.value)}'];
    return PlaylistSyncRoute(path: fields.isEmpty ? base : '$base?${fields.join('&')}', method: method);
  }
}

String _encode(String text) => Uri.encodeQueryComponent(text).replaceAll('+', '%20');

/// Relative primary synchronization route from native0x101aaa0d8/0x101affddc.
/// The input is the original canonical Spotify URI, already formatted by its
/// owner; this does not parse arbitrary links, build headers/body or select a host.
PlaylistSyncRoute playlistSyncRoute(String canonicalUri, {PlaylistSyncMode mode = PlaylistSyncMode.read}) {
  final artistPopular = RegExp(r'^spotify:list:popular-release-segments-main-roles:artist_[0-9A-Za-z]{22}$').hasMatch(canonicalUri);
  if (!(artistPopular && mode == PlaylistSyncMode.read) &&
      !RegExp(r'^spotify:(playlist:[^:?#]+|user:[^:?#]+:playlist:[^:?#]+)$').hasMatch(canonicalUri)) {
    throw UnsupportedError('Only plain canonical playlist synchronization paths are supported.');
  }
  final path = 'playlist/v2/${canonicalUri.substring(8).replaceAll(':', '/')}';
  return PlaylistSyncRoute(path: '$path${switch (mode) {
    PlaylistSyncMode.read => '', PlaylistSyncMode.changes => '/changes', PlaylistSyncMode.diff => '/diff',
  }}', method: mode == PlaylistSyncMode.changes ? 'POST' : 'GET');
}
