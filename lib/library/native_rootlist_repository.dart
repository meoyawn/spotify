import 'package:cancellation_token/cancellation_token.dart';

import 'dart:convert';

import '../async/shared_task.dart';
import '../playlist_service/native_rootlist_read_client.dart';
import '../protocol/generated/playlist_api.pb.dart';
import '../protocol/native_playlist_images.dart';
import 'models.dart';
import 'repository.dart';

/// Read-only saved-playlist projection from real rootlist Items/MetaItems.
/// Album/artist/predefined-list joins, folder markers, filtering and native
/// Library sort policy are not supplied by this endpoint. Their query branches
/// remain explicit unsupported states rather than invented Library contents.
class NativeRootlistLibraryRepository implements LibraryRepository {
  NativeRootlistLibraryRepository(this.client, {required this.imageUrlTemplate});
  final NativeRootlistReadClient client;
  final String imageUrlTemplate;
  static const _pageLength = 120;
  int _generation = 0;
  String? _revision;
  final _pages = <int, SelectedListContent>{};
  final _pendingPages = <int, SharedTask<SelectedListContent>>{};
  CancellationToken _cancellation = CancellationToken();

  Future<SelectedListContent> _readPage(int from, int generation, CancellationToken cancellationToken) async {
    cancellationToken.throwIfCancelled();
    final cached = _pages.remove(from);
    if (cached != null) { _pages[from] = cached; return cached; }
    final existing = _pendingPages[from];
    if (existing != null && !existing.token.isCancelled) return existing.wait(cancellationToken);
    late final SharedTask<SelectedListContent> pending;
    pending = SharedTask((token) => client.read(from: from, length: _pageLength,
      cancellationToken: _cancellation.merge(token)).then((snapshot) {
      if (generation != _generation) throw StateError('Rootlist read was superseded');
      _pages[from] = snapshot..freeze();
      while (_pages.length > 2) { _pages.remove(_pages.keys.first); }
      return snapshot;
    }).whenComplete(() {
      if (identical(_pendingPages[from], pending)) _pendingPages.remove(from);
    }));
    _pendingPages[from] = pending;
    return pending.wait(cancellationToken);
  }

  @override
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (query.filters.isNotEmpty) {
      throw const LibraryQueryError('filter', 'Rootlist joins for these Library filters are not implemented');
    }
    if (query.sortOrder != null && query.sortOrder != '4' || query.sortDirection != null) {
      throw const LibraryQueryError('sort', 'Rootlist currently preserves the server custom order');
    }
    if (query.textFilter.isNotEmpty || query.folderUri != null || query.expandedFolders.isNotEmpty ||
        query.flattenTree || query.itemToCheckCurationFor != null || query.includeLocalFiles ||
        query.likedSongsInclusion == LibraryPlaylistInclusion.always ||
        query.yourEpisodesInclusion == LibraryPlaylistInclusion.always) {
      throw UnsupportedError('This rootlist adapter does not implement folder, text or predefined-list queries');
    }
    if (query.offset < 0 || query.limit <= 0) throw RangeError('Invalid Library rootlist range');
    final generation = query.offset == 0 ? ++_generation : _generation;
    if (query.offset == 0) {
      _cancellation.cancel(); _cancellation = CancellationToken();
      _revision = null; _pages.clear(); _pendingPages.clear();
    }
    final token = MergedCancellationToken([_cancellation, ?cancellationToken]);
    var from = query.offset ~/ _pageLength * _pageLength;
    final items = <LibraryItem>[];
    var total = -1;
    do {
      final snapshot = await _readPage(from, generation, token);
      token.throwIfCancelled();
      if (generation != _generation) throw StateError('Rootlist read was superseded');
      if (!snapshot.hasLength() || snapshot.length < 0) {
        throw const FormatException('Rootlist snapshot does not provide its total length');
      }
      final revision = snapshot.hasRevision() ? base64Encode(snapshot.revision) : null;
      if (_revision != null && revision != _revision) {
        throw StateError('Rootlist changed during paging; refresh the Library');
      }
      if (from != 0 && revision == null) {
        throw UnsupportedError('Rootlist paging requires the server revision');
      }
      _revision ??= revision;
      if (total < 0) total = snapshot.length;
      final contents = snapshot.contents;
      if (snapshot.length != total || contents.items.length != contents.metaItems.length ||
          contents.items.length > _pageLength || from + contents.items.length > total) {
        throw const FormatException('Rootlist contents and decoration positions are inconsistent');
      }
      final start = query.offset > from ? query.offset - from : 0;
      for (var index = start; index < contents.items.length && items.length < query.limit; index++) {
        items.add(_item(contents.items[index], contents.metaItems[index], from + index));
      }
      from += contents.items.length;
      if (from < total && (!contents.truncated || contents.items.isEmpty)) {
        throw const FormatException('Rootlist response ended before its declared length');
      }
    } while (items.length < query.limit && from < total);
    return LibraryPage(items: items, offset: query.offset, limit: query.limit,
      totalLength: total, unfilteredTotalLength: total, hasUnfilteredItems: total > 0,
      selectedSortOrder: const LibraryOption(id: '4', name: 'Custom order'));
  }

  LibraryItem _item(Item item, MetaItem meta, int position) {
    final source = <String, Object?>{'nativeItem': item, 'nativeMetaItem': meta, 'rootlistPosition': position};
    if (!RegExp(r'^spotify:playlist:[0-9A-Za-z]{22}$').hasMatch(item.uri) ||
        !meta.hasStatusCode() || meta.statusCode != 200 || !meta.hasAttributes() ||
        meta.capabilities.hasCanView() && !meta.capabilities.canView) {
      return LibraryItem.unsupported(source: source);
    }
    final attributes = meta.attributes;
    return LibraryItem.fromJson({
      'type': 'playlist', 'uri': item.uri, 'name': attributes.name,
      'images': nativePlaylistImages(attributes, imageUrlTemplate: imageUrlTemplate),
      if (meta.hasOwnerUsername()) 'owner': {'type': 'user',
        'username': meta.ownerUsername, 'name': meta.ownerUsername},
      if (meta.hasOwnerUsername()) 'isOwnedBySelf': meta.ownerUsername == client.username,
      if (meta.hasLength()) 'numberOfItems': meta.length,
      if (meta.hasLength()) 'isEmpty': meta.length == 0,
      if (meta.capabilities.hasCanView()) 'canView': meta.capabilities.canView,
      if (meta.capabilities.hasCanEditItems()) 'canAddTo': meta.capabilities.canEditItems,
      if (attributes.hasCollaborative()) 'isCollaborative': attributes.collaborative,
      if (attributes.hasDeletedByOwner()) 'deletedByOwner': attributes.deletedByOwner,
      'canReorder': false,
    }, source: source);
  }
}
