import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;

import '../protocol/generated/entity_extension_data.pb.dart';
import '../protocol/generated/extended_metadata.pb.dart';
import '../protocol/generated/extension_kind.pbenum.dart';
import '../protocol/generated/metadata.pb.dart';
import 'spotify_media_client.dart';

enum SpotifyMetadataProblem { missing, ambiguous, missingPayload, wrongPayloadType, invalidPayload }

/// Both original envelopes remain available, including provider/entity status,
/// cache information, unknown enum values, unknown fields and the raw Any bytes.
final class SpotifyMetadataMatch {
  const SpotifyMetadataMatch(this.provider, this.entity);
  final EntityExtensionDataArray provider;
  final EntityExtensionData entity;
}

final class SpotifyEntityMetadata {
  SpotifyEntityMetadata._({required this.uri, required this.extensionKind,
    required List<SpotifyMetadataMatch> matches, this.track, this.episode,
    this.problem, this.decodeError}) : matches = List.unmodifiable(matches);

  final String uri;
  final ExtensionKind extensionKind;
  final List<SpotifyMetadataMatch> matches;
  final Track? track;
  final Episode? episode;
  final SpotifyMetadataProblem? problem;
  final Object? decodeError;

  /// These numbers are preserved, not interpreted as an account admission rule.
  /// A typed payload alone does not authorize choosing or playing an audio file.
  int? get providerErrorStatus => matches.length == 1 && matches.single.provider.hasHeader()
    ? matches.single.provider.header.providerErrorStatus : null;
  int? get entityStatusCode => matches.length == 1 && matches.single.entity.hasHeader()
    ? matches.single.entity.header.statusCode : null;

  /// Only an actual decoded 16-octet GID may enter the audio-key boundary.
  /// No GID is synthesized from the requested URI or an alternate track.
  Uint8List get gid {
    final value = track?.gid ?? episode?.gid;
    if (value == null) throw StateError('No typed metadata payload is available');
    if (value.length != 16) throw const FormatException('Metadata GID must contain exactly16 octets');
    return Uint8List.fromList(value).asUnmodifiableView();
  }
}

final class SpotifyMetadataBatch {
  SpotifyMetadataBatch._(this.response, List<SpotifyEntityMetadata> entities)
    : entities = List.unmodifiable(entities);
  final BatchedExtensionResponse response;
  final List<SpotifyEntityMetadata> entities;

  factory SpotifyMetadataBatch.forTracks(Iterable<String> uris, BatchedExtensionResponse response) {
    final snapshot = response.deepCopy()..freeze();
    return SpotifyMetadataBatch._(snapshot, [for (final uri in uris)
      SpotifyMetadataRepository._project(uri, ExtensionKind.TRACK_V4, snapshot)]);
  }

  SpotifyEntityMetadata forUri(String uri) => entities.singleWhere((entity) => entity.uri == uri);
}

/// Concrete v0 Track/Episode metadata acquisition using original generated
/// schemas and the explicitly injected media client. It neither authenticates
/// nor chooses files, bypasses restrictions or infers Free/Premium entitlement.
class SpotifyMetadataRepository {
  const SpotifyMetadataRepository(this.client);
  final SpotifyMediaClient client;

  Future<SpotifyMetadataBatch> fetch(Iterable<String> uris, {BatchedEntityRequestHeader? header,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final selected = uris.toList(growable: false);
    final kinds = <String, ExtensionKind>{};
    for (final uri in selected) {
      final match = RegExp(r'^spotify:(track|episode):[A-Za-z0-9]{22}$').firstMatch(uri);
      if (match == null) throw ArgumentError.value(uri, 'uri', 'Expected a Spotify track or episode URI');
      if (kinds.containsKey(uri)) throw ArgumentError.value(uri, 'uris', 'Duplicate metadata entity');
      kinds[uri] = match.group(1) == 'track' ? ExtensionKind.TRACK_V4 : ExtensionKind.EPISODE_V4;
    }
    if (selected.isEmpty) throw ArgumentError.value(selected, 'uris', 'At least one entity is required');
    final request = BatchedEntityRequest(header: header?.deepCopy(), entityRequest: [
      for (final uri in selected) EntityRequest(entityUri: uri,
        query: [ExtensionQuery(extensionKind: kinds[uri])]),
    ]);
    final response = await client.extendedMetadata(request, cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    response.freeze();
    return SpotifyMetadataBatch._(response, [
      for (final uri in selected) _project(uri, kinds[uri]!, response),
    ]);
  }

  static SpotifyEntityMetadata _project(String uri, ExtensionKind kind, BatchedExtensionResponse response) {
    final matches = <SpotifyMetadataMatch>[
      for (final provider in response.extendedMetadata)
        // Unknown enum occurrences lose ordering relative to known ones in the
        // Dart runtime. Preserve them in the raw batch without guessing kind.
        if (provider.extensionKind == kind && !provider.unknownFields.hasField(2))
          for (final entity in provider.extensionData)
            if (entity.entityUri == uri) SpotifyMetadataMatch(provider, entity),
    ];
    if (matches.length != 1) {
      return SpotifyEntityMetadata._(uri: uri, extensionKind: kind, matches: matches,
        problem: matches.isEmpty ? SpotifyMetadataProblem.missing : SpotifyMetadataProblem.ambiguous);
    }
    final entity = matches.single.entity;
    if (!entity.hasExtensionData()) {
      return SpotifyEntityMetadata._(uri: uri, extensionKind: kind, matches: matches,
        problem: SpotifyMetadataProblem.missingPayload);
    }
    final payload = entity.extensionData;
    final name = kind == ExtensionKind.TRACK_V4 ? 'spotify.metadata.Track' : 'spotify.metadata.Episode';
    if (payload.typeUrl.isNotEmpty && payload.typeUrl.split('/').last != name) {
      return SpotifyEntityMetadata._(uri: uri, extensionKind: kind, matches: matches,
        problem: SpotifyMetadataProblem.wrongPayloadType);
    }
    try {
      if (kind == ExtensionKind.TRACK_V4) {
        final track = Track.fromBuffer(payload.value)..check();
        return SpotifyEntityMetadata._(uri: uri, extensionKind: kind, matches: matches, track: track..freeze());
      }
      final episode = Episode.fromBuffer(payload.value)..check();
      return SpotifyEntityMetadata._(uri: uri, extensionKind: kind, matches: matches, episode: episode..freeze());
    } on InvalidProtocolBufferException catch (error) {
      return SpotifyEntityMetadata._(uri: uri, extensionKind: kind, matches: matches,
        problem: SpotifyMetadataProblem.invalidPayload, decodeError: error);
    } on StateError catch (error) {
      return SpotifyEntityMetadata._(uri: uri, extensionKind: kind, matches: matches,
        problem: SpotifyMetadataProblem.invalidPayload, decodeError: error);
    }
  }
}
