import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import '../playback/native_spotify_gid.dart';
import '../playback/spotify_requests.dart';
import '../protocol/generated/extended_metadata.pb.dart' as metadata;
import '../protocol/generated/extension_kind.pbenum.dart';
import '../protocol/generated/metadata.pb.dart' as v4;
import '../protocol/native_http_defaults.dart';
import '../protocol/native_gzip.dart';
import '../protocol/native_image_request.dart';
import '../protocol/native_metadata_cache.dart';
import '../protocol/request_builder.dart';
import 'models.dart';
import 'native_collection_read_client.dart';

/// Original base-metadata producer 101cd5f0c, HTTP owner10061230c. The native
/// your_library caller is independently captured. No account rights or optional
/// decoration traits are inferred from a successful base-metadata response.
class NativeLibraryMetadataPlan {
  NativeLibraryMetadataPlan({required Iterable<String> uris,
    required String country, required String catalogue}) {
    final selected = uris.toList(growable: false), unique = <String>{};
    if (selected.isEmpty || selected.length > 50) throw RangeError('A native metadata batch requires 1..50 entities');
    for (final uri in selected) {
      _kind(uri);
      if (!unique.add(uri)) throw ArgumentError.value(uri, 'uris', 'Duplicate Library metadata identity');
    }
    // Original100601d64 iterates the query collection by extension kind. Each
    // kind retains source order; a mixed batch is not input-URI order.
    final ordered = [for (final kind in [ExtensionKind.ARTIST_V4, ExtensionKind.ALBUM_V4])
      ...selected.where((uri) => _kind(uri) == kind)];
    request = metadata.BatchedEntityRequest(
      header: metadata.BatchedEntityRequestHeader(country: country, catalogue: catalogue),
      entityRequest: [for (final uri in ordered) metadata.EntityRequest(entityUri: uri,
        query: [metadata.ExtensionQuery(extensionKind: _kind(uri))])],
    )..freeze();
  }

  late final metadata.BatchedEntityRequest request;

  RequestEnvelope envelope(SpotifyRequests requests) {
    final base = requests.extendedMetadata(request), compressed = request.entityRequest.length >= 5;
    return RequestEnvelope(method: base.method, url: base.url,
      headers: nativeHeaderOverrides(base.headers, {'client-feature-id': 'your_library',
        if (compressed) 'Content-Encoding': 'gzip'}),
      body: compressed ? NativeGzip.encode(base.body) : base.body,
      authorize: base.authorize, includeCredentials: base.includeCredentials,
      responseType: base.responseType, nativeTimeoutMilliseconds: base.nativeTimeoutMilliseconds,
      cancellationToken: base.cancellationToken);
  }
}

ExtensionKind _kind(String uri) {
  final match = RegExp(r'^spotify:(album|artist):[A-Za-z0-9]{22}$').firstMatch(uri);
  if (match == null) throw ArgumentError.value(uri, 'uri', 'Expected an album or artist URI');
  return match[1] == 'album' ? ExtensionKind.ALBUM_V4 : ExtensionKind.ARTIST_V4;
}

class NativeLibraryMetadataClient {
  NativeLibraryMetadataClient({required this.requests, required this.country,
    required this.catalogue, required this.imageUrlTemplate, required this.send,
    required this.nowMicroseconds});
  final SpotifyRequests requests;
  final String country, catalogue, imageUrlTemplate;
  final NativeCollectionHttpSend send;
  final int Function() nowMicroseconds;
  final _cache = <String, (LibraryItem, int)>{};
  final _pending = <String, SharedTask<Map<String, LibraryItem>>>{};

  LibraryItem? cached(String uri) {
    final item = _cache.remove(uri);
    if (item == null || item.$2 < nowMicroseconds()) return null;
    _cache[uri] = item;
    return item.$1;
  }

  Future<Map<String, LibraryItem>> describe(Iterable<String> uris, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final selected = uris.toSet().toList(growable: false);
    final result = <String, LibraryItem>{};
    for (var index = 0; index < selected.length; index += 50) {
      cancellationToken?.throwIfCancelled();
      final waiting = <String, SharedTask<Map<String, LibraryItem>>>{}, missing = <String>[];
      for (final uri in selected.skip(index).take(50)) {
        final existing = cached(uri);
        if (existing != null) {
          result[uri] = existing;
        } else {
          final pending = _pending[uri];
          if (pending == null || pending.token.isCancelled) { missing.add(uri); } else { waiting[uri] = pending; }
        }
      }
      if (missing.isNotEmpty) {
        final job = SharedTask((token) => _fetch(missing, token));
        for (final uri in missing) {
          _pending[uri] = job;
          waiting[uri] = job;
        }
      }
      try {
        final values = await Future.wait(waiting.entries.map((entry) async =>
          (entry.key, (await entry.value.wait(cancellationToken))[entry.key]!)));
        cancellationToken?.throwIfCancelled();
        for (final (uri, item) in values) { result[uri] = item; }
      } finally {
        for (final entry in waiting.entries) {
          if ((entry.value.isComplete || entry.value.token.isCancelled) && identical(_pending[entry.key], entry.value)) {
            _pending.remove(entry.key);
          }
        }
      }
    }
    return result;
  }

