import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/generated/playlist_api.pb.dart' as playlist;
import '../protocol/native_playlist_images.dart';
import 'models.dart';
import 'playlist_dates.dart';
import 'repository.dart';

/// Fresh online snapshots and their real server metadata. Synchronization,
/// offline indexes and decorated PlaylistDataService mutations are separate.
class NativePlaylistEntityRepository implements EntityRepository {
  NativePlaylistEntityRepository({required this.read, required this.describeTracks,
    required this.imageUrlTemplate, this.presentation, this.saved, this.username});

  final Future<playlist.SelectedListContent> Function(String uri, {CancellationToken? cancellationToken}) read;
  final Future<Map<String, EntityRow>> Function(List<String> uris, {CancellationToken? cancellationToken}) describeTracks;
  final String imageUrlTemplate;
  final String? username;
  final Future<bool> Function(String uri, {CancellationToken? cancellationToken})? saved;
  /// Already observed Home labels/colors, never an extra profile/metadata read.
  final EntityJson Function(String uri)? presentation;
  final _snapshots = <String, playlist.SelectedListContent>{};
  final _descriptions = <String, EntityRow>{};

  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final snapshot = await read(uri, cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    if (snapshot.contents.pos != 0 || snapshot.contents.truncated) {
      throw const EntityQueryError({'message': 'The complete playlist is currently unavailable.'});
    }
    _snapshots[uri] = snapshot;
    // Reproject against the metadata owner's real freshness/relink cache.
    // A fresh playlist open must not retain a previous raw, unlinked row.
    _descriptions.clear();
    final tracks = await _tracks(snapshot, offset: 0, limit: 50, cancellationToken: cancellationToken);
    final attributes = snapshot.attributes;
    final format = {for (final attribute in attributes.formatAttributes) attribute.key: attribute.value};
    final observed = presentation?.call(uri) ?? const <String, Object?>{};
    final madeFor = format['madeFor.username'];
    final details = EntityDetails.fromJson({
      'type': 'playlist', 'uri': uri, 'name': attributes.name,
      if (saved != null) 'isSaved': await saved!(uri, cancellationToken: cancellationToken),
      if (username != null) 'isOwnedBySelf': snapshot.ownerUsername == username,
      'description': attributes.description,
      'hasDateAdded': playlistHasDateAdded(attributes.format),
      'formatListData': {'type': attributes.format, 'attributes': format},
      if (snapshot.hasCreatedAt()) 'createdAt': playlistTimestampIso(snapshot.createdAt.toInt()),
      'images': nativePlaylistImages(attributes, imageUrlTemplate: imageUrlTemplate),
      'owner': {'username': snapshot.ownerUsername,
        if (observed['ownerUsername'] == snapshot.ownerUsername) 'displayName': observed['ownerName']},
      if (format['madeFor.displayed'] == '1' && madeFor != null && madeFor.isNotEmpty)
        'madeFor': {'type': 'user', 'username': madeFor, 'uri': 'spotify:user:$madeFor',
          'displayName': observed['madeForName'] ?? madeFor},
      if (observed['extractedColors'] != null) 'extractedColors': observed['extractedColors'],
      'nrTracks': snapshot.hasLength() ? snapshot.length : snapshot.contents.items.length,
      'permissions': {'canView': !snapshot.hasCapabilities() ||
        !snapshot.capabilities.hasCanView() || snapshot.capabilities.canView},
      'hasEpisodes': snapshot.contents.items.any((item) => item.uri.startsWith('spotify:episode:')),
      'hasSpotifyTracks': snapshot.contents.items.any((item) => item.uri.startsWith('spotify:track:')),
      'canRequestPlayback': tracks.rows.any((row) => row.canRequestPlayback),
    }, unsupportedFeatures: const ['decorated-playlist-state', 'offline-library']);
    return EntityPage(details: details, tracks: tracks);
  }

  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) async {
    final snapshot = _snapshots[details.uri];
    if (snapshot == null) throw const EntityQueryError({'message': 'Open the playlist again to load its tracks.'});
    return _tracks(snapshot, offset: offset, limit: limit ?? 50, cancellationToken: cancellationToken);
  }

  Future<EntityTrackPage> _tracks(playlist.SelectedListContent snapshot,
      {required int offset, required int limit, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (offset < 0 || limit < 1) throw ArgumentError('Invalid playlist page');
    final items = snapshot.contents.items.skip(offset).take(limit).toList(growable: false);
    final missing = <String>{for (final item in items)
      if (RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(item.uri) &&
          !_descriptions.containsKey(item.uri)) item.uri}.toList(growable: false);
    if (missing.isNotEmpty) _descriptions.addAll(await describeTracks(missing, cancellationToken: cancellationToken));
    final rows = <EntityRow>[];
    for (final item in items) {
      final description = _descriptions[item.uri];
      if (description == null) {
        rows.add(EntityRow.unsupported(source: {'uri': item.uri}));
        continue;
      }
      rows.add(EntityRow.fromJson({...description.data,
        'uri': item.uri,
        if (item.attributes.hasTimestamp()) 'addedAt': playlistTimestampIso(item.attributes.timestamp.toInt()),
      }, source: {'uri': item.uri,
        if (item.attributes.hasTimestamp()) 'addedAtMilliseconds': item.attributes.timestamp.toString()},
        unsupportedFeatures: description.unsupportedFeatures));
    }
    return EntityTrackPage(rows: rows, offset: offset, limit: limit,
      totalLength: snapshot.contents.items.length);
  }
}
