import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/pathfinder.dart';
import '../protocol/generated/playlist_api.pb.dart' as playlist;
import 'models.dart';
import 'repository.dart';

/// Original renderer87922 overview plus54896's separate top-track URI read.
/// The desktop supplies the original native popular-release list reader.
/// Outgoing source execution: reverse-engineering/evidence/native-renderer-artist.json.
class NativeArtistEntityRepository implements EntityRepository {
  NativeArtistEntityRepository(this.loader, {required this.describeTracks,
    required this.preReleaseV2, this.readPopularTracks, this.locale = ''});

  final PathfinderLoader loader;
  final Future<Map<String, EntityRow>> Function(List<String> uris, {CancellationToken? cancellationToken}) describeTracks;
  final Future<playlist.SelectedListContent> Function(String uri, {CancellationToken? cancellationToken})? readPopularTracks;
  final bool preReleaseV2;
  final String locale;
  final _tracks = <String, _ArtistTracks>{};
  final _sectionInfo = <String, ({String name, Map<String, int> counts, DateTime expires})>{};

  static const overviewOperation = PathfinderOperation(name: 'queryArtistOverview', operation: 'query',
    sha256Hash: '9f8134ef565e78621f1e1793555bd6633c5ac144ae0f89604ed3ae3f80b3c8e6', value: null);
  static const topTracksOperation = PathfinderOperation(name: 'getArtistNameAndTracks', operation: 'query',
    sha256Hash: '0adaf1a1a8a94c7ed095639c4d9456d2b1cfac16ac511d5dd2b01b6dd89f748a', value: null);
  static const _discographyHash = '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599';
  static const _sectionOperations = {
    'overview': PathfinderOperation(name: 'queryArtistDiscographyOverview', operation: 'query', sha256Hash: _discographyHash, value: null),
    'albums': PathfinderOperation(name: 'queryArtistDiscographyAlbums', operation: 'query', sha256Hash: _discographyHash, value: null),
    'singles': PathfinderOperation(name: 'queryArtistDiscographySingles', operation: 'query', sha256Hash: _discographyHash, value: null),
    'compilations': PathfinderOperation(name: 'queryArtistDiscographyCompilations', operation: 'query', sha256Hash: _discographyHash, value: null),
    'all': PathfinderOperation(name: 'queryArtistDiscographyAll', operation: 'query', sha256Hash: _discographyHash, value: null),
    'related': PathfinderOperation(name: 'queryArtistRelated', operation: 'query', sha256Hash: '3d031d6cb22a2aa7c8d203d49b49df731f58b1e2799cc38d9876d58771aa66f3', value: null),
    'appearsOn': PathfinderOperation(name: 'queryArtistAppearsOn', operation: 'query', sha256Hash: '9a4bb7a20d6720fe52d7b47bc001cfa91940ddf5e7113761460b4a288d18a4c1', value: null),
    'featuring': PathfinderOperation(name: 'queryArtistFeaturing', operation: 'query', sha256Hash: '20842d6d9d2d28ef945984b68cb927bb33edd00eab84a8da1667def21f1f2c54', value: null),
    'discoveredOn': PathfinderOperation(name: 'queryArtistDiscoveredOn', operation: 'query', sha256Hash: '71c2392e4cecf6b48b9ad1311ae08838cbdabcfd189c6bf0c66c2430b8dcfdb1', value: null),
  };

