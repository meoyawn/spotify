import '../protocol/generated/playlist_query.pb.dart';
import 'query_tables.dart';

class PlaylistNativeFilter {
  const PlaylistNativeFilter(this.field, this.value, this.operatorCode);
  final String field;
  final String value;
  final int operatorCode;
  Map<String, Object?> toJson() => {'field': field, 'value': value, 'operator': operatorCode};
}

class PlaylistNativeSort {
  const PlaylistNativeSort(this.field, {required this.ascending});
  final String field;
  final bool ascending;
  Map<String, Object?> toJson() => {'field': field, 'ascending': ascending};
}

/// The native Get handler's TrackList query, before provider loading and range.
class PlaylistTrackListQuery {
  PlaylistTrackListQuery({required List<PlaylistNativeSort> sorts, required List<PlaylistNativeFilter> filters,
    required List<int> supportedPlaceholderTypes, required this.availabilityMode, required this.premiumContentMode,
    required this.includeAllPlaceholders, required this.providedSortInternalId, required this.dontLoadItemMetadata})
      : sorts = List.unmodifiable(sorts), filters = List.unmodifiable(filters),
        supportedPlaceholderTypes = List.unmodifiable(supportedPlaceholderTypes);
  final List<PlaylistNativeSort> sorts;
  final List<PlaylistNativeFilter> filters;
  final List<int> supportedPlaceholderTypes;
  final int availabilityMode;
  final int premiumContentMode;
  final bool includeAllPlaceholders;
  final String providedSortInternalId;
  final bool dontLoadItemMetadata;
  Map<String, Object?> toJson() => {
    'sorts': sorts.map((value) => value.toJson()).toList(),
    'filters': filters.map((value) => value.toJson()).toList(),
    'supportedPlaceholderTypes': supportedPlaceholderTypes,
    'availabilityMode': availabilityMode, 'premiumContentMode': premiumContentMode,
    'includeAllPlaceholders': includeAllPlaceholders, 'providedSortInternalId': providedSortInternalId,
    'dontLoadItemMetadata': dontLoadItemMetadata,
  };
}

/// Original native functions0x1014ea100 /0x10158205c and initializer0x101583fe0.
/// Account product, provider admission, list range and decorations are separate.
PlaylistTrackListQuery compilePlaylistQuery(PlaylistQuery query) {
  final sort = _enumValue(query, 3, query.sortBy.value);
  final source = _enumValue(query, 7, query.sourceRestriction.value);
  final predicates = [...query.boolPredicates.map((value) => value.value), ..._unknownEnums(query, 1)];
  if (_unknownEnums(query, 11).isNotEmpty) {
    throw UnsupportedError('Unknown placeholder enum ordering requires the original raw query.');
  }
  final filters = <PlaylistNativeFilter>[
    for (final predicate in predicates)
      if (playlistPredicateTable[predicate] case final value?) PlaylistNativeFilter(value.$1, value.$2, value.$3),
    if (source == 1 || source == 2) PlaylistNativeFilter('originalIndex', source == 1 ? '50' : '500', 3),
    if (query.textFilter.isNotEmpty) PlaylistNativeFilter('text', query.textFilter, 6),
    for (final value in query.descriptorFilter) PlaylistNativeFilter('tags', value, 6),
    for (final value in query.languageFilter) PlaylistNativeFilter('languages', value, 6),
    for (final value in query.attributeFilter)
      if (value.containsOneOf.isNotEmpty) PlaylistNativeFilter('attributes', value.containsOneOf.join(','), 6),
    if (query.tagIdFilter.isNotEmpty) PlaylistNativeFilter('tagIds', query.tagIdFilter.join(','), 6),
    if (query.itemIdFilter.isNotEmpty) PlaylistNativeFilter('rowId', query.itemIdFilter, 0),
  ];
  final metadataForSort = sort < 0 || sort > 24 || (0x007e7ffe >> sort & 1) != 0;
  final metadataForFilters = query.textFilter.isNotEmpty || query.descriptorFilter.isNotEmpty ||
    predicates.any((value) => value < 0 || value > 19 || (0x000d97c5 >> value & 1) == 0);
  return PlaylistTrackListQuery(
    sorts: [for (final value in playlistSortTable[sort] ?? <(String, bool)>[])
      PlaylistNativeSort(value.$1, ascending: value.$2)],
    filters: filters, supportedPlaceholderTypes: query.supportedPlaceholderTypes.map((value) => value.value).toList(),
    availabilityMode: query.showUnavailable ? 2 : 1, premiumContentMode: query.includePremiumContent ? 2 : 1,
    includeAllPlaceholders: query.includeAllPlaceholders, providedSortInternalId: query.providedSortInternalId,
    dontLoadItemMetadata: query.dontLoadItemMetadata && !metadataForSort && !metadataForFilters,
  );
}

List<int> _unknownEnums(PlaylistQuery query, int tag) =>
    query.unknownFields.getField(tag)?.varints.map((value) => value.toInt()).toList() ?? [];
int _enumValue(PlaylistQuery query, int tag, int known) {
  final values = _unknownEnums(query, tag);
  if (values.isEmpty) return known;
  if (query.hasField(tag) || values.length > 1) {
    throw UnsupportedError('Mixed known/unknown scalar enums require the original raw query ordering.');
  }
  return values.single;
}
