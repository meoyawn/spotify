import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/pathfinder.dart';
import '../async/shared_task.dart';
import 'models.dart';
import 'repository.dart';

/// Original getTrack rich page and its separately owned related/credits reads.
class NativeSongEntityRepository implements EntityRepository, SongPageRepository {
  NativeSongEntityRepository(this.loader);
  final PathfinderLoader loader;
  final _credits = <String, ({SharedTask<EntityJson> task, DateTime expires})>{};

  static const trackOperation = PathfinderOperation(name: 'getTrack', operation: 'query',
    sha256Hash: 'a8ef9e9f02b836feb0da3003c31dbb30decc6f4b473ef89ca88c882386d668de', value: null);
  static const recommendationsOperation = PathfinderOperation(name: 'internalLinkRecommenderTrack', operation: 'query',
    sha256Hash: '642923b2e705fceb9984697c1620fecd42615fd8b116b8a9faf2786b389d3e4a', value: null);
  static const relatedAlbumsOperation = PathfinderOperation(name: 'similarAlbumsBasedOnThisTrack', operation: 'query',
    sha256Hash: '1d1f93a737498adca2c892c73af87fc0b052afe4e1a33c989540c32413dfae17', value: null);
  static const creditsOperation = PathfinderOperation(name: 'queryTrackCreditsGroupedModal', operation: 'query',
    sha256Hash: 'f135fb9be58a72d041ab5d214d817021a272405d883860468e2627afb01a3ca9', value: null);

  Future<EntityJson> _query(PathfinderOperation operation, EntityJson variables,
      CancellationToken? cancellationToken) async {
    cancellationToken?.throwIfCancelled();
    final response = _map(await loader.load(operation, variables, cancellationToken: cancellationToken));
    final errors = response['errors'];
    if (errors != null && errors != false && errors != '' && errors != 0) throw EntityQueryError(errors);
    return _map(response['data']);
  }

  @override Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    final related = RegExp(r'^spotify:app:track:([0-9A-Za-z]{22}):more-like-this$').firstMatch(uri);
    if (related != null) {
      final items = await songRelatedAlbums('spotify:track:${related[1]}', cancellationToken: cancellationToken);
      return EntityPage(details: EntityDetails.fromJson({'type': 'artist-section', 'uri': uri,
        'name': 'Recommended releases', 'nrTracks': items.length}),
        tracks: EntityTrackPage(rows: items.map(EntityRow.fromJson).toList(), offset: 0,
          limit: 50, totalLength: items.length));
    }
    if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)) {
      throw const EntityQueryError({'message': 'This song is unavailable.'});
    }
    final data = await _query(trackOperation, {'uri': uri,
      'includeVideoAssociationItems': true, 'includeMusicVideoPreviews': false}, cancellationToken);
    final track = _map(data['trackUnion']);
    if (track['__typename'] != 'Track') throw const EntityQueryError({'message': 'This song is unavailable.'});
    return _projectSongPage(track);
  }

  @override Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit,
      CancellationToken? cancellationToken}) async => offset == 0
    ? (await open(details.uri, cancellationToken: cancellationToken)).tracks
    : EntityTrackPage(offset: offset, limit: limit ?? 1, totalLength: details.trackCount);

  @override Future<List<EntityRow>> songRecommendations(String uri, {CancellationToken? cancellationToken}) async {
    final data = await _query(recommendationsOperation, {'uri': uri, 'limit': 5}, cancellationToken);
    return [for (final value in _list(_map(data['seoRecommendedTrack'])['items']))
      if (_map(_map(value)['data']) case final track when track['__typename'] == 'Track') _trackRow(track)];
  }

  @override Future<List<EntityJson>> songRelatedAlbums(String uri, {CancellationToken? cancellationToken}) async {
    final data = await _query(relatedAlbumsOperation, {'uri': uri, 'limit': 50, 'albumsOnly': true}, cancellationToken);
    return [for (final value in _list(_map(data['seoRecommendedTrackAlbum'])['items']))
      if (_map(_map(value)['data']) case final album when album['__typename'] == 'Album') _album(album)];
  }

  @override Future<EntityJson> songCredits(String uri, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    var cached = _credits.remove(uri);
    if (cached == null || cached.task.token.isCancelled || !cached.expires.isAfter(DateTime.now())) {
      cached = (task: SharedTask((token) => _query(creditsOperation,
        {'trackUri': uri, 'contributorsLimit': 100, 'contributorsOffset': 0}, token)),
        expires: DateTime.now().add(const Duration(minutes: 10)));
    }
    _credits[uri] = cached;
    while (_credits.length > 8) { _credits.remove(_credits.keys.first); }
    try { return await cached.task.wait(cancellationToken); }
    catch (error) {
      if ((error is! CancelledException || cached.task.token.isCancelled) &&
          identical(_credits[uri]?.task, cached.task)) { _credits.remove(uri); }
      rethrow;
    }
  }
}

