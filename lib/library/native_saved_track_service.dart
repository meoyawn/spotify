import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cancellation_token/cancellation_token.dart';

import '../playlist_service/native_read_client.dart';
import '../playlist_service/sync_plan.dart';
import '../playlist_service/sync_path.dart';
import '../playlist_service/sync_reply.dart';
import '../playlist_service/native_write_plan.dart';
import '../protocol/esperanto.dart';
import '../protocol/generated/collection_contains_request.pb.dart';
import '../protocol/generated/playlist_api.pb.dart' as playlist;
import '../protocol/generated/playlist_modification_request.pb.dart';
import '../protocol/generated/playlist_sync_reason.pb.dart';
import '../protocol/generated/response_status.pb.dart';
import '../protocol/generated/status.pb.dart';
import '../protocol/request_builder.dart';
import 'native_collection_read_client.dart';
import 'native_saved_tracks.dart';

/// Dart ownership of the two native services used by the installed LibraryAPI.
/// The injected session sender remains the only network boundary. No mutation
/// starts until an explicit Modify call reaches this service.
class NativeSavedTrackService {
  NativeSavedTrackService({required this.baseUrl, required this.username,
    required this.headers, required this.membership, required this.readPlaylist,
    required this.send, required this.requestedLenses,
    required this.dsaMode, required this.listPlayerEnabled});
  final String baseUrl, username;
  final Map<String, String> headers;
  final NativeCollectionReadClient membership;
  final Future<playlist.SelectedListContent> Function(String uri, {CancellationToken? cancellationToken}) readPlaylist;
  final NativePlaylistHttpSend send;
  final List<String> requestedLenses;
  final bool dsaMode, listPlayerEnabled;
  playlist.SelectedListContent? _snapshot;
  Future<void> _writes = Future.value();
  int _nonce = 0;
  bool? _derivedIdsMatchServer;

  void register(EsperantoDispatcher dispatcher) {
    dispatcher.register(NativeSavedTracksRepository.collectionService, EsperantoService(cancellableSingle: {
      'Contains': (bytes, token) async {
        final request = CollectionContainsRequest.fromBuffer(bytes);
        final uris = request.uri.toList(growable: false);
        final found = await membership.contains(uris, cancellationToken: token);
        return CollectionContainsResponse(status: Status(code: 200),
          found: [for (final uri in uris) found[uri] == true]).writeToBuffer();
      },
    }));
    dispatcher.register(NativeSavedTracksRepository.playlistService, EsperantoService(cancellableSingle: {
      'Modify': (bytes, token) async {
        final request = PlaylistModificationRequest.fromBuffer(bytes);
        final change = request.request;
        if (request.uri != NativeSavedTracksRepository.likedSongsAsPlaylistUri ||
            change.uris.length != 1 || !const {'add', 'remove'}.contains(change.operation) ||
            change.hasSaveSource() || change.rows.isNotEmpty || change.attributesToClear.isNotEmpty) {
          throw UnsupportedError('This native save service accepts a single Liked Songs track mutation');
        }
        final result = Completer<void>();
        _writes = _writes.catchError((Object _) {}).then((_) async {
          try { token.throwIfCancelled(); await _change(change.uris.single, change.operation == 'add', token); result.complete(); }
          catch (error, stack) { result.completeError(error, stack); }
        });
        await result.future.asCancellable(token);
        return PlaylistModificationResponse(status: ResponseStatus(statusCode: 200)).writeToBuffer();
      },
    }));
  }

