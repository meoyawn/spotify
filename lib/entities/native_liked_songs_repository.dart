import 'package:cancellation_token/cancellation_token.dart';
import 'package:flutter/foundation.dart' show Listenable;

import '../library/liked_songs.dart';
import '../library/native_collection_read_client.dart';
import '../protocol/generated/collection2v2.pb.dart';
import 'models.dart';
import 'playlist_dates.dart';
import 'repository.dart';

/// Liked Songs is the account collection, including rows beyond the native
/// playlist response's range. Metadata is requested only for the displayed page.
class NativeLikedSongsRepository implements EntityRepository, UpdatingEntityRepository {
  NativeLikedSongsRepository({required this.collection, required this.describeTracks, required this.username});
  final NativeCollectionReadClient collection;
  final String username;
  final Future<Map<String, EntityRow>> Function(List<String>, {CancellationToken? cancellationToken}) describeTracks;
  List<CollectionItem>? _items;

  @override Listenable? changesFor(String uri) => uri == likedSongsUri ? collection.changes : null;

  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    if (uri != likedSongsUri) throw ArgumentError.value(uri, 'uri');
    final items = (await collection.items(cancellationToken: cancellationToken))
      .where((item) => RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(item.uri)).toList();
    cancellationToken?.throwIfCancelled();
    // Preserve membership order when additions have the same timestamp.
    final order = {for (final (index, item) in items.indexed) item.uri: index};
    items.sort((a, b) {
      final time = b.addedAt.compareTo(a.addedAt);
      return time != 0 ? time : order[a.uri]!.compareTo(order[b.uri]!);
    });
    _items = items;
    final page = await _page(items, offset: 0, limit: 50, cancellationToken: cancellationToken);
    return EntityPage(details: EntityDetails.fromJson({
      'type': 'playlist', 'uri': likedSongsUri, 'name': 'Liked Songs',
      'images': likedSongsImages, 'extractedColors': {'colorRaw': '#5038a0'},
      'owner': {'username': username}, 'isOwnedBySelf': true,
      'nrTracks': items.length, 'hasDateAdded': true,
      'hasSpotifyTracks': items.isNotEmpty, 'hasEpisodes': false,
      'canRequestPlayback': page.rows.any((row) => row.canRequestPlayback),
      'permissions': {'canView': true},
    }, source: {'playbackUris': items.map((item) => item.uri).toList(growable: false)}), tracks: page);
  }

  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit,
      CancellationToken? cancellationToken}) {
    final items = _items;
    if (items == null || details.uri != likedSongsUri) {
      throw const EntityQueryError({'message': 'Open Liked Songs again to load its tracks.'});
    }
    return _page(items, offset: offset, limit: limit ?? 50, cancellationToken: cancellationToken);
  }

  Future<EntityTrackPage> _page(List<CollectionItem> items, {required int offset, required int limit,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (offset < 0 || limit < 1 || limit > 50) throw RangeError('Invalid Liked Songs page');
    final selected = items.skip(offset).take(limit).toList(growable: false);
    final descriptions = selected.isEmpty ? <String, EntityRow>{}
      : await describeTracks(selected.map((item) => item.uri).toList(), cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    return EntityTrackPage(offset: offset, limit: limit, totalLength: items.length,
      nextOffset: offset + selected.length, rows: [for (final item in selected)
        if (descriptions[item.uri] case final row?) EntityRow.fromJson({...row.data,
          'uri': item.uri, 'isSaved': true,
          if (item.addedAt > 0) 'addedAt': playlistTimestampIso(item.addedAt.toInt() * 1000),
        }, source: row.source, unsupportedFeatures: row.unsupportedFeatures)
        else EntityRow.unsupported(source: {'uri': item.uri})]);
  }
}
