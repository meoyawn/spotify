typedef SearchJson = Map<String, Object?>;

enum SearchCategory {
  tracks('Songs', 'tracksV2', 20), artists('Artists', 'artists', 30),
  albums('Albums', 'albumsV2', 30), playlists('Playlists', 'playlists', 30),
  podcasts('Podcasts & Shows', 'podcasts', 30), episodes('Episodes', 'episodes', 30),
  audiobooks('Audiobooks', 'audiobooks', 30), authors('Authors', 'authors', 30),
  users('Profiles', 'users', 30), genres('Genres & Moods', 'genres', 30);
  const SearchCategory(this.label, this.responseField, this.pageSize);
  final String label, responseField;
  final int pageSize;
  static SearchCategory? parse(String? name) {
    for (final category in values) { if (category.name == name) return category; }
    return null;
  }
}

class SearchSection {
  SearchSection({required List<SearchItem> items, required this.totalCount, this.nextOffset, this.returnedCount = 0})
    : items = List.unmodifiable(items);
  final List<SearchItem> items;
  final int totalCount;
  final int? nextOffset;
  final int returnedCount;
}

/// Full-page and category responses retain their independent server cursors.
class SearchResults {
  SearchResults({required this.query, List<SearchItem> topResults = const [],
    Map<SearchCategory, SearchSection> sections = const {}, List<SearchCategory> chipOrder = const []})
    : topResults = List.unmodifiable(topResults), sections = Map.unmodifiable(sections),
      chipOrder = List.unmodifiable(chipOrder);
  final String query;
  final List<SearchItem> topResults;
  final Map<SearchCategory, SearchSection> sections;
  final List<SearchCategory> chipOrder;
  Iterable<SearchItem> get items sync* {
    yield* topResults;
    for (final section in sections.values) { yield* section.items; }
  }

  factory SearchResults.fromJson(SearchJson body, {required String query, SearchCategory? category}) {
    final search = _map(_map(body['data'])['searchV2']);
    SearchItem? project(Object? value) {
      final wrapper = _map(value);
      if (const {'UnknownTypeWrapper', 'SearchAutoCompleteEntity', 'SearchSectionEntity'}.contains(wrapper['__typename'])) return null;
      return _project(wrapper, query, false);
    }
    final sections = <SearchCategory, SearchSection>{};
    for (final kind in category == null ? SearchCategory.values : [category]) {
      final source = _map(search[kind.responseField]);
      final rows = _list(source['items']);
      sections[kind] = SearchSection(items: [for (final row in rows)
        ?project(kind == SearchCategory.tracks ? _map(row)['item'] : row)],
        totalCount: source['totalCount'] as int? ?? 0,
        returnedCount: rows.length,
        nextOffset: _map(source['pagingInfo'])['nextOffset'] as int?);
    }
    final chips = <SearchCategory>[];
    for (final raw in _list(_map(search['chipOrder'])['items'])) {
      final name = _text(_map(raw)['typeName']).toLowerCase();
      final chip = SearchCategory.parse(name);
      if (chip != null && (sections[chip]?.totalCount ?? 0) > 0 && !chips.contains(chip)) chips.add(chip);
    }
    return SearchResults(query: query, sections: sections, chipOrder: chips,
      topResults: [for (final hit in _list(_map(search['topResultsV2'])['itemsV2']))
        ?project(_map(hit)['item'])]);
  }
}

/// Display fields projected by the original desktop search entity mappers.
class SearchItem {
  SearchItem({
    required this.type,
    required this.uri,
    required this.name,
    required List<SearchJson> images,
    required List<String> contributors,
    this.durationMs,
    this.isPlayable,
    this.isExplicit = false,
    this.searchTerm,
  }) : images = List.unmodifiable(images.map(Map<String, Object?>.unmodifiable)),
       contributors = List.unmodifiable(contributors);

  final String type;
  final String uri;
  final String name;
  final List<SearchJson> images;
  final List<String> contributors;
  final int? durationMs;
  final bool? isPlayable;
  final bool isExplicit;
  final String? searchTerm;

  SearchJson toJson() => {
    'type': type,
    'uri': uri,
    'name': name,
    'images': images,
    'contributors': contributors,
    'durationMs': durationMs,
    'isPlayable': isPlayable,
    'isExplicit': isExplicit,
    'searchTerm': searchTerm,
  };
}

