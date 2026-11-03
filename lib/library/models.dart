typedef LibraryJson = Map<String, Object?>;
typedef LibraryLabelResolver = String Function(String resourceKey);

bool libraryUriMatches(String uri, String? activeUri) {
  if (activeUri == null || uri.isEmpty) return false;
  String canonical(String value) => value.replaceFirst(
    RegExp(r'^spotify:user:[^:]+:playlist:'), 'spotify:playlist:');
  return canonical(uri) == canonical(activeUri);
}

enum LibrarySortDirection { forward, reverse }
enum LibraryItemsView { compact, list, grid, compactGrid }
enum LibraryPlaylistInclusion { exclude, ifNotEmpty, always }

class LibraryFeatures {
  const LibraryFeatures({this.courses = false, this.authors = false,
    this.venues = false, this.concertCampaigns = false, this.recentsSortOrder = false,
    this.artistRecentlyUpdatedSort = false, this.customFilterOrder = false});
  final bool courses;
  final bool authors;
  final bool venues;
  final bool concertCampaigns;
  final bool recentsSortOrder;
  final bool artistRecentlyUpdatedSort;
  final bool customFilterOrder;
}

const _unset = Object();

class LibraryQuery {
  const LibraryQuery({this.filters = const [], this.sortOrder, this.sortDirection,
    this.textFilter = '', this.offset = 0, this.limit = 50, this.folderUri,
    this.expandedFolders = const [], this.includeLocalFiles = false,
    this.filtersPickedByUser = true, this.flattenTree = false,
    this.itemToCheckCurationFor, this.includeYourClips = true,
    this.likedSongsInclusion = LibraryPlaylistInclusion.ifNotEmpty,
    this.yourEpisodesInclusion = LibraryPlaylistInclusion.ifNotEmpty});
  final List<String> filters;
  final String? sortOrder;
  final LibrarySortDirection? sortDirection;
  final String textFilter;
  final int offset;
  final int limit;
  final String? folderUri;
  final List<String> expandedFolders;
  final bool includeLocalFiles;
  final bool filtersPickedByUser;
  final bool flattenTree;
  final List<String>? itemToCheckCurationFor;
  final bool includeYourClips;
  final LibraryPlaylistInclusion likedSongsInclusion;
  final LibraryPlaylistInclusion yourEpisodesInclusion;

  factory LibraryQuery.fromJson(LibraryJson json) => LibraryQuery(
    filters: List<String>.from(json['filters'] as List? ?? []),
    sortOrder: json['sortOrder'] as String?,
    sortDirection: json['sortDirection'] == 'reverse' ? LibrarySortDirection.reverse
        : json['sortDirection'] == 'forward' ? LibrarySortDirection.forward : null,
    textFilter: json['textFilter'] as String? ?? '', offset: json['offset'] as int? ?? 0,
    limit: json['limit'] as int? ?? 50, folderUri: json['folderUri'] as String?,
    expandedFolders: List<String>.from(json['expandedFolders'] as List? ?? []),
    includeLocalFiles: json['includeStsLocalFilesPlaylist'] == true,
    filtersPickedByUser: json['filtersPickedByUser'] != false,
    flattenTree: json['flattenTree'] == true,
    itemToCheckCurationFor: json['itemToCheckCurationFor'] is List
        ? List<String>.from(json['itemToCheckCurationFor'] as List) : null,
    includeYourClips: json['includeYourClips'] != false,
  );

  LibraryQuery copyWith({List<String>? filters, Object? sortOrder = _unset,
    Object? sortDirection = _unset, String? textFilter, int? offset, int? limit,
    Object? folderUri = _unset, List<String>? expandedFolders}) => LibraryQuery(
    filters: filters ?? this.filters,
    sortOrder: identical(sortOrder, _unset) ? this.sortOrder : sortOrder as String?,
    sortDirection: identical(sortDirection, _unset) ? this.sortDirection : sortDirection as LibrarySortDirection?,
    textFilter: textFilter ?? this.textFilter, offset: offset ?? this.offset,
    limit: limit ?? this.limit,
    folderUri: identical(folderUri, _unset) ? this.folderUri : folderUri as String?,
    expandedFolders: expandedFolders ?? this.expandedFolders,
    includeLocalFiles: includeLocalFiles, filtersPickedByUser: filtersPickedByUser,
    flattenTree: flattenTree, itemToCheckCurationFor: itemToCheckCurationFor,
    includeYourClips: includeYourClips, likedSongsInclusion: likedSongsInclusion,
    yourEpisodesInclusion: yourEpisodesInclusion,
  );
}

class LibraryOption {
  const LibraryOption({required this.id, required this.name});
  factory LibraryOption.fromJson(LibraryJson json) => LibraryOption(
    id: json['id'] as String, name: json['name'] as String);
  final String id;
  final String name;
  LibraryJson toJson() => {'id': id, 'name': name};
}

