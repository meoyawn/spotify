part of 'repository.dart';

List<EntityJson> _nativeImages(Object? value) {
  final image = _map(value);
  return [for (final pair in const [
    ('standardLink', 'standard'), ('smallLink', 'small'), ('largeLink', 'large'),
    ('xlargeLink', 'xlarge'), ('imageUri', 'standard'), ('thumbnailUri', 'small'),
  ]) if (_str(image[pair.$1]).isNotEmpty) {'url': image[pair.$1], 'label': pair.$2}];
}

EntityJson? _nativeUser(Object? value) => value == null ? null : {
  'type': 'user', 'uri': _map(value)['link'] ?? '', 'username': _map(value)['username'] ?? '',
  'displayName': _map(value)['displayName'], 'images': _nativeImages(value),
};
EntityJson _attributes(Object? value) => {for (final entry in _list(value))
  if (_map(entry).containsKey('key')) _str(_map(entry)['key']): _map(entry)['value'] ?? ''};
String? _nativeTime(Object? value) {
  final seconds = num.tryParse('$value');
  return seconds == null ? null : DateTime.fromMillisecondsSinceEpoch((seconds * 1000).toInt(), isUtc: true).toIso8601String();
}
EntityJson _nativeArtist(Object? value) => {'type': 'artist', 'uri': _map(value)['link'] ?? '', 'name': _map(value)['name'] ?? ''};

