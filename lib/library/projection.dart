part of 'repository.dart';

LibraryJson _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
List<Object?> _list(Object? value) => value is List ? value : [];
String _str(Object? value) => value is String ? value : '';
const _priority = {2: 0, 3: 1, 4: 2, 0: 3, 1: 4, 7: 5, 5: 6, 102: 7,
  103: 8, 105: 9, 104: 10, 100: 11, 107: 12, 108: 13, 109: 14, 110: 15};
List<int> _ordered(Iterable<int> ids) => ids.where(_priority.containsKey).toList()
    ..sort((a, b) => _priority[a]!.compareTo(_priority[b]!));

LibraryOption _filter(int id, bool courses, LibraryLabelResolver label) {
  final key = switch (id) {
    0 => 'shared.library.filter.album', 1 => 'shared.library.filter.artist',
    7 => 'shared.library.filter.author', 2 => 'shared.library.filter.playlist',
    3 => courses ? 'shared.library.filter.podcasts-courses' : 'search.title.shows',
    4 => 'shared.library.filter.book', 100 => 'shared.library.filter.downloaded',
    102 => 'shared.library.filter.by-you', 103 => 'shared.library.filter.by-spotify',
    104 => 'shared.library.filter.unplayed', 105 => 'shared.library.filter.in-progress',
    5 => 'shared.library.filter.events', 107 => 'shared.library.filter.mixed',
    109 => 'shared.library.filter.venues', 110 => 'shared.library.filter.past',
    108 => 'shared.library.filter.upcoming',
    _ => null,
  };
  return LibraryOption(id: '$id', name: key == null
      ? cfg.YourLibraryFilters_Filter.valueOf(id)?.name ?? 'UNRECOGNIZED' : label(key));
}

List<LibraryOption> _sorts(int? primary, LibraryLabelResolver label, {
  bool recents = false, bool artistUpdated = false,
}) {
  final ids = [recents ? 10 : 6, 1, 0];
  if (primary != 1) ids.add(2);
  if (primary == 0) ids.add(9);
  if (primary == 3 || primary == 1 && artistUpdated) ids.add(5);
  if (primary == 2) ids.add(4);
  if ({5, 108, 109, 110}.contains(primary)) ids.insert(0, 8);
  return ids.map((id) => _sort(id, primary, label)).toList();
}

LibraryOption _sort(int? id, int? primary, LibraryLabelResolver label) {
  final key = switch (id) {
    2 => primary == 4 ? 'shared.library.sort-by.author' : 'shared.library.sort-by.creator',
    4 => 'shared.library.sort-by.custom', 0 => 'shared.library.sort-by.name',
    1 => 'shared.library.sort-by.recently-added',
    6 || 10 => 'shared.library.sort-by.recently-played-or-added',
    5 => 'shared.library.sort-by.recently-updated', 7 => 'shared.library.sort-by.relevance',
    9 => 'tracklist.header.release-date', 8 => 'shared.library.sort-by.date', _ => null,
  };
  return key == null ? _sorts(primary, label).first : LibraryOption(id: '$id', name: label(key));
}

