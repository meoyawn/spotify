import 'package:cancellation_token/cancellation_token.dart';

import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';

import '../protocol/esperanto.dart';
import '../protocol/generated/your_library_config.pb.dart' as cfg;
import '../protocol/generated/your_library_request.pb.dart' as req;
import '../protocol/generated/your_library_response.pb.dart' as res;
import 'models.dart';

part 'projection.dart';

abstract interface class LibraryRepository {
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken});
}

abstract interface class RefreshableLibraryRepository implements LibraryRepository {
  void invalidate();
}

/// Local matches can precede the remaining, cancellable metadata reads.
abstract interface class LibrarySearchRepository implements LibraryRepository {
  Stream<LibraryPage> search(LibraryQuery query, {CancellationToken? cancellationToken});
  void cancelPendingRead();
}

/// The desktop LibraryAPI's native All call; no platform sender is installed.
class EsperantoLibraryRepository implements LibraryRepository {
  const EsperantoLibraryRepository(this.dispatcher, {
    this.features = const LibraryFeatures(), this.localize = libraryEnglishLabel,
  });
  static const service = 'spotify.your_library_esperanto.proto.YourLibraryService';
  final EsperantoDispatcher dispatcher;
  final LibraryFeatures features;
  final LibraryLabelResolver localize;

  @override
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final numeric = <int>[];
    for (final id in query.filters.where((id) => !id.startsWith('spotify:concept:'))) {
      final value = int.tryParse(id);
      if (value == null) throw LibraryQueryError('filter', '"$id" is not a valid YLX filter.');
      numeric.add(value);
    }
    final tag = query.filters.where((id) => id.startsWith('spotify:concept:')).firstOrNull;
    final primary = _ordered(numeric).firstOrNull;
    // The source tests the numeric primary filter for truthiness, including ALBUM=0.
    final prefix = query.expandedFolders.isNotEmpty && query.textFilter.isEmpty && tag == null &&
        (primary == null || primary == 0 || primary == 2 || primary == 100);
    var text = query.textFilter;
    List<String>? curated = query.itemToCheckCurationFor == null ? null : [...query.itemToCheckCurationFor!];
    var curatedMode = req.CuratedItems_CuratedItemsFilter.GROUP_BY;
    final curationUri = _curationUri(text);
    if (curationUri != null) {
      if (curated == null) { curated = []; curatedMode = req.CuratedItems_CuratedItemsFilter.ONLY_CURATED; }
      curated.add(curationUri);
      text = '';
    }
    final sort = _sort(int.tryParse(query.sortOrder ?? ''), primary, localize);
    final header = req.YourLibraryRequestHeader(
      length: prefix ? query.offset + query.limit : query.limit,
      skip: prefix ? 0 : query.offset, textFilter: text,
      sortOrder: cfg.YourLibrarySortOrder(
        sortOrder: cfg.YourLibrarySortOrder_SortOrder.valueOf(int.parse(sort.id)),
        reverse: query.sortDirection == LibrarySortDirection.reverse),
      filters: cfg.YourLibraryFilters(filter: numeric.map((id) {
        final filter = cfg.YourLibraryFilters_Filter.valueOf(id);
        if (filter == null) throw LibraryQueryError('filter', '"$id" is not a valid YLX filter.');
        return filter;
      })),
      totalCount: true, allPlaylists: query.textFilter.isNotEmpty || tag != null || query.flattenTree,
      fillFolders: query.expandedFolders.map(_folderId).whereType<Int64>(),
      folderId: query.folderUri == null ? null : _folderId(query.folderUri!),
      numLinkTypesInPlaylists: true,
      curatedItems: curated == null ? null : req.CuratedItems(items: curated, filter: curatedMode),
      tagFilter: tag == null ? null : req.YourLibraryTagFilter(tagUri: tag),
      includePrereleases: true, includeEvents: true, includeAuthors: features.authors,
      includeVenues: features.venues, includeConcertCampaigns: features.concertCampaigns,
    );
    cfg.YourLibraryPredefinedPlaylistConfig? inclusion(LibraryPlaylistInclusion value) =>
        value == LibraryPlaylistInclusion.exclude ? null : cfg.YourLibraryPredefinedPlaylistConfig(
          inclusionMode: value == LibraryPlaylistInclusion.always
              ? cfg.YourLibraryPredefinedPlaylistConfig_InclusionMode.INCLUDE_ALWAYS
              : cfg.YourLibraryPredefinedPlaylistConfig_InclusionMode.INCLUDE_IF_NOT_EMPTY);
    final request = req.YourLibraryRequest(header: header,
      predefinedPlaylistConfigs: cfg.YourLibraryPredefinedPlaylistConfigs(
        likedSongs: inclusion(query.likedSongsInclusion), yourEpisodes: inclusion(query.yourEpisodesInclusion),
        localFiles: query.includeLocalFiles ? cfg.YourLibraryPredefinedPlaylistConfig(
          inclusionMode: cfg.YourLibraryPredefinedPlaylistConfig_InclusionMode.INCLUDE_IF_NOT_EMPTY,
          decorateNumLinkTypes: true) : null,
        highlights: cfg.YourLibraryPredefinedPlaylistConfig(inclusionMode: query.includeYourClips
            ? cfg.YourLibraryPredefinedPlaylistConfig_InclusionMode.INCLUDE_IF_NOT_EMPTY
            : cfg.YourLibraryPredefinedPlaylistConfig_InclusionMode.EXCLUDE),
        kallax: cfg.YourLibraryPredefinedPlaylistConfig(), allAvailableConfigsProvided: true,
      ));
    _omitScalarDefaults(request);
    final bytes = await dispatcher.callSingle(EsperantoCall(service, 'All', _originalRequestBytes(request)),
      cancellationToken: cancellationToken);
    return _project(_messageMap(res.YourLibraryResponse.fromBuffer(bytes)), query, prefix, features, localize);
  }
}

