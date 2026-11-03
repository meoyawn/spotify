import 'dart:convert';

import '../protocol/generated/playlist_sync_reason.pb.dart';
import 'sync_path.dart';

class PlaylistSyncPlan {
  PlaylistSyncPlan({required this.path, required this.method, required List<MapEntry<String, String>> headers})
      : headers = List.unmodifiable(headers);
  final String path;
  final String method;
  final List<MapEntry<String, String>> headers;
  Map<String, Object?> toJson() => {'path': path, 'method': method,
    'headers': [for (final header in headers) [header.key, header.value]]};
}

/// Original primary playlist synchronization builder0x101aaa0d8.
/// This plan precedes host binding, native HTTP defaults and transport. Native
/// applied revision/lens state and changes bodies are separate inputs. Requested
/// lenses and permission grants are explicit owner inputs, not account defaults.
PlaylistSyncPlan buildPlaylistSyncPlan({required String canonicalUri, required PlaylistSyncCaller caller,
    required bool prioritized, PlaylistSyncMode mode = PlaylistSyncMode.read,
    bool acceptListItems = false, bool handlesContent = false, bool force = false,
    String hintRevision = '', bool? dsaMode, bool listPlayerEnabled = false,
    Iterable<String> requestedLenses = const [], String permissionGrantToken = ''}) {
  // Original101aaa0d8 removes tag-filter prefix entries before joining the
  // remaining requested lens vector. Empty entries and duplicates survive.
  final lenses = requestedLenses.where((lens) => !lens.startsWith('tag-filter')).toList();
  final route = playlistSyncRoute(canonicalUri, mode: mode).withQuery([
    if (handlesContent) const MapEntry('handlesContent', ''),
    if (hintRevision.isNotEmpty) MapEntry('hint_revision', hintRevision),
    if (force) const MapEntry('force', 'true'),
    if (permissionGrantToken.isNotEmpty) MapEntry('permission-grant-token', permissionGrantToken),
  ]);
  final reason = PlaylistSyncReason();
  if (caller != PlaylistSyncCaller.UNKNOWN) { reason.caller = caller; }
  if (prioritized) { reason.prioritized = true; }
  return PlaylistSyncPlan(path: route.path, method: route.method, headers: [
    const MapEntry('Cache-Control', 'no-cache, no-store'),
    if (acceptListItems) const MapEntry('x-accept-list-items', 'audio-track, audio-episode, video-episode, audiobook'),
    const MapEntry('spotify-accept-geoblock', 'dummy'),
    MapEntry('spotify-playlist-sync-reason', base64.encode(reason.writeToBuffer())),
    if (lenses.isNotEmpty) MapEntry('spotify-apply-lenses', lenses.join(',')),
    if (dsaMode != null) MapEntry('spotify-dsa-mode-enabled', '$dsaMode'),
    if (listPlayerEnabled) const MapEntry('spotify-list-player-enabled', 'true'),
  ]);
}