  @override
  Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final section = RegExp(r'^spotify:app:artist:([0-9A-Za-z]{22}):(discography:(all|album|single|compilation)|related|appears-on|featuring|discovered-on)$').firstMatch(uri);
    if (section != null) return _openSection(uri, 'spotify:artist:${section[1]}', section[2]!, cancellationToken);
    if (!RegExp(r'^spotify:artist:[0-9A-Za-z]{22}$').hasMatch(uri)) {
      throw const EntityQueryError({'message': 'This artist URI is unavailable.'});
    }
    final overview = await _query(overviewOperation,
      {'uri': uri, 'locale': locale, 'preReleaseV2': preReleaseV2},
      headers: const {'spotify-app-version': '896000000'}, cancellationToken: cancellationToken);
    final artist = _artist(_map(overview['data'])['artistUnion']);
    _rememberSectionInfo(uri, artist);
    final read = readPopularTracks;
    final EntityJson topTracks;
    final source = _ArtistTracks();
    if (read == null) {
      topTracks = await _trackPage(uri, 0, cancellationToken);
      source.append(topTracks);
    } else {
      final listUri = 'spotify:list:popular-release-segments-main-roles:artist_${uri.split(':').last}';
      final snapshot = await read(listUri, cancellationToken: cancellationToken);
      if (!snapshot.hasContents() || snapshot.contents.pos != 0 || snapshot.contents.truncated ||
          snapshot.hasLength() && snapshot.length != snapshot.contents.items.length) {
        throw const EntityQueryError({'message': 'This artist’s popular tracks are currently incomplete.'});
      }
      source.append({'items': [for (final item in snapshot.contents.items) {'track': {'uri': item.uri}}]});
      topTracks = {'uri': listUri, 'snapshot': snapshot};
    }
    _tracks[uri] = source;
    final page = await _rows(uri, offset: 0, limit: 10, cancellationToken: cancellationToken);
    final profile = _map(artist['profile']);
    final images = _images(_map(_map(artist['visuals'])['avatarImage'])['sources']);
    return EntityPage(details: EntityDetails.fromJson({
      'type': 'artist', 'uri': uri, 'name': profile['name'], 'images': images,
      'trackHeading': read == null ? 'Top tracks' : 'Popular',
      if (read != null) 'playbackUri': topTracks['uri'],
      if (read != null) 'nrTracks': source.uris.length,
      'canRequestPlayback': page.rows.any((row) => row.canRequestPlayback),
      if (artist['stats'] is Map) 'stats': artist['stats'],
      'biography': _map(profile['biography'])['text'],
      'artistSections': _sections(artist, artistUri: uri),
    }, source: {'artist': artist, 'topTracks': topTracks}), tracks: page);
  }

  Future<EntityJson> _trackPage(String uri, int offset, CancellationToken? cancellationToken) async {
    final response = await _query(topTracksOperation, {'uri': uri, 'offset': offset, 'limit': 200},
      cancellationToken: cancellationToken);
    final artist = _artist(_map(response['data'])['artistUnion']);
    final topTracks = _map(_map(artist['discography'])['topTracks']);
    if (topTracks['items'] is! List) {
      throw const EntityQueryError({'message': 'This artist’s tracks are currently unavailable.'});
    }
    return topTracks;
  }

  @override
  Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) =>
    details.type == 'artist-section' ? _sectionRows(details.data['artistUri'] as String,
      details.data['sectionId'] as String, offset: offset, limit: limit ?? 50,
      total: details.trackCount, cancellationToken: cancellationToken)
      : _rows(details.uri, offset: offset, limit: limit ?? 50, cancellationToken: cancellationToken);

  void _rememberSectionInfo(String uri, EntityJson artist) {
    final discography = _map(artist['discography']);
    _sectionInfo.remove(uri);
    _sectionInfo[uri] = (name: _map(artist['profile'])['name'] as String,
      counts: {for (final key in ['all', 'albums', 'singles', 'compilations'])
        if (_map(discography[key])['totalCount'] is int) key: _map(discography[key])['totalCount'] as int},
      expires: DateTime.now().add(const Duration(minutes: 5)));
    while (_sectionInfo.length > 16) { _sectionInfo.remove(_sectionInfo.keys.first); }
  }

  Future<EntityPage> _openSection(String routeUri, String artistUri, String route, CancellationToken? cancellationToken) async {
    final discography = route.startsWith('discography:');
    final key = switch (route) {
      'discography:album' => 'albums', 'discography:single' => 'singles',
      'discography:compilation' => 'compilations', 'discography:all' => 'all',
      'appears-on' => 'appearsOn', 'discovered-on' => 'discoveredOn', _ => route,
    };
    var info = _sectionInfo[artistUri];
    if (discography && (info == null || !info.expires.isAfter(DateTime.now()) || !info.counts.containsKey(key))) {
      final response = await _query(_sectionOperations['overview']!, {'uri': artistUri}, cancellationToken: cancellationToken);
      _rememberSectionInfo(artistUri, _artist(_map(response['data'])['artistUnion']));
      info = _sectionInfo[artistUri];
    }
    final page = await _sectionRows(artistUri, key, offset: 0, limit: 50, total: info?.counts[key],
      cancellationToken: cancellationToken);
    final name = _sectionInfo[artistUri]?.name ?? info?.name ?? '';
    return EntityPage(details: EntityDetails.fromJson({'type': 'artist-section', 'uri': routeUri,
      'name': _sectionTitle(key, name), 'artistUri': artistUri, 'artistName': name,
      'sectionId': key, 'nrTracks': page.totalLength}), tracks: page);
  }

  Future<EntityTrackPage> _sectionRows(String uri, String key, {required int offset,
      required int limit, int? total, CancellationToken? cancellationToken}) async {
    if (offset < 0 || limit < 1) throw ArgumentError('Invalid artist section page');
    final discography = const {'all', 'albums', 'singles', 'compilations'}.contains(key);
    final response = await _query(_sectionOperations[key]!, {'uri': uri,
      if (discography) ...{'offset': offset, 'limit': limit, 'order': 'DATE_DESC'}}, cancellationToken: cancellationToken);
    final artist = _artist(_map(response['data'])['artistUnion'], requireName: false);
    final name = _map(artist['profile'])['name'] as String? ?? _sectionInfo[uri]?.name ?? '';
    final branch = _map(_map(artist[discography ? 'discography' : 'relatedContent'])[
      switch (key) { 'related' => 'relatedArtists', 'featuring' => 'featuringV2', 'discoveredOn' => 'discoveredOnV2', _ => key }]);
    final rawItems = _list(branch['items']);
    final section = _sections(artist, artistUri: uri, artistName: name).where((section) => section['id'] == key).firstOrNull;
    final cards = _list(section?['items']).cast<EntityJson>();
    final count = discography ? branch['totalCount'] as int? ?? total : cards.length;
    if (count == null) throw const EntityQueryError({'message': 'This artist’s release count is unavailable.'});
    if (!_sectionInfo.containsKey(uri)) {
      _sectionInfo[uri] = (name: name, counts: const {}, expires: DateTime.now().add(const Duration(minutes: 5)));
      while (_sectionInfo.length > 16) { _sectionInfo.remove(_sectionInfo.keys.first); }
    }
    return EntityTrackPage(rows: [for (final card in cards) EntityRow.fromJson(card)],
      offset: offset, limit: limit, totalLength: count,
      nextOffset: discography ? offset + rawItems.length : cards.length);
  }

  Future<EntityTrackPage> _rows(String uri, {required int offset, required int limit,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (offset < 0 || limit < 1) throw ArgumentError('Invalid artist track page');
    final source = _tracks[uri];
    if (source == null) {
      throw const EntityQueryError({'message': 'Open the artist again to load its tracks.'});
    }
    while (offset + limit > source.uris.length && source.nextOffset != null) {
      final cursor = source.nextOffset!;
      final page = await _trackPage(uri, cursor, cancellationToken);
      source.append(page, previousOffset: cursor);
    }
    final selected = source.uris.skip(offset).take(limit).toList(growable: false);
    final missing = selected.where((value) => !source.descriptions.containsKey(value)).toSet().toList(growable: false);
    for (var start = 0; start < missing.length; start += 50) {
      // The injected original Track metadata request plan admits at most50.
      source.descriptions.addAll(await describeTracks(missing.skip(start).take(50).toList(growable: false),
        cancellationToken: cancellationToken));
    }
    final rows = <EntityRow>[];
    for (final trackUri in selected) {
      final row = source.descriptions[trackUri];
      if (row == null || !row.isSupported) {
        rows.add(EntityRow.unsupported(source: {'uri': trackUri}));
      } else {
        rows.add(EntityRow.fromJson({...row.data, 'uri': trackUri}, source: row.source,
          unsupportedFeatures: row.unsupportedFeatures));
      }
    }
    return EntityTrackPage(rows: rows, offset: offset, limit: limit,
      totalLength: source.uris.length + (source.nextOffset == null ? 0 : 1));
  }

  Future<EntityJson> _query(PathfinderOperation operation, EntityJson variables,
      {Map<String, String> headers = const {}, CancellationToken? cancellationToken}) async {
    final Object? response;
    try {
      response = await loader.load(operation, variables, headers: headers, cancellationToken: cancellationToken);
    } on CancelledException { rethrow; } catch (error) {
      throw EntityQueryError(error.toString());
    }
    final body = _map(response);
    final errors = body['errors'];
    // Original92693 rejects every truthy errors member, including an empty list.
    if (errors != null && errors != false && errors != '' && errors != 0) {
      throw EntityQueryError(errors);
    }
    return body;
  }
}

