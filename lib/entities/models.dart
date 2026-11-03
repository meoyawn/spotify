typedef EntityJson = Map<String, Object?>;

/// A navigation target carried by actual entity metadata. No name lookup or
/// inferred identifier is used when a source omits its canonical URI.
class EntityLink {
  EntityLink({required this.uri, required this.name, required this.type,
    EntityJson data = const {}}) : data = Map.unmodifiable(data);
  final String uri, name, type;
  final EntityJson data;

  static EntityLink? fromJson(EntityJson data, {required String type}) {
    final uri = data['uri'], name = data['name'];
    if (uri is! String || name is! String || name.isEmpty ||
        !const {'track', 'artist', 'album', 'playlist'}.contains(type) ||
        !RegExp('^spotify:$type:[0-9A-Za-z]{22}\$').hasMatch(uri)) { return null; }
    return EntityLink(uri: uri, name: name, type: type, data: data);
  }
}

class EntityFeatures {
  const EntityFeatures({this.watchFeed = false, this.authors = false, this.ageAssurance = false});
  final bool watchFeed;
  final bool authors;
  final bool ageAssurance;
}

class EntityDetails {
  EntityDetails.fromJson(EntityJson data, {EntityJson source = const {}, List<String> unsupportedFeatures = const []})
      : data = Map.unmodifiable(data), source = Map.unmodifiable(source), unsupportedFeatures = List.unmodifiable(unsupportedFeatures);
  final EntityJson data;
  final EntityJson source;
  final List<String> unsupportedFeatures;
  String get uri => data['uri'] as String? ?? '';
  String get type => data['type'] as String? ?? '';
  String get name => data['name'] as String? ?? '';
  String get description => data['description'] as String? ?? '';
  List<EntityJson> get images => (data['images'] as List? ?? []).cast<EntityJson>();
  /// Original playlist route: desktop header first, mobile image as fallback.
  /// Cover sources remain separate for Home, Library and playback contexts.
  String? get headerImageUrl {
    if (type != 'playlist') return null;
    final attributes = (data['formatListData'] as Map?)?['attributes'];
    if (attributes is! Map) return null;
    for (final key in ['header_image_url_desktop', 'image_url']) {
      final url = attributes[key];
      if (url is String && url.isNotEmpty) return url;
    }
    return null;
  }
  List<String> get contributors {
    final artists = data['artists'];
    if (artists is List) return artists.map((artist) => (artist as Map)['name'] as String).toList();
    final owner = data['owner'];
    if (owner is Map) {
      final name = owner['displayName'] ?? owner['username'];
      if (name is String && name.isNotEmpty) return [name];
    }
    return [];
  }
  int get trackCount => data['nrTracks'] as int? ?? data['totalLength'] as int? ?? 0;
  EntityJson get discs => (data['discs'] as Map?)?.cast<String, Object?>() ?? {};
  bool get hasDiscRows => (discs['totalCount'] as int? ?? 0) >= 2 && (discs['totalCount'] as int? ?? 0) <= 10;
  int get rowCount => trackCount + (hasDiscRows ? discs['totalCount'] as int : 0);
  num? get durationMs {
    final duration = data['duration'];
    return duration is Map ? (duration['durationMs'] ?? duration['milliseconds']) as num? : null;
  }
  bool get isPlayable => data['isPlayable'] == true || data['canPlay'] == true;
  bool get canRequestPlayback => isPlayable || data['canRequestPlayback'] == true;
  bool get isAccessible => (data['permissions'] as Map?)?['canView'] != false;
  EntityJson toJson() => data;
}

class EntityRow {
  EntityRow.fromJson(EntityJson data, {EntityJson source = const {}, List<String> unsupportedFeatures = const []})
      : data = Map.unmodifiable(data), source = Map.unmodifiable(source),
        unsupportedFeatures = List.unmodifiable(unsupportedFeatures), isSupported = true;
  EntityRow.unsupported({EntityJson source = const {}})
      : data = const {}, source = Map.unmodifiable(source), unsupportedFeatures = const [], isSupported = false;
  final EntityJson data;
  final EntityJson source;
  final List<String> unsupportedFeatures;
  final bool isSupported;
  String get type => data['type'] as String? ?? 'unsupported';
  bool get isDisc => type == 'AlbumDisc';
  String get uri => data['uri'] as String? ?? '';
  String get playbackUri => data['linkedUri'] as String? ?? uri;
  String? get uid => data['uid'] as String?;
  String get name => data['name'] as String? ?? '';
  List<EntityJson> get artists => (data['artists'] as List? ?? []).cast<EntityJson>();
  Map<String, String> get playbackArtistMetadata => {
    for (final (index, artist) in artists.take(10).indexed) ...{
      if (artist['name'] case final String name) 'artist_name${index == 0 ? '' : ':$index'}': name,
      if (artist['uri'] case final String uri) 'artist_uri${index == 0 ? '' : ':$index'}': uri,
    },
  };
  EntityJson? get album => (data['album'] as Map?)?.cast<String, Object?>();
  List<EntityJson> get images => (data['images'] as List? ?? album?['images'] as List? ?? []).cast<EntityJson>();
  int? get discNumber => data['discNumber'] as int?;
  int? get trackNumber => data['trackNumber'] as int?;
  int? get durationMs => (data['duration'] as Map?)?['milliseconds'] as int?;
  bool get isPlayable => data['isPlayable'] == true;
  bool get canRequestPlayback => isPlayable || data['canRequestPlayback'] == true;
  bool get isExplicit => data['isExplicit'] == true;
  EntityJson? toJson() => isSupported ? data : null;
}

class EntityTrackPage {
  EntityTrackPage({List<EntityRow> rows = const [], required this.offset,
    required this.limit, required this.totalLength, this.nextOffset}) : rows = List.unmodifiable(rows);
  final List<EntityRow> rows;
  final int offset;
  final int limit;
  final int totalLength;
  final int? nextOffset;
  EntityJson toJson() => {'items': rows.map((row) => row.toJson()).toList(),
    'offset': offset, 'limit': limit, 'totalLength': totalLength};
}

class EntityPage {
  const EntityPage({required this.details, required this.tracks});
  final EntityDetails details;
  final EntityTrackPage tracks;
}

/// Selection metadata for a caller-owned player. rowIndex is a display index.
class EntityPlaybackSelection {
  const EntityPlaybackSelection({required this.entity, this.row, this.rowIndex, this.rows});
  final EntityDetails entity;
  final EntityRow? row;
  final int? rowIndex;
  final List<EntityRow>? rows;
  String get contextUri => entity.data['playbackUri'] as String? ?? entity.uri;
  String? get trackUri => row?.playbackUri;
  String? get uid => row?.uid;
}

class EntityQueryError implements Exception {
  const EntityQueryError(this.errors);
  final Object? errors;
  @override
  String toString() => 'EntityQueryError: $errors';
}
