import 'package:cancellation_token/cancellation_token.dart';

import 'dart:async';

import '../async/shared_task.dart';
import '../home/native_recent_contexts.dart';
import '../protocol/generated/playlist_api.pb.dart' as playlist;
import 'models.dart';
import 'native_collection_read_client.dart';
import 'native_metadata_client.dart';
import 'native_rootlist_repository.dart';
import 'native_rootlist_folders.dart';
import 'saved_playlists.dart';
import 'native_saved_tracks.dart';
import 'repository.dart';

/// Session-owned joins over independently verified native rootlist, collection
/// and base metadata reads. Query changes reuse the complete source snapshots;
/// only a refresh invalidates them. Recents joins actual server play history;
/// opening a page or selecting a row never counts as playing it.
class NativeLibraryRepository implements RefreshableLibraryRepository, LibrarySearchRepository, SavedPlaylistsRepository {
  NativeLibraryRepository({required this.rootlist, required this.collection,
    required this.artists, required this.metadata, this.recentContexts});
  final NativeRootlistLibraryRepository rootlist;
  final NativeCollectionReadClient collection, artists;
  final NativeLibraryMetadataClient metadata;
  final NativeRecentContextsClient? recentContexts;
  SharedTask<List<_Entry>>? _snapshot;
  SharedTask<List<_Entry>>? _rootSnapshot;
  CancellationToken _query = CancellationToken();
  Future<void> _playlistWrites = Future.value();
  int _queuedPlaylistWrites = 0;

  @override
  Future<bool> containsPlaylist(String uri, {CancellationToken? cancellationToken}) async =>
    (await _rootEntries(cancellationToken ?? CancellationToken())).any((entry) => entry.uri == uri);

  @override
  Future<void> setPlaylistSaved(String uri, bool saved, {CancellationToken? cancellationToken}) async {
    if (_queuedPlaylistWrites >= 16) throw StateError('A library change is still in progress');
    _queuedPlaylistWrites++;
    final token = cancellationToken ?? CancellationToken();
    final previous = _playlistWrites;
    final write = _playlistWrites = previous.catchError((Object _) {}).then((_) async {
      token.throwIfCancelled();
      try {
        await rootlist.client.setPlaylistSaved(uri, saved, cancellationToken: token);
      } finally {
        _snapshot?.token.cancel(); _rootSnapshot?.token.cancel();
        _snapshot = null; _rootSnapshot = null;
      }
      if (await containsPlaylist(uri, cancellationToken: token) != saved) {
        throw StateError('Spotify has not confirmed the playlist’s library status');
      }
    }).whenComplete(() => _queuedPlaylistWrites--);
    // Preserve serialization even if a queued caller leaves before its turn.
    unawaited(write.catchError((Object _) {}));
    await write.asCancellable(token);
  }

  @override void cancelPendingRead() { _query.cancel(); _query = CancellationToken(); }

  @override
  Stream<LibraryPage> search(LibraryQuery query, {CancellationToken? cancellationToken}) async* {
    final token = MergedCancellationToken([_query, ?cancellationToken]);
    final cached = await _load(query, cachedOnly: true, cancellationToken: token);
    yield cached;
    token.throwIfCancelled();
    if (cached.isSearchComplete) return;
    yield await _load(query, cancellationToken: token);
  }

  @override
  void invalidate() {
    // A newly attached Library can reuse a Contains snapshot already in flight.
    if (_snapshot == null && _rootSnapshot == null) return;
    cancelPendingRead();
    _snapshot?.token.cancel(); _rootSnapshot?.token.cancel();
    _snapshot = null;
    _rootSnapshot = null;
    collection.invalidate();
    artists.invalidate();
    recentContexts?.invalidate();
  }

  Future<List<_Entry>> _entries(CancellationToken cancellationToken) {
    if (_snapshot?.token.isCancelled == true) _snapshot = null;
    late final SharedTask<List<_Entry>> pending;
    final task = _snapshot ??= pending = SharedTask((token) => _read(token).onError((Object error, StackTrace stack) {
      if (identical(_snapshot, pending)) _snapshot = null;
      Error.throwWithStackTrace(error, stack);
    }));
    return task.wait(cancellationToken);
  }