  Future<void> _change(String uri, bool saved, CancellationToken token) async {
    token.throwIfCancelled();
    final listUri = NativeSavedTracksRepository.likedSongsAsPlaylistUri;
    final snapshot = _snapshot ??= await readPlaylist(listUri, cancellationToken: token);
    if (!snapshot.hasRevision() || snapshot.revision.isEmpty || !snapshot.hasLength() ||
        snapshot.contents.pos != 0 || snapshot.capabilities.hasCanEditItems() && !snapshot.capabilities.canEditItems) {
      throw StateError('Spotify did not supply an editable Liked Songs revision');
    }
    final before = (await membership.contains([uri], cancellationToken: token))[uri]!;
    if (before == saved) return;
    final clock = DateTime.now().microsecondsSinceEpoch;
    final NativePlaylistChangesBody body;
    playlist.ItemAttributes? inserted;
    final index = snapshot.contents.items.indexWhere((item) => item.uri == uri);
    if (saved) {
      inserted = NativePlaylistChangesBody.freshRowAttributes(username: username,
        clockMicroseconds: clock, uri: uri, itemIdAlgorithm: snapshot.attributes.itemIdAlgorithm);
      body = NativePlaylistChangesBody.add(currentRevision: snapshot.revision,
        priorNonce: _nonce, username: username, clockMicroseconds: clock,
        uri: uri, previousLength: snapshot.length, rowAttributes: inserted);
    } else {
      List<int> itemId;
      if (index < 0) {
        // The declared deterministic algorithm permits keyed operations on
        // older rows beyond a partial snapshot. Independently check it against
        // every returned track ID before relying on that global list policy.
        if (snapshot.attributes.itemIdAlgorithm != playlist.ItemIdAlgorithm.ALGORITHM_TRUNCATED_SHA1) {
          throw UnsupportedError('Spotify did not provide this saved track’s row identity');
        }
        _derivedIdsMatchServer ??= await _verifyDerivedServerIds([
          for (final item in snapshot.contents.items)
            if (RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(item.uri))
              (item.uri, item.attributes.itemId.toList(growable: false)),
        ], token);
        if (!_derivedIdsMatchServer!) throw StateError('Spotify’s saved row identities do not match its declared algorithm');
        itemId = NativePlaylistChangesBody.freshRowAttributes(username: username,
          clockMicroseconds: clock, uri: uri, itemIdAlgorithm: snapshot.attributes.itemIdAlgorithm).itemId;
      } else {
        itemId = snapshot.contents.items[index].attributes.itemId;
      }
      body = NativePlaylistChangesBody.remove(currentRevision: snapshot.revision,
        priorNonce: _nonce, username: username, clockMicroseconds: clock,
        uri: uri, index: index < 0 ? 0 : index, itemId: itemId);
    }
    final plan = buildPlaylistSyncPlan(canonicalUri: listUri, mode: PlaylistSyncMode.changes,
      caller: PlaylistSyncCaller.ESPERANTO, prioritized: true, dsaMode: dsaMode,
      listPlayerEnabled: listPlayerEnabled, requestedLenses: requestedLenses);
    token.throwIfCancelled();
    final response = await send(RequestEnvelope(method: plan.method,
      url: '$baseUrl/${plan.path}', headers: {...headers,
        for (final header in plan.headers) header.key: header.value},
      body: body.body, responseType: 'bytes', cancellationToken: token));
    PlaylistSyncReply? reply;
    final processor = PlaylistSyncReplyProcessor(onReply: (value) => reply = value);
    try {
      processor.receiveResponse(statusCode: response.statusCode, headers: response.headers, body: response.bodyBytes);
    } finally { processor.close(); }
    final acknowledged = reply;
    if (acknowledged == null || acknowledged.error.value != 0 || response.statusCode != 200) {
      _snapshot = null; _derivedIdsMatchServer = null;
      throw StateError('Spotify did not accept the Liked Songs change (HTTP ${response.statusCode})');
    }
    _nonce = body.nextNonce;
    final returned = acknowledged.content;
    final revision = returned.hasRevision() ? returned.revision : returned.resultingRevisions.lastOrNull;
    if (revision == null || revision.isEmpty) {
      _snapshot = null; _derivedIdsMatchServer = null;
    } else {
      final updated = snapshot.deepCopy()..revision = revision;
      updated.length += saved ? 1 : -1;
      if (saved) {
        updated.contents.items.insert(0, playlist.Item(uri: uri, attributes: inserted));
      } else if (index >= 0) {
        updated.contents.items.removeAt(index);
      }
      _snapshot = updated;
    }
    await membership.recordAcknowledgedChange(uri, saved);
  }
}

Future<bool> _verifyDerivedServerIds(List<(String, List<int>)> rows, CancellationToken token) =>
  CancellableIsolate.run(() => rows.isNotEmpty && rows.every((row) {
    final digest = crypto.sha1.convert(utf8.encode(row.$1)).bytes;
    return row.$2.length == 10 && row.$2.indexed.every((entry) => entry.$2 == digest[entry.$1]);
  }), token);
