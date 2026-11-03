import '../protocol/generated/extended_metadata.pb.dart' as metadata;
import '../protocol/generated/extension_kind.pbenum.dart';
import '../protocol/native_http_defaults.dart';
import '../protocol/request_builder.dart';
import 'spotify_requests.dart';

/// One ready ordinary Track source, with an empty matching metadata cache and
/// no cached video associations.
///
/// Original 0x1008446e8 produces the queries; 0x100601d64 iterates their sorted
/// kind collection; 0x1005f3e90 groups them into one entity and retains the
/// header submessage even for empty country/catalogue. 0x10061230c adds the
/// prefetch operation header. Inputs below belong to the native owner/context;
/// no Free/Premium defaults, account admission or cache decisions are inferred.
///
/// This bounded plan excludes multiple entities, native dedup/window scheduling,
/// cache hits/etags, associated-video Track queries and the five-entity gzip
/// branch. It creates no network I/O.
final class NativeAudioFilesRequestPlan {
  NativeAudioFilesRequestPlan._(this.metadataRequest);

  factory NativeAudioFilesRequestPlan.forReadyTrackCacheMiss({
    required String uri,
    required String country,
    required String catalogue,
    required bool nativeOwnerFlag51,
    required bool nativeOwnerFlag52,
    required bool nativeOwnerFlag53,
  }) {
    if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)) {
      throw ArgumentError.value(uri, 'uri', 'A resolved ordinary Track URI is required');
    }
    final kinds = <int>[
      5,
      if (nativeOwnerFlag52) 99,
      if (nativeOwnerFlag51) ...[178, 179, 182, 212, 220, 239, 249],
      if (nativeOwnerFlag53) 275,
    ];
    final request = metadata.BatchedEntityRequest(
      header: metadata.BatchedEntityRequestHeader(country: country, catalogue: catalogue),
      entityRequest: [metadata.EntityRequest(entityUri: uri, query: [
        for (final kind in kinds)
          metadata.ExtensionQuery(extensionKind: ExtensionKind.valueOf(kind)!),
      ])],
    )..freeze();
    return NativeAudioFilesRequestPlan._(request);
  }

  static const operation = 'prefetch';
  static const rawSubmissionMode = 1;
  final metadata.BatchedEntityRequest metadataRequest;

  /// Reuse the independently recovered v0 template/default policy and preserve
  /// the native setter's case-insensitive header replacement behavior.
  RequestEnvelope envelope(SpotifyRequests requests) {
    final base = requests.extendedMetadata(metadataRequest);
    return RequestEnvelope(method: base.method, url: base.url,
      headers: nativeHeaderOverrides(base.headers, const {'client-feature-id': operation}),
      body: base.body, authorize: base.authorize, includeCredentials: base.includeCredentials,
      responseType: base.responseType, nativeTimeoutMilliseconds: base.nativeTimeoutMilliseconds,
      cancellationToken: base.cancellationToken);
  }
}