EntityPage _projectSongPage(EntityJson track) {
  final row = _trackRow(track), album = _map(track['albumOfTrack']);
  final firstArtists = _list(_map(track['firstArtist'])['items']);
  final otherArtists = _list(_map(track['otherArtists'])['items']);
  final artists = firstArtists.isEmpty ? _list(_map(track['artists'])['items']) : [...firstArtists, ...otherArtists];
  final sections = <EntityJson>[];
  final first = _map(firstArtists.firstOrNull ?? artists.firstOrNull);
  final firstName = _map(first['profile'])['name'] as String? ?? '';
  final firstUri = first['uri'] as String? ?? '';
  final popular = [for (final value in _list(_map(_map(first['discography'])['topTracks'])['items']))
    if (_map(value)['track'] is Map) _trackRow(_map(_map(value)['track']))];
  if (popular.isNotEmpty) {
    sections.add({'kind': 'tracks', 'title': firstName, 'subtitle': 'Popular',
      'contextUri': firstUri, 'contextType': 'artist', 'items': popular.map((row) => row.data).toList()});
  }

  void releases(EntityJson artist, {bool other = false}) {
    final name = _map(artist['profile'])['name'] as String? ?? '';
    final artistUri = artist['uri'] as String? ?? '';
    final discography = _map(artist['discography']);
    for (final (key, title, route) in [
      ('popularReleasesAlbums', 'Popular releases by $name', 'album'),
      if (!other) ...[('albums', 'Popular albums by $name', 'album'),
        ('singles', 'Popular singles and EPs by $name', 'single')],
    ]) {
      final items = <EntityJson>[];
      for (final value in _list(_map(discography[key])['items'])) {
        final entry = _map(value);
        final raw = entry['releases'] is Map ? _map(_list(_map(entry['releases'])['items']).firstOrNull) : entry;
        if (raw['uri'] is String && raw['name'] is String) items.add(_album(raw));
      }
      if (items.isNotEmpty) {
        sections.add({'kind': 'cards', 'title': title, 'items': items,
          'otherArtist': other, 'seeAllUri': 'spotify:app:artist:${artistUri.split(':').last}:discography:$route'});
      }
    }
  }
  releases(first);
  for (final artist in otherArtists) { releases(_map(artist), other: true); }
  final related = [for (final value in _list(_map(_map(first['relatedContent'])['relatedArtists'])['items']))
    if (_map(value)['uri'] is String) _artist(_map(value))];
  final details = EntityDetails.fromJson({...row.data, 'songPage': true,
    'artists': [for (final value in firstArtists.isEmpty ? artists : firstArtists) _artist(_map(value))],
    'songArtists': [for (final value in artists) _artist(_map(value))],
    'songSections': sections, 'relatedArtists': related,
    'relatedArtistsUri': 'spotify:app:artist:${firstUri.split(':').last}:related',
    'release': album['date'], 'copyright': album['copyright'], 'courtesyLine': album['courtesyLine'],
    'extractedColors': _map(album['coverArt'])['extractedColors'],
    'dynamicColors': _songColors(track),
    'nrTracks': 1, 'hasSpotifyTracks': true, 'hasEpisodes': false}, source: track);
  return EntityPage(details: details, tracks: EntityTrackPage(rows: [row], offset: 0, limit: 1, totalLength: 1));
}

EntityRow _trackRow(EntityJson track) {
  final artists = _list(_map(track['artists'])['items']);
  final credited = artists.isEmpty ? [..._list(_map(track['firstArtist'])['items']),
    ..._list(_map(track['otherArtists'])['items'])] : artists;
  final album = _map(track['albumOfTrack']);
  return EntityRow.fromJson({'type': 'track', 'uri': track['uri'], 'name': track['name'],
    'artists': [for (final value in credited) _artist(_map(value))],
    'album': album.isEmpty ? null : _album(album), 'images': _map(album['coverArt'])['sources'] ?? const [],
    'duration': {'milliseconds': _map(track['duration'])['totalMilliseconds']},
    'isPlayable': _map(track['playability'])['playable'] == true,
    'isExplicit': _map(track['contentRating'])['label'] == 'EXPLICIT',
    'playcount': int.tryParse('${track['playcount'] ?? ''}') ?? 0,
    'trackNumber': track['trackNumber'], 'discNumber': track['discNumber'],
    if (_map(_map(track['relinkingInformation'])['linkedTrack'])['uri'] case final String linked) 'linkedUri': linked,
  }, source: track);
}

EntityJson _artist(EntityJson artist) => {'type': 'artist', 'uri': artist['uri'], 'id': artist['id'],
  'name': _map(artist['profile'])['name'] ?? artist['name'] ?? '',
  'images': _map(_map(artist['visuals'])['avatarImage'])['sources'] ?? const [], 'subtitle': 'Artist'};

EntityJson _album(EntityJson album) => {'type': 'album', 'uri': album['uri'], 'name': album['name'],
  'albumType': album['type'], 'images': _map(album['coverArt'])['sources'] ?? const [],
  'artists': [for (final value in _list(_map(album['artists'])['items'])) _artist(_map(value))],
  'year': _map(album['date'])['year'],
  'subtitle': [if (_map(album['date'])['year'] != null) '${_map(album['date'])['year']}',
    switch (album['type']) { 'SINGLE' => 'Single', 'EP' => 'EP', 'COMPILATION' => 'Compilation', _ => 'Album' }].join(' • ')};

EntityJson _songColors(EntityJson track) {
  final set = _map(_map(_map(track['visualIdentity'])['squareCoverImage'])['extractedColorSet']);
  final palette = _map(set['higherContrast']);
  int? color(Object? value) {
    final channels = _map(value);
    if (channels['red'] is! int || channels['green'] is! int || channels['blue'] is! int) return null;
    return ((channels['alpha'] as int? ?? 255) << 24) | ((channels['red'] as int) << 16) |
      ((channels['green'] as int) << 8) | (channels['blue'] as int);
  }
  return {'backgroundBase': color(palette['backgroundBase']), 'backgroundTinted': color(palette['backgroundTintedBase'])};
}

EntityJson _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
List<Object?> _list(Object? value) => value is List ? value : const [];