  Future<List<_Entry>> _read(CancellationToken token) async {
    token.throwIfCancelled();
    final (root, saved, followed) = await (_rootEntries(token), collection.items(cancellationToken: token),
      artists.items(cancellationToken: token)).wait;
    token.throwIfCancelled();
    final entries = [...root];
    var liked = 0;
    final seen = <String>{for (final entry in entries) entry.uri};
    for (final item in saved) {
      final uri = item.uri;
      if (RegExp(r'^spotify:track:[A-Za-z0-9]{22}$').hasMatch(uri)) { liked++; }
      else if (RegExp(r'^spotify:album:[A-Za-z0-9]{22}$').hasMatch(uri) && seen.add(uri)) {
        entries.add(_Entry(uri: uri, type: 'album', added: item.addedAt.toInt()));
      }
    }
    for (final item in followed) {
      final uri = item.uri;
      if (RegExp(r'^spotify:artist:[A-Za-z0-9]{22}$').hasMatch(uri) && seen.add(uri)) {
        entries.add(_Entry(uri: uri, type: 'artist', added: item.addedAt.toInt()));
      }
    }
    if (liked > 0) {
      entries.insert(0, _liked(liked));
    }
    return List.unmodifiable(entries);
  }

  Future<List<_Entry>> _rootEntries(CancellationToken cancellationToken) {
    if (_rootSnapshot?.token.isCancelled == true) _rootSnapshot = null;
    late final SharedTask<List<_Entry>> pending;
    final task = _rootSnapshot ??= pending = SharedTask((token) => _rootlist(token).onError((Object error, StackTrace stack) {
      if (identical(_rootSnapshot, pending)) _rootSnapshot = null;
      Error.throwWithStackTrace(error, stack);
    }));
    return task.wait(cancellationToken);
  }

  Future<List<_Entry>> _rootlist(CancellationToken token) async {
    final entries = <_Entry>[];
    final parents = <_Entry>[], folders = <String>{};
    var offset = 0;
    while (true) {
      token.throwIfCancelled();
      final page = await rootlist.load(LibraryQuery(offset: offset, limit: 120), cancellationToken: token);
      for (final item in page.items) {
        if (item.uri == NativeSavedTracksRepository.likedSongsAsPlaylistUri) continue;
        final native = item.source['nativeItem'] as playlist.Item;
        final position = item.source['rootlistPosition'] as int;
        final added = native.attributes.hasTimestamp() ? native.attributes.timestamp.toInt() ~/ 1000 : 0;
        final marker = NativeRootlistFolderMarker.parse(native.uri);
        if (marker != null) {
          final uri = nativeRootlistFolderUri(rootlist.client.username, marker.id);
          if (marker.opens) {
            if (!folders.add(uri)) throw const FormatException('Rootlist has a duplicate folder identity');
            final folder = _Entry(uri: uri, type: 'folder',
              item: LibraryItem.fromJson({'type': 'folder', 'uri': uri, 'name': marker.name,
                'canReorder': false}, source: {...item.source, 'nativeParentFolderUri': parents.lastOrNull?.uri}),
              position: position, added: added);
            entries.add(folder); parents.add(folder);
          } else {
            if (parents.isEmpty || parents.last.uri != uri) throw const FormatException('Rootlist folder boundaries are inconsistent');
            parents.removeLast();
          }
          continue;
        }
        final parent = parents.lastOrNull?.uri;
        final source = {...item.source, 'nativeParentFolderUri': parent};
        final nested = item.isSupported ? LibraryItem.fromJson(item.data, source: source)
          : LibraryItem.unsupported(source: source);
        entries.add(_Entry(uri: native.uri, type: item.type, item: nested, added: added, position: position));
      }
      offset += page.items.length;
      if (offset >= page.totalLength) {
        if (parents.isNotEmpty) throw const FormatException('Rootlist has an unclosed folder');
        return List.unmodifiable(entries);
      }
      if (page.items.isEmpty) throw const FormatException('Library rootlist ended before its total');
    }
  }

  _Entry _liked(int count) => _Entry(uri: NativeSavedTracksRepository.likedSongsAsPlaylistUri,
    type: 'playlist', item: LibraryItem.fromJson({'type': 'liked-songs',
      'uri': NativeSavedTracksRepository.likedSongsAsPlaylistUri, 'name': 'Liked Songs',
      'numberOfItems': count, 'isEmpty': count == 0, 'isOwnedBySelf': true,
      'canView': true, 'canReorder': false, 'images': <LibraryJson>[]}), predefined: true);

  @override
  Future<LibraryPage> load(LibraryQuery query, {CancellationToken? cancellationToken}) =>
    _load(query, cancellationToken: cancellationToken);