String? _curationUri(String value) {
  if (RegExp(r'^spotify:(?:track|episode|show):[^:]+$').hasMatch(value)) return value;
  if (value.startsWith('spotify:local:')) {
    final parts = value.split(':');
    if (parts.length < 5) return null;
    final names = parts.sublist(2, 5).map((part) => Uri.encodeQueryComponent(Uri.decodeQueryComponent(part)));
    final rawDuration = parts.elementAtOrNull(5);
    final parsed = rawDuration == null || rawDuration.isEmpty ? ''
        : int.tryParse(RegExp(r'^\s*[+-]?\d+').firstMatch(rawDuration)?.group(0)?.trim() ?? '')?.toString() ?? 'NaN';
    return 'spotify:local:${names.join(':')}:$parsed';
  }
  final uri = Uri.tryParse(value);
  if (uri != null && {'open.spotify.com', 'play.spotify.com'}.contains(uri.host) && uri.pathSegments.length >= 2 &&
      {'track', 'episode', 'show'}.contains(uri.pathSegments[0])) {
    return 'spotify:${uri.pathSegments[0]}:${uri.pathSegments[1]}';
  }
  return null;
}

/// Original JS field order and its explicit empty packed fields are observable.
/// The standard protobuf writer owns every field's encoding.
List<int> _originalRequestBytes(GeneratedMessage message) {
  final writer = CodedBufferWriter();
  final fields = message.info_.fieldInfo;
  final order = message is req.YourLibraryRequestHeader
      ? [9, 18, 10, 37, 11, 12, 13, 14, 15, 16, 17, 34, 22, 24, 25, 26, 29, 30, 35, 31, 33, 36]
      : fields.keys;
  for (final number in order) {
    final field = fields[number]!;
    final value = message.getField(number);
    if (field.isRepeated) {
      if (value is List && value.isEmpty &&
          (message is cfg.YourLibraryFilters && number == 1 || message is req.YourLibraryRequestHeader && number == 34)) {
        writer.writeField(number, PbFieldType.OY, <int>[]);
      } else {
        writer.writeField(number, field.type, value);
      }
    } else if (message.hasField(number)) {
      if (value is GeneratedMessage) {
        writer.writeField(number, PbFieldType.OY, _originalRequestBytes(value));
      } else {
        writer.writeField(number, field.type, value);
      }
    }
  }
  return writer.toBuffer();
}

Int64? _folderId(String uri) {
  final match = RegExp(r'^spotify:user:[^:]*:folder:([0-9a-fA-F]+)$').firstMatch(uri);
  return match == null ? null : Int64.parseHex(match.group(1)!);
}

void _omitScalarDefaults(GeneratedMessage message) {
  for (final field in message.info_.fieldInfo.values) {
    final value = message.getField(field.tagNumber);
    if (value is GeneratedMessage) {
      if (message.hasField(field.tagNumber)) _omitScalarDefaults(value);
    } else if (!field.isRepeated && !message.info_.oneofs.containsKey(field.tagNumber) &&
        (value == false || value == 0 || value == '' || value is ProtobufEnum && value.value == 0)) {
      message.clearField(field.tagNumber);
    }
  }
}

LibraryJson _messageMap(GeneratedMessage message) => {
  for (final field in message.info_.fieldInfo.values)
    if ((message.getField(field.tagNumber) is! GeneratedMessage || message.hasField(field.tagNumber)) &&
        (!message.info_.oneofs.containsKey(field.tagNumber) || message.hasField(field.tagNumber)))
      field.name: _messageValue(message.getField(field.tagNumber)),
};
Object? _messageValue(Object? value) => switch (value) {
  GeneratedMessage() => _messageMap(value),
  ProtobufEnum() => value.value,
  Int64() => value.toString(),
  List() => value.map(_messageValue).toList(),
  _ => value,
};
