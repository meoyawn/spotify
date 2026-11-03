part of 'repository.dart';

List<EntityJson> _albumImages(Object? value) => _list(value).map((item) {
  final source = _map(item);
  return <String, Object?>{'url': source['url'],
    if (_truthy(source['width'])) 'width': source['width'],
    if (_truthy(source['height'])) 'height': source['height']};
}).toList();

List<EntityRow> _albumRows(EntityJson tracks, EntityJson discs) {
  final rows = <EntityRow>[];
  var previousTrack = 0;
  final count = discs['totalCount'] as int? ?? 0;
  final showDiscs = count >= 2 && count <= 10;
  for (final value in _list(tracks['items'])) {
    final entry = _map(value);
    if (!entry.containsKey('track') || entry['track'] is! Map) continue;
    final track = _map(entry['track']);
    final number = track['trackNumber'] as int? ?? 0;
    if (showDiscs && (number < previousTrack || number == 1)) {
      rows.add(EntityRow.fromJson({'type': 'AlbumDisc', 'discNumber': track['discNumber'], 'nrTracks': null}));
    }
    final linked = _map(_map(track['relinkingInformation'])['linkedTrack']);
    rows.add(EntityRow.fromJson({
      'type': 'track', if (entry.containsKey('uid')) 'uid': entry['uid'],
      'uri': track['uri'], 'name': track['name'],
      'artists': _list(_map(track['artists'])['items']).map((artist) => {
        'uri': _map(artist)['uri'], 'name': _map(_map(artist)['profile'])['name'],
      }).toList(),
      'duration': {'milliseconds': _map(track['duration'])['totalMilliseconds']}, 'album': null,
      'discNumber': track['discNumber'], 'trackNumber': track['trackNumber'],
      'isPlayable': _map(track['playability'])['playable'], 'isLocal': false,
      'isExplicit': _map(track['contentRating'])['label'] == 'EXPLICIT',
      'is19PlusOnly': _map(track['contentRating'])['label'] == 'NINETEEN_PLUS',
      if (track.containsKey('saved')) 'isSaved': track['saved'],
      'playcount': track['playcount'] ?? '',
      'linkedUri': linked['__typename'] == 'Track' ? linked['uri'] : null,
      'hasAssociatedVideo': (_map(_map(track['associationsV3'])['videoAssociations'])['totalCount'] as num? ?? 0) > 0,
      'isBanned': false,
    }, source: entry));
    previousTrack = number;
  }
  return rows;
}

EntityPage _albumPage(EntityJson album, String? timeZone) {
  final tracks = _map(album['tracksV2']);
  final discs = <String, Object?>{'totalCount': _map(album['discs'])['totalCount'],
    'items': _list(_map(album['discs'])['items']).map((disc) => {'type': 'AlbumDisc',
      'discNumber': _map(disc)['number'], 'nrTracks': _map(_map(disc)['tracks'])['totalCount']}).toList()};
  final trackEntries = _list(tracks['items']);
  final actualTracks = trackEntries.map(_map).where((entry) => entry['track'] is Map).toList();
  final total = tracks['totalCount'] as int? ?? 0;
  final duration = actualTracks.fold<num>(0, (sum, entry) => sum + (_map(_map(entry['track'])['duration'])['totalMilliseconds'] as num));
  // Popular releases are optional source metadata, independent of the track page.
  final releases = _list(_map(_map(_map(_list(_map(album['moreAlbumsByArtist'])['items']).firstOrNull)['discography'])['popularReleasesAlbums'])['items']);
  final watch = _map(album['watchFeedEntrypoint']);
  final video = _map(watch['video']);
  final videoType = {'MANIFEST_ID', 'URL'}.contains(video['videoType']) ? video['videoType'] : null;
  final thumbnail = _map(_map(watch['thumbnailImage'])['data']);
  final metadata = <String, Object?>{
    'type': 'album', 'uri': album['uri'], 'name': album['name'],
    'artists': _list(_map(album['artists'])['items']).map((artist) {
      final source = _map(artist);
      return {'type': 'artist', 'name': _map(source['profile'])['name'],
        'images': _albumImages(_map(_map(source['visuals'])['avatarImage'])['sources']),
        'uri': source['uri'], if (source.containsKey('id')) 'id': source['id']};
    }).toList(),
    'images': _albumImages(_map(album['coverArt'])['sources']),
    'moreAlbumsByArtist': releases.map((value) {
      final release = _map(value);
      return {'type': 'album', 'uri': release['uri'], 'albumType': release['type'],
        'name': release['name'], 'images': _albumImages(_map(release['coverArt'])['sources']),
        'artists': [], if (release.containsKey('sharingInfo')) 'sharingInfo': release['sharingInfo'],
        if (_map(release['date']).containsKey('year')) 'year': _map(release['date'])['year']};
    }).toList(),
    'nrTracks': total, 'isPlayable': actualTracks.any((entry) => _map(_map(entry['track'])['playability'])['playable'] == true),
    if (album.containsKey('saved')) 'isSaved': album['saved'],
    'isCatalogueRestricted': _map(album['playability'])['reason'] == 'CATALOGUE_RESTRICTED',
    'discs': discs, if (album.containsKey('copyright')) 'copyright': album['copyright'], 'albumType': album['type'],
    'duration': {'durationMs': trackEntries.isEmpty ? 0 : duration / trackEntries.length * total,
      'isEstimate': trackEntries.length < total},
    if (album.containsKey('releases')) 'releases': album['releases'],
    'extractedColors': _map(album['coverArt'])['extractedColors'], 'courtesyLine': album['courtesyLine'],
    'sharingInfo': album['sharingInfo'],
    if (album['date'] != null) 'release': {'isoString': _map(album['date'])['isoString'], 'precision': _map(album['date'])['precision']},
    'dynamicColors': null,
    'watchFeedEntityEntryPoint': album['watchFeedEntrypoint'] == null ? null : {
      'feedUri': watch['entrypointUri'], 'video': video['fileId'] != null && videoType != null ? {
        'urlOrFileId': video['fileId'], 'type': videoType,
        if (video.containsKey('startTime')) 'startTime': video['startTime'],
        if (video.containsKey('endTime')) 'endTime': video['endTime'],
      } : null, 'thumbnail': thumbnail['__typename'] == 'ImageV2' ? {'url': thumbnail['imageId']} : null,
    },
    'preReleaseEndDateTime': album['preReleaseEndDateTime'], 'prereleaseDisplayTimeZone': timeZone,
  };
  final details = EntityDetails.fromJson(metadata, source: album, unsupportedFeatures: [
    if (_map(_map(album['visualIdentity'])['squareCoverImage'])['extractedColorSet'] != null) 'dynamic-colors',
  ]);
  return EntityPage(details: details, tracks: EntityTrackPage(rows: _albumRows(tracks, discs),
    offset: 0, limit: 50, totalLength: details.rowCount));
}