EntityPage _playlistPage(EntityJson response, String requestedUri) {
  final status = _map(response['status'])['statusCode'];
  if (status == 403 || status == 451) {
    final metadata = <String, Object?>{
      'type': 'playlist', 'uri': requestedUri, 'name': '', 'description': '', 'images': [],
      'dynamicColors': null, 'madeFor': null,
      'owner': {'type': 'user', 'uri': '', 'username': '', 'displayName': '', 'images': []},
      'totalLength': 0, 'unfilteredTotalLength': 0, 'totalLikes': null, 'duration': null,
      'isLoaded': false, 'isOwnedBySelf': false, 'isPublished': false, 'isRootlistable': false,
      'hasEpisodes': null, 'hasSpotifyTracks': null, 'hasSpotifyAudiobooks': null,
      'canAdd': false, 'canRemove': false, 'canEditMetadata': false, 'canEditItems': false,
      'canPlay': null, 'canMixPlaylist': false, 'formatListData': null,
      'canReportAnnotationAbuse': false, 'hasDateAdded': false,
      'permissions': {'isPrivate': false, 'canView': false,
        'canAdministratePermissions': false, 'canCancelMembership': false}, 'collaborators': null,
    };
    return EntityPage(details: EntityDetails.fromJson(metadata, source: response),
      tracks: EntityTrackPage(offset: 0, limit: 0, totalLength: 0));
  }
  final data = _map(response['data']);
  final playlist = _map(data['playlist']);
  final source = _map(playlist['playlistMetadata']);
  if (source.isEmpty) throw const EntityQueryError({'message': 'Invalid playlist or members response!'});
  final caps = _map(data['userCapabilities']);
  final collaborators = _map(data['collaborators']);
  final permissions = _map(data['basePermission']);
  final duration = num.tryParse('${data['duration']}') ?? 0;
  final counts = _list(data['numberOfItemsPerLinkType']);
  final creation = _map(data['createdAt']);
  final creationSeconds = int.tryParse('${creation['seconds']}');
  final creationMilliseconds = creationSeconds == null ? null
    : creationSeconds * 1000 + (creation['nanos'] as int? ?? 0) ~/ 1000000;
  final uri = _str(source['link']);
  final extensions = _list(source['extension']);
  final metadata = <String, Object?>{
    'type': 'playlist', 'uri': uri, 'name': _str(source['name']), 'description': _str(source['description']),
    if (creationMilliseconds != null) 'createdAt': playlistTimestampIso(creationMilliseconds),
    'images': _nativeImages(source['pictures']), 'dynamicColors': null,
    'madeFor': _nativeUser(source['madeFor']), 'owner': _nativeUser(source['owner']),
    'totalLength': data['unrangedLength'] ?? source['totalLength'] ?? 0,
    'unfilteredTotalLength': source['lengthIgnoringTextFilter'] ?? 0,
    'totalLikes': data['numFollowers'], 'duration': duration != 0 ? {'milliseconds': duration * 1000, 'isEstimate': false} : null,
    'isLoaded': source['isLoaded'] ?? false, 'isOwnedBySelf': source['ownedBySelf'] ?? false,
    'isPublished': source['published'] ?? false,
    if (extensions.isEmpty) 'isRootlistable': true,
    if (source.containsKey('followed')) 'isSaved': source['followed'],
    'hasEpisodes': data['containsEpisodes'], 'hasSpotifyTracks': data['containsSpotifyTracks'],
    'hasSpotifyAudiobooks': counts.any((count) => _map(count)['linkType'] == 62 && _truthy(_map(count)['numItems'])),
    'hasPodcastChapters': counts.any((count) => _map(count)['linkType'] == 96 && _truthy(_map(count)['numItems'])),
    if (uri == 'spotify:playlist:37i9dQZF1Fx4l3meNStj7H') 'acceptsItemTypes': [],
    if (uri == 'spotify:playlist:37i9dQZF1CIl0ks0ynmzpD') 'acceptsItemTypes': ['clip'],
    'canAdd': _map(source['allows'])['canInsert'] ?? false,
    'canRemove': _map(source['allows'])['canRemove'] ?? false,
    'canEditMetadata': caps['canEditMetadata'] ?? false, 'canEditItems': caps['canEditItems'] ?? false,
    'canPlay': data['playable'], 'canMixPlaylist': caps['canMixPlaylist'] ?? false,
    'formatListData': {'type': source['formatListType'] ?? '', 'attributes': _attributes(source['formatListAttributes'])},
    'canReportAnnotationAbuse': source['canReportAnnotationAbuse'] ?? false,
    'hasDateAdded': playlistHasDateAdded(source['formatListType'] as String? ?? ''),
    'permissions': data.containsKey('userCapabilities') || data.containsKey('collaborators') || data.containsKey('basePermission')
      ? {'canView': caps['canView'] == true, 'canAdministratePermissions': caps['canAdministratePermissions'] ?? false,
        'canCancelMembership': caps['canCancelMembership'] ?? false, 'isPrivate': permissions['permissionLevel'] == 1,
        'canDelete': caps['canDelete'] ?? false} : null,
    'collaborators': {'count': collaborators['count'] ?? 0,
      'items': _list(collaborators['collaborator']).map((value) => {'isOwner': _map(value)['isOwner'] ?? false,
        'tracksAdded': _map(value)['numberOfItems'] ?? 0,
        if (_map(value).containsKey('user')) 'user': _nativeUser(_map(value)['user'])}).toList()},
    'appliedLenses': _list(_map(playlist['lenses'])['appliedLenses']).map((lens) => _map(lens)['name']).whereType<String>().toList(),
    'availableSignals': _list(data['availableSignals']).where((signal) => _map(signal).containsKey('name')).toList(),
  };
  return EntityPage(details: EntityDetails.fromJson(metadata, source: response,
    unsupportedFeatures: [for (final extension in extensions) 'metadata-extension:${_map(extension)['extensionKind']}']),
    tracks: _playlistRows(data));
}

EntityTrackPage _playlistRows(EntityJson data) {
  if (!data.containsKey('item')) throw const EntityQueryError({'message': 'Invalid playlist response!'});
  final rows = _list(data['item']).map((value) => _playlistRow(_map(value))).toList();
  return EntityTrackPage(rows: rows, offset: 0, limit: rows.length, totalLength: data['unrangedLength'] as int? ?? 0);
}