class SearchPage {
  SearchPage({required this.query, required List<SearchItem> items})
    : items = List.unmodifiable(items);

  /// Original desktop quick-search producer ci excludes autocomplete and
  /// unsupported wrapper variants before its entity-only result projection.
  factory SearchPage.fromModalJson(SearchJson body, {required String query}) {
    final search = _map(_map(body['data'])['searchV2']);
    final wrappers = _list(_map(search['topResultsV2'])['itemsV2']);
    const excluded = {'UnknownTypeWrapper', 'PreReleaseResponseWrapper',
      'SearchAutoCompleteEntity', 'SearchSectionEntity'};
    return SearchPage(query: query, items: [
      for (final wrapper in wrappers)
        if (_map(wrapper)['item'] case final Map<String, Object?> item)
          if (!excluded.contains(item['__typename']) && item['data'] != null)
            ?_project(item, query, false),
    ]);
  }

  factory SearchPage.fromJson(SearchJson body, {bool recent = false}) {
    final data = _map(body['data']);
    final search = _map(data['searchV2']);
    final query = recent ? '' : _text(search['query']);
    final history = _map(data['recentSearches']);
    final List<Object?> wrappers;
    if (recent) {
      wrappers = history['__typename'] == 'RecentSearchesResult'
          ? _list(_map(history['recentSearchesItems'])['items'])
          : const [];
    } else {
      wrappers = _list(_map(search['topResultsV2'])['itemsV2'])
          .map((entry) => _map(entry)['item'])
          .toList();
    }
    return SearchPage(
      query: query,
      items: wrappers
          .map((wrapper) => _project(_map(wrapper), query, recent))
          .whereType<SearchItem>()
          .toList(),
    );
  }

  final String query;
  final List<SearchItem> items;

  SearchJson toJson() => {
    'query': query,
    'items': items.map((item) => item.toJson()).toList(),
  };
}

SearchJson _map(Object? value) => value is SearchJson ? value : const {};
List<Object?> _list(Object? value) => value is List ? value : const [];
String _text(Object? value) => value is String ? value : '';

List<SearchJson> _images(Object? value) => _list(value).map((entry) {
  final image = _map(entry);
  if (_text(image['url']).isEmpty) return image;
  num dimension(Object? value) {
    final number = value is num ? value : num.tryParse('$value');
    return number == null || number == 0 || number.isNaN ? 56 : number;
  }
  return <String, Object?>{
    'url': image['url'],
    'width': dimension(image['width']),
    'height': dimension(image['height']),
  };
}).toList();

List<String> _artists(SearchJson data) =>
    _list(_map(data['artists'])['items'])
        .map((artist) => _text(_map(_map(artist)['profile'])['name']))
        .toList();