class _ArtistTracks {
  final uris = <String>[];
  final descriptions = <String, EntityRow>{};
  int? nextOffset;

  void append(EntityJson page, {int previousOffset = -1}) {
    final items = page['items'] as List;
    final next = _map(page['pagingInfo'])['nextOffset'];
    if (next != null && (next is! int || next <= previousOffset || items.isEmpty)) {
      throw const EntityQueryError({'message': 'This artist’s track cursor is invalid.'});
    }
    final incoming = <String>[];
    for (final item in items) {
      final uri = _map(_map(item)['track'])['uri'];
      if (uri is! String || !RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)) {
        throw const EntityQueryError({'message': 'This artist’s track metadata is incomplete.'});
      }
      incoming.add(uri);
    }
    uris.addAll(incoming);
    nextOffset = next as int?;
  }
}

List<Object?> _list(Object? value) => value is List ? value : const [];

String _sectionTitle(String key, String name) => switch (key) {
  'all' => 'Discography', 'albums' => 'Albums', 'singles' => 'Singles and EPs', 'compilations' => 'Compilations',
  'related' => 'Fans also like', 'appearsOn' => 'Appears on', 'featuring' => 'Featuring $name',
  'discoveredOn' => 'Discovered on', _ => '',
};

List<EntityJson> _sections(EntityJson artist, {required String artistUri, String artistName = ''}) {
  final discography = _map(artist['discography']), related = _map(artist['relatedContent']);
  final name = _map(artist['profile'])['name'] as String? ?? artistName;
  EntityJson? album(Object? value) {
    var record = _map(value);
    if (record.containsKey('releases')) {
      record = _map(_list(_map(record['releases'])['items']).firstOrNull);
    }
    final link = EntityLink.fromJson(record, type: 'album');
    if (link == null) return null;
    return {'type': 'album', 'uri': link.uri, 'name': link.name,
      'images': _images(_map(record['coverArt'])['sources']),
      'subtitle': [if (_map(record['date'])['year'] != null) _map(record['date'])['year'],
        switch (record['type']) { 'SINGLE' => 'Single', 'EP' => 'EP', 'COMPILATION' => 'Compilation', _ => 'Album' }].join(' • ')};
  }
  EntityJson? playlist(Object? value) {
    final record = _map(_map(value)['data']);
    if (record['__typename'] != 'Playlist') return null;
    final link = EntityLink.fromJson(record, type: 'playlist');
    if (link == null) return null;
    return {'type': 'playlist', 'uri': link.uri, 'name': link.name,
      'images': _images(_map(_list(_map(record['images'])['items']).firstOrNull)['sources']),
      'subtitle': _map(_map(record['ownerV2'])['data'])['name'] ?? ''};
  }
  EntityJson? relatedArtist(Object? value) {
    final record = _map(value), profile = _map(_map(value)['profile']);
    final link = EntityLink.fromJson({'uri': record['uri'], 'name': profile['name']}, type: 'artist');
    if (link == null) return null;
    return {'type': 'artist', 'uri': link.uri, 'name': link.name,
      'images': _images(_map(_map(record['visuals'])['avatarImage'])['sources']), 'subtitle': 'Artist'};
  }
  final popular = _list(_map(discography['popularReleasesAlbums'])['items']);
  final latest = _map(discography['latest']);
  final releases = [if (latest.isNotEmpty) latest,
    ...popular.where((item) => latest.isEmpty || _map(item)['uri'] != latest['uri'])];
  EntityJson section(String id, String title, Iterable<Object?> items,
      EntityJson? Function(Object?) project) => {'id': id, 'title': title,
    'seeAllUri': 'spotify:app:artist:${artistUri.split(':').last}:${switch (id) {
      'popularReleasesAlbums' || 'all' => 'discography:all', 'albums' => 'discography:album',
      'singles' => 'discography:single', 'compilations' => 'discography:compilation',
      'appearsOn' => 'appears-on', 'discoveredOn' => 'discovered-on', _ => id,
    }}',
    'items': items.map(project).whereType<EntityJson>().toList(growable: false)};
  return [
    section('popularReleasesAlbums', 'Popular releases', releases, album),
    for (final (key, label) in const [('all', 'All releases'), ('albums', 'Albums'), ('singles', 'Singles and EPs'), ('compilations', 'Compilations')])
      section(key, label, _list(_map(discography[key])['items']), album),
    section('featuring', 'Featuring $name', _list(_map(related['featuringV2'])['items']), playlist),
    section('related', 'Fans also like', _list(_map(related['relatedArtists'])['items']), relatedArtist),
    section('appearsOn', 'Appears on', _list(_map(related['appearsOn'])['items']), album),
    section('discoveredOn', 'Discovered on', _list(_map(related['discoveredOnV2'])['items']), playlist),
  ].where((section) => (section['items'] as List).isNotEmpty).toList(growable: false);
}

EntityJson _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};

EntityJson _artist(Object? value, {bool requireName = true}) {
  final artist = _map(value);
  if (artist['__typename'] != 'Artist' || requireName && _map(artist['profile'])['name'] is! String) {
    throw const EntityQueryError({'message': 'This artist is currently unavailable.'});
  }
  return artist;
}

List<EntityJson> _images(Object? values) => values is! List ? [] : [
  for (final value in values)
    if (_map(value)['url'] is String && (_map(value)['url'] as String).isNotEmpty)
      {'url': _map(value)['url'],
        if (_map(value)['width'] is num) 'width': _map(value)['width'],
        if (_map(value)['height'] is num) 'height': _map(value)['height']},
];
