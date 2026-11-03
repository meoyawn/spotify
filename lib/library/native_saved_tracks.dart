import 'package:protobuf/protobuf.dart';
import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/esperanto.dart';
import '../protocol/generated/collection_add_remove_items_request.pb.dart';
import '../protocol/generated/collection_contains_request.pb.dart';
import '../protocol/generated/collection_itemdata.pb.dart';
import '../protocol/generated/playlist_modification_request.pb.dart';
import '../protocol/generated/save_source.pb.dart';
import 'saved_tracks.dart';

/// The two optional fields accepted by the installed renderer's SaveSource.
class NativeSavedTrackSaveSource {
  const NativeSavedTrackSaveSource({this.originalUri, this.interactionId});
  final String? originalUri;
  final String? interactionId;

  SaveSource _message() => SaveSource(originalUri: originalUri, interactionId: interactionId);
}

typedef NativeSavedTrackSource = NativeSavedTrackSaveSource? Function(String uri, bool saved);

/// Original LibraryAPI track membership and mutation branches. The owner must
/// register independently verified native service implementations on the bus.
class NativeSavedTracksRepository implements SavedTracksRepository {
  NativeSavedTracksRepository(this.dispatcher, {
    required this.likedSongsListPlatformEnabled,
    required this.likedSongsUri,
    this.saveSource,
  }) {
    if (likedSongsListPlatformEnabled && likedSongsUri.isEmpty) {
      throw ArgumentError.value(likedSongsUri, 'likedSongsUri', 'List platform requires the original policy URI');
    }
  }

  static const collectionService = 'spotify.collection_esperanto.proto.CollectionService';
  static const playlistService = 'spotify.playlist_esperanto.proto.PlaylistService';
  static const likedSongsAsPlaylistUri = 'spotify:playlist:37i9dQZF1F5p3rmiWPIYgZ';

  final EsperantoDispatcher dispatcher;
  final bool likedSongsListPlatformEnabled;
  final String likedSongsUri;
  final NativeSavedTrackSource? saveSource;

  @override
  Future<Map<String, bool>> contains(List<String> uris, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final requested = List<String>.of(uris);
    for (final uri in requested) { _requireTrack(uri); }
    final request = CollectionContainsRequest(uri: requested);
    final bytes = await dispatcher.callSingle(EsperantoCall(collectionService, 'Contains', request.writeToBuffer()),
      cancellationToken: cancellationToken);
    final found = CollectionContainsResponse.fromBuffer(bytes).found;
    return Map.unmodifiable({for (var index = 0; index < requested.length; index++)
      requested[index]: index < found.length ? found[index] : false});
  }

  @override
  Future<void> setSaved(String uri, bool saved, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _requireTrack(uri);
    final source = saveSource?.call(uri, saved)?._message();
    if (likedSongsListPlatformEnabled) {
      final bytes = await dispatcher.callSingle(EsperantoCall(playlistService, 'Modify',
        _playlistModification(uri, saved, source)), cancellationToken: cancellationToken);
      final response = PlaylistModificationResponse.fromBuffer(bytes);
      // The concrete native failure callback returns an explicit non2xx
      // status. Keep the last acknowledged UI value on that error reply.
      if (response.hasStatus() && (response.status.statusCode < 200 || response.status.statusCode >= 300)) {
        throw StateError('Spotify could not update Liked Songs: ${response.status.reason}');
      }
    } else {
      final request = source == null
          ? CollectionAddRemoveItemsRequest(uri: [uri])
          : CollectionAddRemoveItemsRequest(items: [CollectionAddRemoveItem(uri: uri,
              itemData: ItemData(saveSource: source))]);
      final bytes = await dispatcher.callSingle(EsperantoCall(collectionService,
        saved ? 'Add' : 'Remove', request.writeToBuffer()), cancellationToken: cancellationToken);
      final response = CollectionAddRemoveItemsResponse.fromBuffer(bytes);
      if (response.hasStatus() && (response.status.code < 200 || response.status.code >= 300)) {
        throw StateError('Spotify could not update Liked Songs: ${response.status.reason}');
      }
    }
  }

  List<int> _playlistModification(String uri, bool saved, SaveSource? source) {
    final modification = CodedBufferWriter()
      ..writeField(1, PbFieldType.OS, saved ? 'add' : 'remove')
      ..writeField(7, PbFieldType.PS, [uri])
      // Original module7967 explicitly writes this empty packed enum field.
      ..writeField(11, PbFieldType.OY, <int>[]);
    if (source != null) modification.writeField(13, PbFieldType.OY, source.writeToBuffer());
    return (CodedBufferWriter()
      ..writeField(1, PbFieldType.OS, likedSongsUri)
      ..writeField(2, PbFieldType.OY, modification.toBuffer())).toBuffer();
  }

  static void _requireTrack(String uri) {
    if (!RegExp(r'^spotify:track:[A-Za-z0-9]{22}$').hasMatch(uri)) {
      throw ArgumentError.value(uri, 'uri', 'Saved-track protocol supports canonical Spotify track URIs');
    }
  }
}
