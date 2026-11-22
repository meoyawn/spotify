import 'package:protobuf/protobuf.dart' show CodedBufferReader;

import '../playback/spotify_requests.dart';
import '../protocol/generated/extended_metadata.pb.dart' as metadata;
import '../protocol/generated/extension_kind.pbenum.dart';
import '../protocol/native_gzip.dart';
import '../protocol/native_http_defaults.dart';
import '../protocol/request_builder.dart';

/// Original artist popular-row PlayCount column (module27246): trait table
/// ON_PLATFORM_REPUTATION_TRAIT, rendered by34411 only when totalPlays >= 1.
/// Trait tables subscribe through the native metadata-extensions API with
/// featureId "grizzly"; captured original requests carry
/// `client-feature-id: grizzly` on the ordinary extended-metadata POST
/// (reverse-engineering/evidence/native-artist-play-counts.json).
///
/// Scope: the original batcher may coalesce other trait kinds for the same
/// rows. Row identity, artwork and duration already come from TrackV4, so this
/// plan queries only kind 185. No account permission is inferred.
final class NativeArtistPlayCountPlan {
  NativeArtistPlayCountPlan({required Iterable<String> uris,
      required String country, required String catalogue}) {
    final selected = uris.toList(growable: false), unique = <String>{};
    if (selected.isEmpty || selected.length > 50) {
      throw RangeError('A native trait batch requires 1..50 Track identities');
    }
    for (final uri in selected) {
      if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri) || !unique.add(uri)) {
        throw ArgumentError.value(uri, 'uris', 'Unique canonical Track URIs are required');
      }
    }
    request = metadata.BatchedEntityRequest(
      header: metadata.BatchedEntityRequestHeader(country: country, catalogue: catalogue),
      entityRequest: [for (final uri in selected) metadata.EntityRequest(entityUri: uri,
        query: [metadata.ExtensionQuery(extensionKind: ExtensionKind.ON_PLATFORM_REPUTATION_TRAIT)])],
    )..freeze();
  }

  static const featureId = 'grizzly';
  late final metadata.BatchedEntityRequest request;

  RequestEnvelope envelope(SpotifyRequests requests) {
    final base = requests.extendedMetadata(request), compressed = request.entityRequest.length >= 5;
    return RequestEnvelope(method: base.method, url: base.url,
      headers: nativeHeaderOverrides(base.headers, {'client-feature-id': featureId,
        if (compressed) 'Content-Encoding': 'gzip'}),
      body: compressed ? NativeGzip.encode(base.body) : base.body,
      authorize: base.authorize, includeCredentials: base.includeCredentials,
      responseType: base.responseType, nativeTimeoutMilliseconds: base.nativeTimeoutMilliseconds,
      cancellationToken: base.cancellationToken);
  }

  /// Successful per-entity traits only. A provider/entity error, missing
  /// payload or absent totalPlays leaves the row without a count.
  static Map<String, int> decode(List<int> body, Iterable<String> uris) {
    final response = metadata.BatchedExtensionResponse.fromBuffer(body)..freeze();
    final wanted = uris.toSet(), result = <String, int>{};
    for (final provider in response.extendedMetadata) {
      if (provider.extensionKind != ExtensionKind.ON_PLATFORM_REPUTATION_TRAIT ||
          !provider.hasHeader() || provider.header.providerErrorStatus != 200) { continue; }
      for (final entity in provider.extensionData) {
        if (!wanted.contains(entity.entityUri) || !entity.hasHeader() ||
            entity.header.statusCode != 200 || !entity.hasExtensionData()) { continue; }
        final plays = _totalPlays(entity.extensionData.value);
        if (plays != null) result[entity.entityUri] = plays;
      }
    }
    return result;
  }
}

/// Original OnPlatformReputationTrait decoder: totalPlays is field 3, int64.
int? _totalPlays(List<int> bytes) {
  final reader = CodedBufferReader(bytes);
  int? plays;
  while (!reader.isAtEnd()) {
    final tag = reader.readTag();
    if (tag == 0) break;
    if (tag == 24) {
      plays = reader.readInt64().toInt();
    } else if (tag & 7 == 4) {
      break;
    } else {
      reader.skipField(tag);
    }
  }
  return plays;
}
