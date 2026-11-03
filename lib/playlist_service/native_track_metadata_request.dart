import 'dart:io' show gzip;

import '../playback/spotify_requests.dart';
import '../protocol/generated/extended_metadata.pb.dart' as metadata;
import '../protocol/generated/extension_kind.pbenum.dart';
import '../protocol/native_http_defaults.dart';
import '../protocol/request_builder.dart';

/// Fresh ordinary Track metadata from native playlist_tracks_loader. Optional
/// playlist-loader sidecar maps are empty and the separate TrackV4 association
/// configuration is explicitly false. No cache, account or playback permission
/// is inferred. This plan performs no I/O.
final class NativePlaylistTrackMetadataPlan {
  NativePlaylistTrackMetadataPlan._(this.metadataRequest);

  factory NativePlaylistTrackMetadataPlan.forFreshTracks({
    required Iterable<String> uris,
    required String country,
    required String catalogue,
    required bool fetchAssociationsWithTrackV4Enabled,
  }) {
    if (fetchAssociationsWithTrackV4Enabled) {
      throw UnsupportedError('The captured base-track plan requires the native association flag to be false');
    }
    final selected = uris.toList(growable: false);
    if (selected.isEmpty || selected.length > 50) {
      throw RangeError('One native batch requires between 1 and 50 Track identities');
    }
    final unique = <String>{};
    for (final uri in selected) {
      if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri) || !unique.add(uri)) {
        throw ArgumentError.value(uri, 'uris', 'Unique canonical ordinary Track URIs are required');
      }
    }
    final request = metadata.BatchedEntityRequest(
      header: metadata.BatchedEntityRequestHeader(country: country, catalogue: catalogue),
      entityRequest: [for (final uri in selected)
        metadata.EntityRequest(entityUri: uri, query: [
          metadata.ExtensionQuery(extensionKind: ExtensionKind.TRACK_V4),
        ])],
    )..freeze();
    return NativePlaylistTrackMetadataPlan._(request);
  }

  static const operation = 'playlist_tracks_loader';
  final metadata.BatchedEntityRequest metadataRequest;

  RequestEnvelope envelope(SpotifyRequests requests) {
    final base = requests.extendedMetadata(metadataRequest);
    final compressed = metadataRequest.entityRequest.length >= 5;
    return RequestEnvelope(method: base.method, url: base.url,
      headers: nativeHeaderOverrides(base.headers, {
        'client-feature-id': operation,
        if (compressed) 'Content-Encoding': 'gzip',
      }),
      body: compressed ? gzip.encode(base.body) : base.body,
      authorize: base.authorize, includeCredentials: base.includeCredentials,
      responseType: base.responseType,
      nativeTimeoutMilliseconds: base.nativeTimeoutMilliseconds, cancellationToken: base.cancellationToken);
  }
}