class LibraryItem {
  LibraryItem.fromJson(LibraryJson data, {LibraryJson source = const {}})
      : data = Map.unmodifiable(data), source = Map.unmodifiable(source), isSupported = true;
  LibraryItem.unsupported({LibraryJson source = const {}})
      : data = const {}, source = Map.unmodifiable(source), isSupported = false;
  final LibraryJson data;
  final LibraryJson source;
  final bool isSupported;
  String get uri => data['uri'] as String? ?? '';
  String get name => data['name'] as String? ?? '';
  String get type => data['type'] as String? ?? 'unsupported';
  bool get pinned => data['pinned'] == true;
  int get canPin => data['canPin'] as int? ?? 2;
  int? get folderDepth => data['folderDepth'] as int?;
  List<LibraryJson> get images => (data['images'] as List? ?? []).cast<LibraryJson>();
  List<String> get contributors {
    final artists = data['artists'];
    if (artists is List) return artists.map((artist) => (artist as Map)['name'] as String).toList();
    final author = data['authorName'];
    if (author is String && author.isNotEmpty) return [author];
    final publisher = data['publisher'];
    if (publisher is String && publisher.isNotEmpty) return [publisher];
    final owner = data['owner'];
    return owner is Map && owner['name'] is String && owner['name'] != '' ? [owner['name'] as String] : [];
  }
  LibraryJson? toJson() => isSupported ? data : null;
}

class LibraryPage {
  LibraryPage({List<LibraryItem> items = const [], this.primaryFilter,
    List<String> passedFilterIds = const [], List<LibraryOption> availableFilters = const [],
    List<LibraryOption> selectedFilters = const [], List<LibraryOption> availableSortOrders = const [],
    this.selectedSortOrder = const LibraryOption(id: '6', name: 'Recents'),
    this.limit = 50, this.offset = 0, this.unfilteredTotalLength = 0, this.totalLength = 0,
    this.hasUnfilteredItems = false, this.hasTextFilter = false, this.reorderAllowed = false,
    this.isSearchComplete = true,
    this.passedFolderUri, this.openedFolderName, this.parentFolderUri, this.openedFolderIsPlayable = false})
      : items = List.unmodifiable(items), passedFilterIds = List.unmodifiable(passedFilterIds),
        availableFilters = List.unmodifiable(availableFilters), selectedFilters = List.unmodifiable(selectedFilters),
        availableSortOrders = List.unmodifiable(availableSortOrders);
  final List<LibraryItem> items;
  final String? primaryFilter;
  final List<String> passedFilterIds;
  final List<LibraryOption> availableFilters;
  final List<LibraryOption> selectedFilters;
  final List<LibraryOption> availableSortOrders;
  final LibraryOption selectedSortOrder;
  final int limit;
  final int offset;
  final int unfilteredTotalLength;
  final int totalLength;
  final bool hasUnfilteredItems;
  final bool hasTextFilter;
  final bool isSearchComplete;
  final bool reorderAllowed;
  final String? passedFolderUri;
  final String? openedFolderName;
  final String? parentFolderUri;
  final bool openedFolderIsPlayable;

  LibraryJson toJson() => {
    if (primaryFilter != null) 'primaryFilter': primaryFilter,
    'passedFilterIds': passedFilterIds,
    'availableFilters': availableFilters.map((option) => option.toJson()).toList(),
    'selectedFilters': selectedFilters.map((option) => option.toJson()).toList(),
    'availableSortOrders': availableSortOrders.map((option) => option.toJson()).toList(),
    'selectedSortOrder': selectedSortOrder.toJson(), 'limit': limit, 'offset': offset,
    'items': items.map((item) => item.toJson()).toList(),
    'unfilteredTotalLength': unfilteredTotalLength, 'totalLength': totalLength,
    'hasUnfilteredItems': hasUnfilteredItems, 'hasTextFilter': hasTextFilter,
    'reorderAllowed': reorderAllowed,
    if (passedFolderUri != null) 'passedFolderUri': passedFolderUri,
    if (openedFolderName != null) 'openedFolderName': openedFolderName,
    if (parentFolderUri != null) 'parentFolderUri': parentFolderUri,
    'openedFolderIsPlayable': openedFolderIsPlayable,
  };
}

class LibraryQueryError implements Exception {
  const LibraryQueryError(this.kind, this.message);
  final String kind;
  final String message;
  @override
  String toString() => message;
}

String libraryEnglishLabel(String key) => const {
  'shared.library.filter.album': 'Albums', 'shared.library.filter.artist': 'Artists',
  'shared.library.filter.author': 'Authors', 'shared.library.filter.playlist': 'Playlists',
  'shared.library.filter.podcasts-courses': 'Podcasts & Courses', 'search.title.shows': 'Podcasts',
  'shared.library.filter.book': 'Audiobooks', 'shared.library.filter.downloaded': 'Downloaded',
  'shared.library.filter.by-you': 'By you', 'shared.library.filter.by-spotify': 'By Spotify',
  'shared.library.filter.unplayed': 'Unplayed', 'shared.library.filter.in-progress': 'In progress',
  'shared.library.filter.events': 'Events', 'shared.library.filter.mixed': 'Mixed',
  'shared.library.filter.venues': 'Venues', 'shared.library.filter.past': 'Past',
  'shared.library.filter.upcoming': 'Upcoming', 'shared.library.sort-by.author': 'Author',
  'shared.library.sort-by.creator': 'Creator', 'shared.library.sort-by.custom': 'Custom order',
  'shared.library.sort-by.name': 'Alphabetical', 'shared.library.sort-by.recently-added': 'Recently added',
  'shared.library.sort-by.recently-played-or-added': 'Recents',
  'shared.library.sort-by.recently-updated': 'Recently updated',
  'shared.library.sort-by.relevance': 'Most relevant', 'tracklist.header.release-date': 'Release date',
  'shared.library.sort-by.date': 'Date',
}[key] ?? key;
