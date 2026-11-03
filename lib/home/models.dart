import 'dart:math' as math;

import '../content/advertising.dart';

typedef HomeJson = Map<String, Object?>;

/// Desktop defaults recovered from renderer module 15364, supplied by callers.
class HomeFeatures {
  const HomeFeatures({
    this.includeHomeChapterVideoCards = false,
    this.includeEpisodeContentRatingsV2 = true,
    this.sectionItemsLimit,
    this.grid = false,
    this.watchFeed = false,
    this.podcastVideos = false,
    this.yourDJ = false,
  });

  final bool includeHomeChapterVideoCards;
  final bool includeEpisodeContentRatingsV2;
  final int? sectionItemsLimit;
  final bool grid;
  final bool watchFeed;
  final bool podcastVideos;
  final bool yourDJ;
}

class HomeRequestContext {
  const HomeRequestContext({
    required this.timeZone,
    this.spT = '',
    this.collectionUri = '',
    this.features = const HomeFeatures(),
  });

  final String timeZone;
  final String spT;
  final String collectionUri;
  final HomeFeatures features;
}

enum HomeSectionKind { shortcuts, carousel, feed, unsupported }

/// Original Home chips carry opaque facet IDs, separate from their labels.
class HomeChip {
  HomeChip({required this.id, required this.label, List<HomeChip> subChips = const []})
    : subChips = List.unmodifiable(subChips);
  final String id, label;
  final List<HomeChip> subChips;
  HomeJson toJson() => {'id': id, 'label': label,
    if (subChips.isNotEmpty) 'subChips': subChips.map((chip) => chip.toJson()).toList()};
}

class HomeItem {
  HomeItem({
    required this.type,
    required this.uri,
    required this.name,
    List<HomeJson> images = const [],
    List<String> contributors = const [],
    this.description = '',
    this.isPlayable,
    this.isExplicit = false,
    this.durationMs,
    this.reason = '',
    this.sourceSectionUri,
    HomeJson source = const {},
  }) : images = List.unmodifiable(images.map((image) => Map<String, Object?>.unmodifiable(image))),
       contributors = List.unmodifiable(contributors),
       source = Map.unmodifiable(source);

  final String type;
  final String uri;
  final String name;
  final List<HomeJson> images;
  final List<String> contributors;
  final String description;
  final bool? isPlayable;
  final bool isExplicit;
  final int? durationMs;
  final String reason;
  final String? sourceSectionUri;
  final HomeJson source;

  HomeJson get contentData => _map(_map(source['content'])['data']);
  /// Original playlist card50427 leaves the branded cover as the title.
  bool get showTitle => type != 'playlist' ||
    _map(_map(contentData['ownerV2'])['data'])['uri'] != 'spotify:user:spotify';
  String get cardSubtitle => type == 'playlist' && description.isNotEmpty
    ? description.replaceAll(RegExp(r'<[^>]*>'), '')
    : '${type == 'playlist' && contributors.isNotEmpty ? 'By ' : ''}${contributors.join(', ')}';

  HomeJson toJson() => {
    'type': type, 'uri': uri, 'name': name, 'images': images,
    'contributors': contributors, 'description': description,
    'isPlayable': isPlayable, 'isExplicit': isExplicit, 'durationMs': durationMs,
    'reason': reason, 'sourceSectionUri': sourceSectionUri,
  };
}

class HomeSection {
  HomeSection({
    required this.uri,
    required this.kind,
    required this.sourceType,
    this.title = '',
    this.pretitle,
    this.titleUri,
    this.titleImage,
    this.titleMediaCircle = false,
    this.seeAllUri,
    List<HomeItem> items = const [],
    HomeJson source = const {},
  }) : items = List.unmodifiable(items), source = Map.unmodifiable(source);

  final String uri;
  final HomeSectionKind kind;
  final String sourceType;
  final String title;
  final String? pretitle;
  final String? titleUri;
  final String? titleImage;
  final bool titleMediaCircle;
  final String? seeAllUri;
  final List<HomeItem> items;
  final HomeJson source;