  Future<LibraryPage> _load(LibraryQuery query, {bool cachedOnly = false, CancellationToken? cancellationToken}) async {
    final token = MergedCancellationToken([_query, ?cancellationToken]);
    token.throwIfCancelled();
    if (query.offset < 0 || query.limit <= 0) throw RangeError('Invalid Library range');
    if (query.itemToCheckCurationFor != null || query.includeLocalFiles ||
        query.filters.any((id) => !const {'0', '1', '2', '102', '103'}.contains(id))) {
      throw const LibraryQueryError('filter', 'This Library filter is not available');
    }
    final main = query.filters.where(const {'0', '1', '2'}.contains).toList();
    if (main.length > 1 || query.filters.any(const {'102', '103'}.contains) && main.singleOrNull != '2') {
      throw const LibraryQueryError('filter', 'This Library filter combination is not available');
    }
    final primary = query.folderUri != null ? '2' : main.firstOrNull;
    final sorts = <LibraryOption>[
      if (recentContexts != null) const LibraryOption(id: '6', name: 'Recents'),
      const LibraryOption(id: '1', name: 'Recently added'),
      const LibraryOption(id: '0', name: 'Alphabetical'),
      if (primary != '1') const LibraryOption(id: '2', name: 'Creator'),
      if (primary == '0') const LibraryOption(id: '9', name: 'Release date'),
      if (primary == '2') const LibraryOption(id: '4', name: 'Custom order'),
    ];
    final sort = query.sortOrder ?? (recentContexts == null ? '1' : '6');
    if (!sorts.any((option) => option.id == sort)) {
      throw const LibraryQueryError('sort', 'This Library sort order is not available');
    }
    final source = query.folderUri != null ? await _rootEntries(token) : await _entries(token);
    final played = <String, int>{};
    if (sort == '6' && recentContexts != null) {
      final history = await recentContexts!.read(cancellationToken: token);
      for (final context in history.response.contexts) {
        final time = context.lastPlayedTime.toInt(), uri = context.uri;
        if (time > (played[uri] ?? 0)) played[uri] = time;
      }
    }
    token.throwIfCancelled();
    final folders = {for (final entry in source) if (entry.type == 'folder') entry.uri: entry};
    final folderUri = query.folderUri == null ? null
      : nativeRootlistCanonicalFolderUri(query.folderUri!, rootlist.client.username);
    final opened = folders[folderUri];
    if (query.folderUri != null && opened == null) throw const LibraryQueryError('folder', 'This folder is no longer in Your Library');
    bool inFolder(_Entry entry) {
      if (folderUri == null) return true;
      var parent = entry.parentUri;
      while (parent != null) {
        if (parent == folderUri) return true;
        parent = folders[parent]?.parentUri;
      }
      return false;
    }
    final all = source.where(inFolder).where((entry) => !entry.predefined ||
      query.likedSongsInclusion != LibraryPlaylistInclusion.exclude).toList();
    if (folderUri == null && query.likedSongsInclusion == LibraryPlaylistInclusion.always && !all.any((entry) => entry.predefined)) {
      all.insert(0, _liked(0));
    }
    final entries = all.where((entry) {
      if (primary != null && entry.type != const {'0': 'album', '1': 'artist', '2': 'playlist'}[primary] &&
          !(primary == '2' && entry.type == 'folder')) { return false; }
      if (query.filters.contains('102') && entry.item?.data['isOwnedBySelf'] != true) return false;
      if (query.filters.contains('103')) {
        final owner = entry.item?.data['owner'];
        if (owner is! Map || owner['username'] != 'spotify') return false;
      }
      return true;
    }).toList();
    final descriptions = <String, LibraryItem>{};
    for (final entry in entries) {
      if (entry.item != null) continue;
      final cached = metadata.cached(entry.uri);
      if (cached != null) descriptions[entry.uri] = cached;
    }
    final complete = !cachedOnly || entries.every((entry) => entry.item != null || descriptions.containsKey(entry.uri));
    if (cachedOnly) entries.removeWhere((entry) => entry.item == null && !descriptions.containsKey(entry.uri));
    Future<void> describe(Iterable<_Entry> selected) async {
      descriptions.addAll(await metadata.describe(selected.where((entry) => entry.item == null &&
        !descriptions.containsKey(entry.uri)).map((entry) => entry.uri),
        cancellationToken: token));
    }
    LibraryItem item(_Entry entry) => entry.item ?? descriptions[entry.uri]!;
    if (query.textFilter.isNotEmpty || const {'0', '2', '9'}.contains(sort)) await describe(entries);
    token.throwIfCancelled();
    if (query.textFilter.isNotEmpty) {
      final text = query.textFilter.toLowerCase();
      entries.removeWhere((entry) {
        final data = item(entry);
        return !data.name.toLowerCase().contains(text) &&
          !data.contributors.any((name) => name.toLowerCase().contains(text));
      });
    }
    final indices = {for (final (index, entry) in entries.indexed) entry: index};
    int compare(_Entry a, _Entry b) {
      final aPinned = a.item?.pinned == true, bPinned = b.item?.pinned == true;
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      if (sort != '6' && a.predefined != b.predefined) return a.predefined ? -1 : 1;
      var order = switch (sort) {
        '0' => item(a).name.toLowerCase().compareTo(item(b).name.toLowerCase()),
        '2' => (a.type == 'artist' ? item(a).name : item(a).contributors.join(', ')).toLowerCase()
          .compareTo((b.type == 'artist' ? item(b).name : item(b).contributors.join(', ')).toLowerCase()),
        '9' => (item(b).data['releaseSortValue'] as int? ?? 0).compareTo(item(a).data['releaseSortValue'] as int? ?? 0),
        '4' => a.position.compareTo(b.position),
        '6' => _recentTime(b, played).compareTo(_recentTime(a, played)),
        _ => b.added.compareTo(a.added),
      };
      if (order == 0) order = indices[a]!.compareTo(indices[b]!);
      return query.sortDirection == LibrarySortDirection.reverse && sort != '4' ? -order : order;
    }
    final flattened = query.textFilter.isNotEmpty || query.flattenTree || primary == '0' || primary == '1' ||
      query.filters.any(const {'102', '103'}.contains);
    final ordered = <_Entry>[], depths = <_Entry, int>{};
    if (flattened) {
      entries.sort(compare); ordered.addAll(entries);
    } else {
      final children = <String?, List<_Entry>>{};
      for (final entry in entries) { (children[entry.parentUri] ??= []).add(entry); }
      for (final group in children.values) { group.sort(compare); }
      final expanded = {for (final uri in query.expandedFolders)
        nativeRootlistCanonicalFolderUri(uri, rootlist.client.username)};
      void append(String? parent, int depth) {
        for (final entry in children[parent] ?? const <_Entry>[]) {
          ordered.add(entry); depths[entry] = depth;
          if (entry.type == 'folder' && expanded.contains(entry.uri)) append(entry.uri, depth + 1);
        }
      }
      append(folderUri, 0);
    }
    final visible = ordered.skip(query.offset).take(query.limit).toList(growable: false);
    await describe(visible.where((entry) => !descriptions.containsKey(entry.uri)));
    token.throwIfCancelled();
    LibraryItem displayed(_Entry entry) {
      final value = item(entry);
      if (!value.isSupported) return value;
      return LibraryItem.fromJson({...value.data,
        if (played[entry.uri] case final time?) 'lastPlayedAt': DateTime.fromMillisecondsSinceEpoch(time, isUtc: true).toIso8601String(),
        if (depths[entry] != null) 'folderDepth': depths[entry],
        if (entry.type == 'folder') 'isFlattened': flattened}, source: value.source);
    }
    final filters = [
      if ((primary == null || primary == '2') && all.any((entry) => entry.type == 'playlist')) const LibraryOption(id: '2', name: 'Playlists'),
      if ((primary == null || primary == '0') && all.any((entry) => entry.type == 'album')) const LibraryOption(id: '0', name: 'Albums'),
      if ((primary == null || primary == '1') && all.any((entry) => entry.type == 'artist')) const LibraryOption(id: '1', name: 'Artists'),
      if (primary == '2' && all.any((entry) => entry.item?.data['isOwnedBySelf'] == true)) const LibraryOption(id: '102', name: 'By you'),
      if (primary == '2' && all.any((entry) => entry.item?.data['owner'] is Map &&
          (entry.item!.data['owner'] as Map)['username'] == 'spotify')) const LibraryOption(id: '103', name: 'By Spotify'),
    ];
    return LibraryPage(items: visible.map(displayed).toList(),
      offset: query.offset, limit: query.limit,
      totalLength: ordered.length, unfilteredTotalLength: all.length, hasUnfilteredItems: all.isNotEmpty,
      hasTextFilter: query.textFilter.isNotEmpty, primaryFilter: const {'0': 'album', '1': 'artist', '2': 'playlist'}[primary],
      isSearchComplete: complete,
      passedFilterIds: query.filters, availableFilters: filters,
      selectedFilters: filters.where((option) => query.filters.contains(option.id) && (folderUri == null || option.id != '2')).toList(),
      passedFolderUri: folderUri, openedFolderName: opened?.item?.name, parentFolderUri: opened?.parentUri,
      selectedSortOrder: sorts.singleWhere((option) => option.id == sort), availableSortOrders: sorts);
  }
}

int _recentTime(_Entry entry, Map<String, int> played) {
  final added = entry.added * 1000, lastPlayed = played[entry.uri] ?? 0;
  return lastPlayed > added ? lastPlayed : added;
}

class _Entry {
  const _Entry({required this.uri, required this.type, this.item, this.added = 0,
    this.position = 0, this.predefined = false});
  final String uri, type;
  final LibraryItem? item;
  final int added, position;
  String? get parentUri => item?.source['nativeParentFolderUri'] as String?;
  final bool predefined;
}