SearchItem? _project(SearchJson wrapper, String query, bool recent) {
  final data = _map(wrapper['data']);
  final wrapperType = wrapper['__typename'];
  if (recent && (wrapperType == 'PodcastResponseWrapper' ||
      wrapperType == 'AudiobookResponseWrapper')) {
    return null;
  }
  String type;
  String name = _text(data['name']);
  String uri = _text(data['uri']);
  List<SearchJson> images = [];
  List<String> contributors = [];
  int? durationMs;
  bool? isPlayable;
  bool explicit = false;
  String? searchTerm;
  switch (wrapperType) {
    case 'AlbumResponseWrapper':
      if (data['__typename'] != 'Album') return null;
      type = 'album';
      images = _images(_map(data['coverArt'])['sources']);
      contributors = _artists(data);
      isPlayable = _map(data['playability'])['playable'] as bool?;
    case 'ArtistResponseWrapper':
      if (data['__typename'] != 'Artist') return null;
      type = 'artist';
      name = _text(_map(data['profile'])['name']);
      images = _images(_map(_map(data['visuals'])['avatarImage'])['sources']);
    case 'TrackResponseWrapper':
      if (data['__typename'] != 'Track') return null;
      type = 'track';
      images = _images(_map(_map(data['albumOfTrack'])['coverArt'])['sources']);
      contributors = _artists(data);
      durationMs = _map(data['duration'])['totalMilliseconds'] as int?;
      isPlayable = _map(data['playability'])['playable'] as bool?;
      explicit = _map(data['contentRating'])['label'] == 'EXPLICIT';
    case 'PlaylistResponseWrapper':
      if (data['__typename'] != 'Playlist') return null;
      type = 'playlist';
      images = _images(_list(_map(data['images'])['items'])
          .expand((entry) => _list(_map(entry)['sources'])).toList());
      final owner = _map(_map(data['ownerV2'])['data']);
      if (owner['__typename'] == 'User' && _text(owner['name']).isNotEmpty) {
        contributors = [_text(owner['name'])];
      }
    case 'EpisodeResponseWrapper':
      if (data['__typename'] != 'Episode') return null;
      type = 'episode';
      images = _images(_map(data['coverArt'])['sources']);
      durationMs = _map(data['duration'])['totalMilliseconds'] as int?;
      explicit = _map(data['contentRating'])['label'] == 'EXPLICIT';
      final show = _map(_map(data['podcastV2'])['data']);
      if (show['__typename'] == 'Podcast' && _text(show['name']).isNotEmpty) {
        contributors = [_text(show['name'])];
      }
    case 'PodcastResponseWrapper':
    case 'AudiobookResponseWrapper':
    case 'PodcastOrAudiobookResponseWrapper':
      if (wrapperType == 'PodcastOrAudiobookResponseWrapper' && !recent) {
        return null;
      }
      final isBook = data['__typename'] == 'Audiobook';
      if (data['__typename'] != 'Podcast' && !isBook) return null;
      if (wrapperType == 'PodcastResponseWrapper' && isBook ||
          wrapperType == 'AudiobookResponseWrapper' && !isBook) {
        return null;
      }
      type = isBook ? 'audiobook' : 'show';
      images = _images(_map(data['coverArt'])['sources']);
      if (isBook) {
        final authors = _list(data['authorsV2']);
        final author = authors.isEmpty ? '' : _text(_map(authors.first)['name']);
        if (author.isNotEmpty) contributors = [author];
        isPlayable = _map(data['accessInfo'])['isUserMemberOfAtLeastOneGroup'] as bool? ?? false;
      } else {
        final publisher = _text(_map(data['publisher'])['name']);
        if (publisher.isNotEmpty) contributors = [publisher];
      }
    case 'UserResponseWrapper':
      if (data['__typename'] != 'User') return null;
      type = 'user';
      name = _text(data['displayName']);
      if (name.isEmpty) name = _text(data['username']);
      images = _images(_map(data['avatar'])['sources']);
    case 'GenreResponseWrapper':
      if (data['__typename'] != 'Genre') return null;
      type = 'genre';
      if (!uri.startsWith('spotify:')) uri = 'spotify:genre:$uri';
      images = _images(_map(data['image'])['sources']);
    case 'AuthorResponseWrapper':
      if (data['__typename'] != 'AuthorV2') return null;
      type = 'author';
      final image = _map(_map(_map(_map(data['visualIdentity'])['squareCoverImage'])['image'])['data']);
      if (image['__typename'] == 'ImageV2') images = _images(image['sources']);
    case 'PreReleaseResponseWrapper':
      if (data['__typename'] != 'PreRelease' || data['preReleaseContent'] == null) return null;
      type = 'pre-release-album';
      final content = _map(data['preReleaseContent']);
      name = _text(content['name']);
      images = _images(_map(content['coverArt'])['sources']);
      contributors = _list(_map(content['artists'])['items'])
          .map((entry) => _map(_map(entry)['data']))
          .where((artist) => artist['__typename'] == 'Artist')
          .map((artist) => _text(_map(artist['profile'])['name'])).toList();
    case 'SearchAutoCompleteEntity':
      if (recent) return null;
      type = 'autocomplete';
      name = _text(data['text']);
      searchTerm = query;
    case 'UnknownTypeWrapper':
      uri = _text(wrapper['_uri']);
      if (!RegExp(r'^spotify:(?:user:[^:]+:)?collection(?::tracks)?$').hasMatch(uri)) return null;
      type = 'liked-songs';
      name = 'Liked Songs';
      images = [for (final size in [64, 300, 640]) {
        'url': 'https://misc.scdn.co/liked-songs/liked-songs-$size.jpg',
        'width': size,
        'height': size,
      }];
    default:
      return null;
  }
  return SearchItem(
    type: type, uri: uri, name: name, images: images, contributors: contributors,
    durationMs: durationMs, isPlayable: isPlayable, isExplicit: explicit,
    searchTerm: searchTerm,
  );
}