  /// Full Home shelves use the ordinary card mapper, without split headers.
  static HomeSection? fullPage(HomeJson section) {
    final data = _map(section['data']);
    final type = _string(data['__typename']);
    if (isAdvertisingSection(type)) return null;
    final generic = type == 'HomeGenericSectionData';
    return HomeSection(uri: _string(section['uri']),
      kind: generic ? HomeSectionKind.carousel : HomeSectionKind.unsupported,
      sourceType: type, title: _string(_map(data['title'])['transformedLabel']),
      items: generic ? _entries(section).map((entry) => _card(entry))
        .whereType<HomeItem>().where((item) => !isAdvertisement(item.uri)).toList() : [],
      source: section);
  }

  /// Browse's original module37764 shares music cards but has its own hubs.
  static HomeSection? browse(HomeJson section, {bool fullPage = false}) {
    final data = _map(section['data']);
    final type = _string(data['__typename']);
    if (!fullPage && !const {'BrowseGenericSectionData', 'BrowseGridSectionData',
        'BrowseRelatedSectionData'}.contains(type)) { return null; }
    final uri = _string(section['uri']);
    final target = _string(section['targetLocation']);
    return HomeSection(uri: uri, kind: HomeSectionKind.carousel, sourceType: type,
      title: _string(_map(data['title'])['transformedLabel']),
      pretitle: _string(_map(data['subtitle'])['transformedLabel']),
      seeAllUri: fullPage ? null : type == 'BrowseGenericSectionData' && uri.startsWith('spotify:section:')
        ? '/genre/section${uri.substring('spotify:section:'.length)}'
        : type == 'BrowseGridSectionData' && target.startsWith('spotify:page:')
        ? '/genre/${target.substring('spotify:page:'.length)}' : null,
      items: _entries(section).map(_browseCard).whereType<HomeItem>()
        .where((item) => !isAdvertisement(item.uri)).toList(), source: section);
  }

