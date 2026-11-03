import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import '../protocol/generated/lens-model.pb.dart' show LensState;
import '../protocol/generated/playlist_api.pb.dart' as api;
import '../protocol/generated/playlist_cache.pb.dart' as cache;
import '../protocol/generated/playlist_permission.pb.dart' as permission;
import '../protocol/generated/signal-model.pb.dart' show Signal;
import '../protocol/native_protobuf.dart';

class PlaylistCacheItem {
  const PlaylistCacheItem({required this.canonicalUri, required this.attributes});
  /// The URI owner's canonical output. This writer does not parse native links.
  final String canonicalUri;
  final api.ItemAttributes attributes;
}

/// Actual managed-list/actor data consumed by the native cache projection.
/// It is not a request policy or a successful Playlist.Get response.
class PlaylistCacheState {
  const PlaylistCacheState({required this.revision, required this.attributes,
    required this.items, required this.ownerUsername,
    required this.timestampMicroseconds, required this.createdAtMicroseconds,
    required this.abuseReportingEnabled, required this.members, required this.permissions,
    required this.contentGenerationVersion, required this.cacheRefreshNeeded,
    required this.headlessState, this.appliedLenses = const [],
    this.availableSignals = const [], this.pendingChanges = const [],
    this.requestedLenses = const [], this.geoblock = const [],
    this.capabilities, this.cacheHintInfo});

  final List<int> revision;
  final api.ListAttributes attributes;
  final List<PlaylistCacheItem> items;
  final String ownerUsername;
  final int timestampMicroseconds;
  final int createdAtMicroseconds;
  final bool abuseReportingEnabled;
  final permission.GetMemberPermissionsResponse members;
  final permission.Permissions permissions;
  final int contentGenerationVersion;
  final bool cacheRefreshNeeded;
  final bool headlessState;
  final List<LensState> appliedLenses;
  final List<Signal> availableSignals;
  final List<api.Delta> pendingChanges;
  final List<String> requestedLenses;
  final List<api.GeoblockBlockingType> geoblock;
  final permission.Capabilities? capabilities;
  final cache.CacheHintInfo? cacheHintInfo;
}

/// Exact bounded native101ac27f4/101ac2998/101acf7ec cache projection.
/// Error mode0 clears,1 uses an explicit code or stored error,2 uses stored
/// error. Other native mode values leave the fresh error field absent.
/// Store lookup/write scheduling and invalid UTF-8 source recovery are separate.
Uint8List encodePlaylistCacheSnapshot(PlaylistCacheState state, {int errorMode = 0,
  int? errorCode, cache.PlaylistCacheInfo? storedInfo}) {
  final info = cache.PlaylistCacheInfo(
    cacheProducerVersion: 1,
    cacheRefreshNeeded: state.cacheRefreshNeeded,
    headlessState: state.headlessState,
    contentGenerationVersion: state.contentGenerationVersion.toUnsigned(32),
    cacheHintInfo: state.cacheHintInfo?.deepCopy());
  final mode = errorMode.toSigned(32);
  final int? effectiveError;
  if (mode == 1 && errorCode != null) {
    effectiveError = errorCode.toSigned(32);
  } else if ((mode == 1 || mode == 2) && storedInfo?.hasErrorCode() == true) {
    effectiveError = storedInfo!.errorCode.code;
  } else {
    effectiveError = null;
  }
  if (effectiveError != null) {
    info.errorCode = cache.ContextSyncErrorCode(code: effectiveError);
  }
  final selected = api.SelectedListContent(
    revision: state.revision,
    attributes: state.attributes.deepCopy(),
    contents: api.ListItems(pos: 0, truncated: false, items: [
      for (final item in state.items)
        api.Item(uri: item.canonicalUri, attributes: item.attributes.deepCopy()),
    ], availableSignals: [for (final signal in state.availableSignals) signal.deepCopy()]),
    timestamp: Int64(state.timestampMicroseconds.toSigned(64) ~/ 1000),
    createdAt: Int64(state.createdAtMicroseconds.toSigned(64) ~/ 1000),
    ownerUsername: state.ownerUsername,
    abuseReportingEnabled: state.abuseReportingEnabled,
    capabilities: state.capabilities?.deepCopy(),
    geoblock: state.geoblock);
  if (state.appliedLenses.isNotEmpty) {
    selected.appliedLenses = api.AppliedLenses(states: [
      for (final lens in state.appliedLenses) lens.deepCopy(),
    ]);
  }
  final snapshot = cache.Playlist(cacheInfo: info, selectedListContent: selected,
    playlistMembers: state.members.deepCopy(), permissions: state.permissions.deepCopy(),
    pendingChanges: cache.PendingPlaylistChanges(changes: [
      for (final change in state.pendingChanges) change.deepCopy(),
    ]), additionalData: cache.AdditionalData(requestedLenses: state.requestedLenses));
  snapshot.check();
  return nativeProto3Bytes(snapshot).asUnmodifiableView();
}