EntityRow _playlistRow(EntityJson entry) {
  final track = _map(entry['trackMetadata']);
  final episode = _map(entry['episodeMetadata']);
  final source = track.isNotEmpty ? track : episode;
  final extensions = [..._list(entry['extension']), ..._list(source['extension'])];
  final unknown = [for (final extension in extensions) 'metadata-extension:${_map(extension)['extensionKind']}'];
  final common = <String, Object?>{
    'uid': entry['rowId'] ?? '', 'playIndex': null, 'addedAt': _nativeTime(entry['addTime']),
    'addedBy': _nativeUser(entry['addedBy']), 'formatListAttributes': _attributes(entry['formatListAttributes']),
    'availableSignals': _list(entry['availableSignals']).map((value) => _map(value)['name']).whereType<String>().toList(),
  };
  if (entry.containsKey('trackMetadata') && entry.containsKey('trackPlayState')) {
    final album = _map(track['album']);
    return EntityRow.fromJson({...common, 'type': 'track', 'uri': track['link'] ?? '', 'name': track['name'] ?? '',
      'album': track['album'] == null ? null : {'type': 'album', 'uri': album['link'] ?? '', 'name': album['name'] ?? '',
        if (album.containsKey('artist')) 'artist': _nativeArtist(album['artist']), 'images': _nativeImages(album['covers'])},
      'artists': _list(track['artist']).map(_nativeArtist).toList(), 'discNumber': track['discNumber'] ?? 0,
      'trackNumber': track['trackNumber'] ?? 0, 'duration': {'milliseconds': (track['length'] as num? ?? 0) * 1000},
      'isExplicit': track['isExplicit'] ?? false, 'isLocal': track['isLocal'] ?? false,
      'isPlayable': _map(entry['trackPlayState'])['isPlayable'] ?? false, 'is19PlusOnly': track['is19PlusOnly'] ?? false,
      if (extensions.isEmpty) 'hasAssociatedVideo': false, if (extensions.isEmpty) 'hasAssociatedAudio': false,
      'isBanned': _map(entry['collectionState'])['isBanned'] ?? false,
    }, source: entry, unsupportedFeatures: unknown);
  }
  if (entry.containsKey('episodeMetadata') && entry.containsKey('episodePlayState')) {
    final state = _map(entry['episodePlayState']);
    final remaining = state['timeLeft'] as num? ?? 0;
    final length = episode['length'] as num? ?? 0;
    final show = _map(episode['show']);
    final mediaType = episode['mediaTypeEnum'];
    return EntityRow.fromJson({...common, 'type': 'episode', 'uri': episode['link'] ?? '',
      'name': episode['name'] ?? '', 'description': episode['description'] ?? '',
      'duration': {'milliseconds': length * 1000},
      'playedState': {'timeLeft': {'milliseconds': remaining * 1000},
        'state': state['isPlayed'] == true ? 'COMPLETED' : remaining < length ? 'IN_PROGRESS' : 'NOT_STARTED'},
      'images': _nativeImages(episode['covers']), 'isExplicit': episode['isExplicit'] ?? false,
      'is19PlusOnly': episode['is19PlusOnly'] ?? false, if (extensions.isEmpty) 'contentRatings': [],
      'isPlayable': state['isPlayable'] ?? false, 'languages': _str(episode['language']).isEmpty ? [] : [episode['language']],
      'release': {'isoString': ?_nativeTime(episode['publishDate']), 'precision': 'DAY'},
      'show': episode['show'] != null && mediaType != null ? {'type': 'show', 'uri': show['link'] ?? '',
        'name': show['name'] ?? '', 'publisher': show['publisher'] ?? '',
        'images': _nativeImages(show['covers']), 'mediaType': mediaType} : null,
      if (extensions.isEmpty) 'podcastSubscription': {'isPaywalled': false, 'isUserSubscribed': false},
      if (extensions.isEmpty) 'isShareable': false, 'dynamicColors': null, 'sixteenByNineCoverImages': null,
      'mediaType': [mediaType == 1 ? 'AUDIO' : mediaType == 0 || mediaType == 2 ? 'VIDEO' : 'UNKNOWN'], 'typeLabel': null,
    }, source: entry, unsupportedFeatures: unknown);
  }
  return EntityRow.unsupported(source: entry);
}