  HomeJson toJson() => {
    'uri': uri, 'sourceType': sourceType, 'kind': kind.name, 'title': title,
    'pretitle': pretitle, 'titleUri': titleUri, 'titleImage': titleImage,
    'titleMediaCircle': titleMediaCircle, 'seeAllUri': seeAllUri,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

class HomePage {
  HomePage({this.greeting, List<HomeSection> sections = const [], List<HomeChip> chips = const []})
      : sections = List.unmodifiable(sections), chips = List.unmodifiable(chips);

  final String? greeting;
  final List<HomeSection> sections;
  final List<HomeChip> chips;

  /// Projection of an already validated HomeResponsePayload union.
  factory HomePage.fromPayload(HomeJson payload, {
    HomeRequestContext context = const HomeRequestContext(timeZone: ''),
  }) {
    final sections = _list(_map(_map(payload['sectionContainer'])['sections'])['items']);
    final grouped = <List<HomeJson>>[];
    for (final value in sections) {
      final section = _map(value);
      final isFeed = _map(section['data'])['__typename'] == 'HomeFeedBaselineSectionData';
      if (isFeed && grouped.isNotEmpty &&
          _map(grouped.last.first['data'])['__typename'] == 'HomeFeedBaselineSectionData') {
        grouped.last.add(section);
      } else {
        grouped.add([section]);
      }
    }
    final projected = <HomeSection>[];
    for (var index = 0; index < grouped.length; index++) {
      final group = grouped[index];
      if (_map(group.first['data'])['__typename'] == 'HomeFeedBaselineSectionData') {
        final items = <HomeItem>[];
        for (final section in group) {
          for (final entry in _entries(section)) {
            final item = _card(entry, feed: true,
              reason: _label(_map(section['data'])['title']),
              sourceSectionUri: _string(section['uri']));
            if (item != null) items.add(item);
          }
        }
        if (items.isNotEmpty) {
          projected.add(HomeSection(
            uri: 'spotify:home:feed-baseline-unified-shelf:$index',
            kind: HomeSectionKind.feed, sourceType: 'HomeFeedBaselineSectionData',
            items: items, source: {'sections': group},
          ));
        }
      } else {
        final section = _section(group.first, context);
        if (section != null) projected.add(section);
      }
    }
    HomeChip? chip(Object? value, {bool parent = true}) {
      final data = _map(value), id = _string(_map(value)['id']);
      final label = _string(_map(data['label'])['transformedLabel']);
      if (id.isEmpty || id == 'wrapped-chip' || label.isEmpty) return null;
      return HomeChip(id: id, label: label, subChips: parent
        ? [for (final child in _list(data['subChips'])) ?chip(child, parent: false)] : const []);
    }
    return HomePage(greeting: _map(payload['greeting'])['transformedLabel'] as String?,
      sections: projected, chips: [for (final value in _list(payload['homeChips'])) ?chip(value)]);
  }

  HomeJson toJson() => {
    'greeting': greeting, 'sections': sections.map((section) => section.toJson()).toList(),
    if (chips.isNotEmpty) 'chips': chips.map((chip) => chip.toJson()).toList(),
  };
}

HomeJson _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
List<Object?> _list(Object? value) => value is List ? value : [];
String _string(Object? value) => value is String ? value : '';
List<HomeJson> _entries(HomeJson section) =>
    _list(_map(section['sectionItems'])['items']).map(_map).toList();

String _label(Object? value) {
  final label = _string(_map(value)['transformedLabel']);
  return label.contains('{0}') ? '' : label;
}

List<HomeJson> _images(HomeJson data) {
  final Object? sources = switch (data['__typename']) {
    'Artist' => _map(_map(data['visuals'])['avatarImage'])['sources'],
    'Album' || 'Audiobook' || 'Podcast' || 'Episode' || 'Chapter' => _map(data['coverArt'])['sources'],
    'Track' => _map(_map(data['albumOfTrack'])['coverArt'])['sources'],
    'Playlist' => _list(_map(data['images'])['items']).isEmpty ? null
        : _map(_list(_map(data['images'])['items']).first)['sources'],
    'User' => _map(data['avatar'])['sources'],
    _ => null,
  };
  return _list(sources).map((source) {
    final image = _map(source);
    return <String, Object?>{
      for (final key in ['url', 'width', 'height']) if (image.containsKey(key)) key: image[key],
    };
  }).toList();
}

bool _booklist(HomeJson data) {
  final attributes = data['attributes'];
  return attributes is List
      ? attributes.any((value) => _map(value)['key'] == 'is-editorial-booklist' &&
          _map(value)['value'] == 'true')
      : _map(attributes)['is-editorial-booklist'] == 'true';
}

const _wrappers = {
  'AlbumResponseWrapper', 'ArtistResponseWrapper', 'EpisodeOrChapterResponseWrapper',
  'PlaylistResponseWrapper', 'PodcastOrAudiobookResponseWrapper', 'TrackResponseWrapper',
};

HomeItem? _card(HomeJson entry, {
  bool feed = false, String reason = '', String? sourceSectionUri,
}) {
  final content = _map(entry['content']);
  if (!_wrappers.contains(content['__typename'])) return null;
  var data = _map(content['data']);
  final originalData = data;
  var type = data['__typename'];
  if (feed && !{'Album', 'Audiobook', 'Episode', 'Playlist'}.contains(type)) return null;
  if (type == 'Chapter') {
    data = _map(_map(data['audiobookV2'])['data']);
    if (data['__typename'] != 'Audiobook') return null;
    type = 'Audiobook';
  }
  if (!{'Album', 'Artist', 'Audiobook', 'Episode', 'Playlist', 'Podcast', 'Track'}.contains(type)) return null;
  final artistNames = _list(_map(data['artists'])['items'])
      .map((artist) => _string(_map(_map(artist)['profile'])['name'])).toList();
  final author = _list(data['authorsV2']).isEmpty ? ''
      : _string(_map(_list(data['authorsV2']).first)['name']);
  final owner = _map(_map(data['ownerV2'])['data']);
  final ownerName = owner['__typename'] == 'User' ? _string(owner['name']) : '';
  final publisher = _string(_map(data['publisher'])['name']);
  final parent = _map(_map(data['podcastV2'])['data']);
  final contributors = switch (type) {
    'Album' || 'Track' => artistNames,
    'Audiobook' => author.isEmpty ? <String>[] : [author],
    'Playlist' => ownerName.isEmpty ? <String>[] : [ownerName],
    'Podcast' => publisher.isEmpty ? <String>[] : [publisher],
    'Episode' when feed => parent['__typename'] == 'Podcast' && _string(parent['name']).isNotEmpty
        ? [_string(parent['name'])] : <String>[],
    _ => <String>[],
  };
  final playlistContent = _map(data['content']);
  final isPlayable = feed ? type != 'Playlist' || !_booklist(data) : switch (type) {
    'Album' => _map(data['playability'])['playable'] as bool?,
    'Audiobook' => _map(data['accessInfo'])['isUserMemberOfAtLeastOneGroup'] == true,
    'Playlist' => !_booklist(data) && playlistContent['__typename'] == 'PlaylistItemsPage' &&
        (playlistContent['totalCount'] as num? ?? 0) > 0,
    _ => null,
  };
  var description = type == 'Episode' || type == 'Playlist' || (feed && type == 'Audiobook')
      ? _string(data['description']) : '';
  if (feed && type == 'Audiobook') description = description.replaceAll(RegExp('<[^>]*>?'), '');
  return HomeItem(
    type: type == 'Podcast' ? 'show' : _string(type).toLowerCase(),
    uri: _string(data['uri']),
    name: type == 'Artist' ? _string(_map(data['profile'])['name']) : _string(data['name']),
    images: _images(originalData), contributors: contributors, description: description,
    isPlayable: isPlayable,
    isExplicit: (type == 'Episode' || type == 'Track') && _map(data['contentRating'])['label'] == 'EXPLICIT',
    durationMs: (type == 'Episode' ? _map(data['duration'])['totalMilliseconds']
        : feed && type == 'Audiobook' ? _map(data['audiobookDuration'])['totalMilliseconds'] : null) as int?,
    reason: reason, sourceSectionUri: sourceSectionUri, source: entry,
  );
}

HomeItem? _browseCard(HomeJson entry) {
  final content = _map(entry['content']);
  final data = _map(content['data']);
  if (content['__typename'] == 'BrowseXlinkResponseWrapper' && data['__typename'] == 'BrowseClientFeature') {
    return HomeItem(type: 'browse', uri: _string(data['featureUri']),
      name: _string(_map(data['title'])['transformedLabel']),
      images: _list(_map(data['artwork'])['sources'] ?? _map(data['iconOverlay'])['sources']).map(_map).toList(), source: entry);
  }
  if (content['__typename'] == 'BrowseSectionContainerWrapper' &&
      data['__typename'] == 'BrowseSectionContainer') {
    final representation = _map(_map(data['data'])['cardRepresentation']);
    return HomeItem(type: 'browse', uri: _string(entry['uri']),
      name: _string(_map(representation['title'])['transformedLabel']),
      images: _list(_map(representation['artwork'])['sources']).map(_map).toList(), source: entry);
  }
  if (content['__typename'] == 'UserResponseWrapper' && data['__typename'] == 'User') {
    return HomeItem(type: 'user', uri: _string(data['uri']), name: _string(data['name']),
      images: _images(data), source: entry);
  }
  final ordinary = _card(entry);
  if (ordinary == null) return null;
  final chapter = data['__typename'] == 'Chapter';
  return HomeItem(type: chapter ? 'chapter' : ordinary.type,
    uri: chapter ? _string(data['uri']) : ordinary.uri,
    name: chapter ? _string(data['name']) : ordinary.name,
    images: ordinary.images, contributors: ordinary.contributors,
    description: ordinary.description,
    isPlayable: ordinary.type == 'playlist' ? !_booklist(data) : ordinary.isPlayable,
    isExplicit: chapter ? _map(data['contentRating'])['label'] == 'EXPLICIT' : ordinary.isExplicit,
    durationMs: chapter ? _map(data['duration'])['totalMilliseconds'] as int? : ordinary.durationMs,
    source: entry);
}

HomeItem? _shortcut(HomeJson entry, HomeRequestContext context) {
  final content = _map(entry['content']);
  if (content['__typename'] == 'UnknownType') {
    final uri = _string(entry['uri']);
    final collection = RegExp(r'^spotify:user:([^:]*):collection(?::.*)?$').firstMatch(uri);
    if (uri.startsWith('spotify:collection:') || collection != null) {
      final String resolvedUri;
      final String type;
      final String name;
      final String imagePath;
      if (uri.endsWith('your-episodes')) {
        resolvedUri = 'spotify:user:${collection?.group(1) ?? ''}:collection:your-episodes';
        type = 'your-episodes'; name = 'Your Episodes'; imagePath = 'your-episodes/SE';
      } else if (uri.endsWith('local-files')) {
        resolvedUri = 'spotify:collection:local-files';
        type = 'local-files'; name = 'Local Files'; imagePath = '';
      } else {
        if (context.collectionUri.isEmpty) return null;
        resolvedUri = context.collectionUri;
        type = 'liked-songs'; name = 'Liked Songs'; imagePath = 'liked-songs/liked-songs';
      }
      return HomeItem(type: type, uri: resolvedUri, name: name, source: entry,
        images: imagePath.isEmpty ? [] : [
          for (final size in [64, 300, 640])
            {'url': 'https://misc.scdn.co/$imagePath-$size.jpg', 'width': size, 'height': size},
        ]);
    }
    return null;
  }
  if ({'UnknownType', 'PromotionResponseWrapper', 'PreReleaseResponseWrapper',
      'ListResponseWrapper', 'ConcertV2ResponseWrapper'}.contains(content['__typename'])) {
    return null;
  }
  var data = _map(content['data']);
  var type = data['__typename'];
  if (!{'Artist', 'Album', 'Track', 'User', 'Podcast', 'Audiobook', 'Playlist', 'Episode', 'Chapter'}.contains(type)) {
    return null;
  }
  var uri = _string(entry['uri']);
  if (type == 'Chapter') {
    final parent = _map(_map(data['audiobookV2'])['data']);
    if (parent['__typename'] == 'Audiobook') {
      data = parent;
      uri = _string(parent['uri']);
    }
  }
  return HomeItem(type: type == 'Audiobook' ? 'audiobook' : uri.split(':').elementAtOrNull(1) ?? '',
    uri: uri, name: type == 'Artist' ? _string(_map(data['profile'])['name']) : _string(data['name']),
    images: _images(data),
    isPlayable: type == 'Audiobook' ? _map(data['accessInfo'])['isUserMemberOfAtLeastOneGroup'] == true : null,
    durationMs: type == 'Episode' ? _map(data['duration'])['totalMilliseconds'] as int? : null,
    source: entry,
  );
}

HomeSection? _section(HomeJson section, HomeRequestContext context) {
  final data = _map(section['data']);
  final type = _string(data['__typename']);
  if (isAdvertisingSection(type)) return null;
  final features = context.features;
  final kind = switch (type) {
    'HomeGenericSectionData' => HomeSectionKind.carousel,
    'HomeGridSectionData' => features.grid ? HomeSectionKind.unsupported : HomeSectionKind.carousel,
    'HomeShortsSectionData' => HomeSectionKind.shortcuts,
    'HomeRecentlyPlayedSectionData' || 'HomeSpotlightSectionData' ||
    'HomeMusicVideosSectionData' => HomeSectionKind.unsupported,
    'HomeWatchFeedSectionData' when features.watchFeed => HomeSectionKind.unsupported,
    'HomePodcastVideosCarouselSectionData' when features.podcastVideos => HomeSectionKind.unsupported,
    'HomeYourDJSectionData' when features.yourDJ && _entries(section).isNotEmpty &&
        _map(_entries(section).first['content'])['__typename'] == 'PlaylistResponseWrapper' &&
        _map(_map(_entries(section).first['content'])['data'])['__typename'] == 'Playlist' => HomeSectionKind.unsupported,
    _ => null,
  };
  if (kind == null) return null;
  List<HomeItem> items = [];
  if (kind == HomeSectionKind.shortcuts) {
    var entries = _entries(section);
    if (entries.length < 8 && entries.length.isOdd) entries = entries.sublist(0, entries.length - 1);
    items = entries.map((entry) => _shortcut(entry, context)).whereType<HomeItem>().take(8).toList();
  } else if (kind == HomeSectionKind.carousel) {
    items = _entries(section).map((entry) => _card(entry)).whereType<HomeItem>().toList();
  }
  if (kind != HomeSectionKind.unsupported && items.isEmpty) return null;
  final header = kind == HomeSectionKind.carousel
      ? _header(data['headerEntity'], data['title'], type == 'HomeGenericSectionData' ? data['subtitle'] : null)
      : <String, Object?>{'title': _string(_map(data['title'])['transformedLabel'])};
  final entity = _map(data['headerEntity']);
  final entityData = _map(entity['data']);
  return HomeSection(uri: _string(section['uri']), kind: kind, sourceType: type,
    title: _string(header['title']), pretitle: header['pretitle'] as String?,
    titleUri: header['titleUri'] as String?, titleImage: header['titleImage'] as String?,
    titleMediaCircle: header['titleMediaCircle'] == true,
    seeAllUri: kind == HomeSectionKind.carousel
        ? entity['__typename'] == 'GenreResponseWrapper' && entityData['__typename'] == 'Genre'
            ? _string(entityData['uri']) : _string(section['uri']) : null,
    items: items, source: section,
  );
}

HomeJson _header(Object? value, Object? title, Object? subtitle) {
  final entity = _map(value);
  final data = _map(entity['data']);
  final type = entity['__typename'];
  final recognized = type == 'UnknownType' ||
      type == 'ArtistResponseWrapper' && data['__typename'] == 'Artist' ||
      {'PodcastOrAudiobookResponseWrapper', 'EpisodeOrChapterResponseWrapper'}.contains(type) &&
          {'Podcast', 'Audiobook', 'Episode', 'Chapter'}.contains(data['__typename']) ||
      type == 'GenreResponseWrapper' && data['__typename'] == 'Genre';
  if (!recognized) return {'title': _string(_map(title)['transformedLabel'])};
  final transformed = _label(title);
  final base = _string(_map(title)['translatedBaseText']);
  final hasToken = base.contains('{0}');
  final unresolved = (hasToken || _string(_map(title)['transformedLabel']).contains('{0}')) && transformed.isEmpty;
  final pretitle = unresolved ? null : hasToken ? base.split('{0}').first
      : _map(subtitle)['transformedLabel'] as String?;
  final name = unresolved ? '' : pretitle != null && pretitle.isNotEmpty && transformed.contains(pretitle)
      ? transformed.split(pretitle)[1] : transformed;
  if (type == 'UnknownType') return {'title': name, 'pretitle': pretitle};
  final sources = type == 'GenreResponseWrapper' ? _list(_map(data['image'])['sources']) : _images(data);
  HomeJson? nearest;
  var distance = double.infinity;
  for (final value in sources) {
    final image = _map(value);
    final width = num.tryParse('${image['width']}') ?? 0;
    final height = num.tryParse('${image['height']}') ?? 0;
    final area = (width == 0 ? height : width) * (height == 0 ? width : height);
    final ratio = math.max(area, 48 * 48) / math.min(area, 48 * 48);
    if (nearest == null || ratio < distance) { nearest = image; distance = ratio; }
  }
  return {'title': name, 'pretitle': pretitle, 'titleUri': data['uri'],
    'titleImage': nearest?['url'], 'titleMediaCircle': type == 'ArtistResponseWrapper'};
}