  Future<Map<String, LibraryItem>> _fetch(List<String> uris, CancellationToken token) async {
    token.throwIfCancelled();
    final response = await send(NativeLibraryMetadataPlan(uris: uris, country: country,
      catalogue: catalogue).envelope(requests).withCancellation(token));
    token.throwIfCancelled();
    if (response.statusCode != 200) throw StateError('Library metadata returned HTTP ${response.statusCode}');
    final body = metadata.BatchedExtensionResponse.fromBuffer(response.bodyBytes)..freeze();
    final result = <String, LibraryItem>{};
    for (final uri in uris) {
      final kind = _kind(uri);
      final matches = [for (final provider in body.extendedMetadata)
        if (provider.extensionKind == kind && !provider.unknownFields.hasField(2) &&
            provider.hasHeader() && provider.header.providerErrorStatus == 200)
          for (final entity in provider.extensionData)
            if (entity.entityUri == uri) (provider: provider, entity: entity)];
      if (matches.length != 1 || !matches.single.entity.hasHeader() ||
          matches.single.entity.header.statusCode != 200 || !matches.single.entity.hasExtensionData()) {
        result[uri] = LibraryItem.unsupported(source: {'uri': uri});
        continue;
      }
      final entity = matches.single.entity, payload = entity.extensionData;
      final provenance = <String, Object?>{'uri': uri, 'extensionKind': kind.value,
        'statusCode': entity.header.statusCode, 'cacheTtlInSeconds': entity.header.cacheTtlInSeconds.toInt()};
      final type = kind == ExtensionKind.ALBUM_V4 ? 'Album' : 'Artist';
      if (payload.typeUrl.isNotEmpty && payload.typeUrl.split('/').last != 'spotify.metadata.$type') {
        throw const FormatException('Unexpected native Library metadata payload');
      }
      final LibraryItem item;
      if (kind == ExtensionKind.ALBUM_V4) {
        final album = v4.Album.fromBuffer(payload.value)..check();
        item = LibraryItem.fromJson({'type': 'album', 'uri': uri, 'name': album.name,
          'albumType': const {1: 'album', 2: 'single', 3: 'compilation', 4: 'ep'}[album.type.value] ?? 'album',
          'artists': [for (final artist in album.artist) <String, Object?>{'name': artist.name,
            if (artist.gid.length == 16) 'uri': nativeSpotifyEntityUri('artist', artist.gid)}],
          'images': _images(album.coverGroup.image.isNotEmpty ? album.coverGroup.image : album.cover),
          'releaseSortValue': album.date.year * 10000 + album.date.month * 100 + album.date.day,
        }, source: provenance);
      } else {
        final artist = v4.Artist.fromBuffer(payload.value)..check();
        item = LibraryItem.fromJson({'type': 'artist', 'uri': uri, 'name': artist.name,
          'images': _images(artist.portraitGroup.image.isNotEmpty ? artist.portraitGroup.image : artist.portrait),
        }, source: provenance);
      }
      result[uri] = item;
      final expiry = nativeMetadataExpiryMicroseconds(
        providerTtlSeconds: matches.single.provider.header.cacheTtlInSeconds.toInt(),
        entityTtlSeconds: entity.header.cacheTtlInSeconds.toInt(), nowMicroseconds: nowMicroseconds());
      if (expiry != null) {
        _cache.remove(uri);
        _cache[uri] = (item, expiry);
        // Keep lightweight names/artwork, without retaining large Artist/Album
        // protobuf payloads. Sorting/filtering can reuse a bounded catalog.
        while (_cache.length > 4096) { _cache.remove(_cache.keys.first); }
      }
    }
    return result;
  }

  List<LibraryJson> _images(List<v4.Image> images) => [for (final image in images)
    if (image.fileId.length == 20) <String, Object?>{
      'url': nativeImageUrlForId(image.fileId, template: imageUrlTemplate),
      if (image.hasWidth()) 'width': image.width,
      if (image.hasHeight()) 'height': image.height,
    }];
}