LibraryPage _project(LibraryJson response, LibraryQuery query, bool prefix,
    LibraryFeatures features, LibraryLabelResolver label) {
  final error = _str(response['error']);
  if (error.contains('filter only available')) {
    final value = RegExp(r'^(.*) filter only available').firstMatch(error)?.group(1) ?? error;
    throw LibraryQueryError('filter', '"$value" is not a valid YLX filter.');
  }
  if (error.contains('order only available')) {
    final value = RegExp(r'^(.*) order only available').firstMatch(error)?.group(1) ?? error;
    throw LibraryQueryError('sort', '"$value" is not a valid YLX sort order.');
  }
  if (error.isNotEmpty && response['statusCode'] == 404 && query.folderUri != null) {
    throw LibraryQueryError('folder', error);
  }
  final header = _map(response['header']);
  final numeric = query.filters.map(int.tryParse).whereType<int>();
  final selected = _ordered(numeric).map((id) => _filter(id, features.courses, label)).toList();
  final primary = query.folderUri != null ? 2 : int.tryParse(selected.firstOrNull?.id ?? '');
  final tag = query.filters.where((id) => id.startsWith('spotify:concept:')).firstOrNull;
  if (tag != null && header['tagInfo'] != null) {
    selected.insert(0, LibraryOption(id: tag, name: _str(_map(header['tagInfo'])['tagName'])));
  }
  final sort = _sort(int.tryParse(query.sortOrder ?? ''), primary, label);
  final reorder = primary == 2 && sort.id == '4';
  final source = _list(response['entity']).map(_map).toList();
  final items = <LibraryItem>[];
  var expandedCount = 0;
  if (prefix) {
    final pending = source.map((entity) => (entity, 0)).toList();
    final all = <LibraryItem>[];
    while (pending.isNotEmpty) {
      final (entity, depth) = pending.removeAt(0);
      all.add(_item(entity, reorder, depth, query.textFilter.isNotEmpty));
      if (depth > 0) expandedCount++;
      if (all.length >= query.offset + query.limit) break;
      final info = _map(entity['entityInfo']);
      if (entity.containsKey('folder') && query.expandedFolders.contains(info['uri'])) {
        pending.insertAll(0, _list(_map(entity['folder'])['entity']).map((child) => (_map(child), depth + 1)));
      }
    }
    items.addAll(all.skip(query.offset).take(query.limit));
  } else {
    items.addAll(source.map((entity) => _item(entity, reorder, null, query.textFilter.isNotEmpty)));
  }
  final available2 = _list(_map(header['availableFilters2'])['availableFilter']);
  final available = <LibraryOption>[];
  if (features.customFilterOrder && available2.isNotEmpty) {
    for (final value in available2) {
      final option = _map(value);
      if (option['conceptName'] != null) {
        available.add(LibraryOption(id: _str(option['uri']), name: _str(option['conceptName'])));
      } else if (option['filter'] is int) {
        final name = cfg.YourLibraryFilters2_Filter.valueOf(option['filter'] as int)?.name;
        final legacy = cfg.YourLibraryFilters_Filter.values.where((filter) => filter.name == name).firstOrNull;
        if (legacy != null) available.add(_filter(legacy.value, features.courses, label));
      }
    }
  } else {
    available.addAll(_ordered(_list(_map(header['availableFilters'])['filter']).whereType<int>())
      .map((id) => _filter(id, features.courses, label)));
  }
  final total = header['totalCount'] as int? ?? 0;
  return LibraryPage(items: items, primaryFilter: const {0: 'album', 1: 'artist', 7: 'author',
      2: 'playlist', 3: 'show', 4: 'audiobook', 5: 'concert', 100: 'downloaded'}[primary],
    passedFilterIds: query.filters, availableFilters: available,
    selectedFilters: query.folderUri == null ? selected : selected.where((option) => option.id != '2').toList(),
    availableSortOrders: _sorts(primary, label, recents: features.recentsSortOrder,
      artistUpdated: features.artistRecentlyUpdatedSort), selectedSortOrder: sort,
    limit: query.limit, offset: query.offset, unfilteredTotalLength: total,
    totalLength: total + expandedCount,
    hasUnfilteredItems: total != 0 || query.filters.isNotEmpty || query.textFilter.isNotEmpty,
    hasTextFilter: query.textFilter.isNotEmpty, reorderAllowed: reorder,
    passedFolderUri: query.folderUri, openedFolderName: header['folderName'] as String?,
    parentFolderUri: header['parentFolderUri'] as String?,
    openedFolderIsPlayable: _str(header['folderName']).isNotEmpty && _playableFolder(response),
  );
}

bool _playableFolder(LibraryJson folder) {
  final entities = _list(folder['entity']);
  if (entities.isEmpty) {
    return (folder['numberOfPlaylists'] as int? ?? 0) > 0 || (folder['numberOfFolders'] as int? ?? 0) > 0;
  }
  return entities.any((value) {
    final entity = _map(value);
    return entity['folder'] != null ? _playableFolder(_map(entity['folder']))
        : _map(entity['playlist'])['isLoading'] == true ||
          _list(_map(entity['playlist'])['numberOfItemsPerLinkType']).any((count) => (_map(count)['numItems'] as int? ?? 0) > 0);
  });
}

String? _time(Object? seconds) {
  final value = int.tryParse('$seconds');
  return value != null && value > 0 ? DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true).toIso8601String() : null;
}

LibraryItem _item(LibraryJson entity, bool reorder, int? depth, bool flattened) {
  final info = _map(entity['entityInfo']);
  final uri = _str(info['uri']);
  final image = _str(info['imageUri']);
  final canPin = switch (info['pinnable']) { 0 => 0, 1 => 1, _ => 2 };
  final common = <String, Object?>{
    'name': _str(info['name']), 'uri': uri, 'pinned': info['pinned'] == true,
    'images': image.isEmpty ? <LibraryJson>[] : [{'url': image, 'width': 300, 'height': 300}],
    'addedAt': _time(info['addTime']),
    'lastPlayedAt': info['lastPlayed'] == info['addTime'] ? null : _time(info['lastPlayed']),
    'canPin': canPin, if (info.containsKey('groupLabel')) 'groupLabel': info['groupLabel'],
  };
  LibraryItem result(LibraryJson data) => LibraryItem.fromJson(data, source: entity);
  if (entity['playlist'] != null) {
    final playlist = _map(entity['playlist']);
    final counts = _list(playlist['numberOfItemsPerLinkType']).map(_map).toList();
    if (uri == 'spotify:playlist:37i9dQZF1FgnTBfUlzkeKt') {
      return result({...common, 'type': 'your-episodes', 'numberOfDownloadedEpisodes': 0});
    }
    if (uri == 'spotify:local-files') {
      return result({...common, 'type': 'local-files',
        'numberOfFiles': counts.where((count) => count['linkType'] == 9)
            .map((count) => count['numItems']).firstOrNull ?? 0});
    }
    final prompt = switch (playlist['promptGenerationStatus']) {
      0 => 'unknown', 1 => 'success', 2 => 'queued', 3 => 'processing', 4 => 'error', _ => null,
    };
    return result({...common, 'type': 'playlist',
      if (playlist.containsKey('madeForName')) 'madeForName': playlist['madeForName'],
      'canView': playlist['canView'] ?? true,
      'owner': {'type': 'user', 'name': _str(playlist['creatorName']), 'uri': _str(playlist['creatorUri']),
        'id': '', 'username': '', 'images': <LibraryJson>[]},
      if (playlist.containsKey('ownedBySelf')) 'isOwnedBySelf': playlist['ownedBySelf'],
      if (playlist.containsKey('isLoading')) 'isLoading': playlist['isLoading'],
      'folderDepth': ?depth,
      if (playlist.containsKey('canAdd')) 'canAddTo': playlist['canAdd'],
      'canReorder': reorder,
      'isBooklist': counts.any((count) => count['linkType'] == 62 && count['numItems'] != 0),
      if (uri == 'spotify:playlist:37i9dQZF1Fx4l3meNStj7H') 'acceptsItemTypes': <String>[],
      if (uri == 'spotify:playlist:37i9dQZF1CIl0ks0ynmzpD') 'acceptsItemTypes': ['clip'],
      'isEmpty': !counts.any((count) => (count['numItems'] as int? ?? 0) > 0),
      if (playlist.containsKey('rowId')) 'rowId': playlist['rowId'],
      'namePrefix': playlist['namePrefix'], 'isMixed': playlist['mixingActive'] ?? false,
      if (playlist.containsKey('isPromptPlaylist')) 'isPromptPlaylist': playlist['isPromptPlaylist'],
      'promptGenerationStatus': ?prompt,
    });
  }
  if (entity['album'] != null || entity['prerelease'] != null) {
    final pre = entity['prerelease'] != null;
    final album = _map(entity[pre ? 'prerelease' : 'album']);
    final artist = _str(album['artistName']);
    final artists = <LibraryJson>[if (artist.isNotEmpty)
      {'type': 'artist', 'name': artist, 'uri': _str(album['artistUri'])}];
    if (pre) {
      return result({...common, 'type': album['type'] == 0 ? 'pre-release-album' : 'pre-release-book',
        if (album['type'] == 0) 'artists': artists else 'authorName': artist});
    }
    return result({...common, 'type': 'album', 'artists': artists,
      'isPremiumOnly': album['isPremiumOnly'] ?? false,
      'albumType': const {0: 'album', 1: 'single', 2: 'compilation', 3: 'ep'}[album['type']] ?? 'album',
      if (album.containsKey('newRelease')) 'isNewRelease': album['newRelease'],
    });
  }
  if (entity['artist'] != null) return result({...common, 'type': 'artist'});
  if (entity['show'] != null) {
    return result({...common, 'type': 'show', 'publisher': _str(_map(entity['show'])['creatorName'])});
  }
  if (entity['book'] != null) {
    final book = _map(entity['book']);
    final author = _str(book['authorName']);
    return result({...common, 'type': 'audiobook', 'authorName': author,
      'authors': [{'uri': null, 'name': author}], 'isLocked': book['access'] == 1,
      'isCappedWithoutExplanation': book['access'] == 2, 'isPlayable': book['access'] == 0});
  }
  if (entity['folder'] != null) {
    final folder = _map(entity['folder']);
    final data = {...common}..remove('images');
    return result({...data, 'type': 'folder', 'rowId': folder['rowId'] ?? '',
      'numberOfFolders': folder['numberOfFolders'] ?? 0, 'numberOfPlaylists': folder['numberOfPlaylists'] ?? 0,
      'folderDepth': ?depth, 'canReorder': reorder,
      'isFlattened': flattened, 'isEmpty': !_playableFolder(folder)});
  }
  if (entity['event'] != null || entity['venue'] != null || entity['concertCampaign'] != null) {
    final event = _map(entity['event']);
    final venue = _map(entity['venue']);
    final campaign = _map(entity['concertCampaign']);
    final data = {...common}..remove('groupLabel');
    return result({...data, 'lastPlayedAt': null,
      'type': entity['event'] != null ? 'concert' : entity['venue'] != null ? 'venue' : 'concert-campaign',
      if (entity['event'] != null || entity['venue'] != null) 'cityName': _str(event['cityName'] ?? venue['cityName']),
      if (entity['event'] != null || entity['venue'] != null) 'locationName': _str(event['locationName'] ?? venue['addressName']),
      if (entity['event'] != null) 'startTime': _time(event['startTime']),
      if (entity['concertCampaign'] != null) 'status': const {0: 'unspecified', 1: 'reserved', 2: 'fcfs', 3: 'waitlisted',
        4: 'purchased', 5: 'ineligible', 6: 'soldOut', 7: 'cancelled', 8: 'saleEnded'}[campaign['status']] ?? 'unspecified',
    });
  }
  if (entity['author'] != null) return result({...common, 'type': 'author'});
  return LibraryItem.unsupported(source: entity);
}
