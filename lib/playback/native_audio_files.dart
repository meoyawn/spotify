import 'package:protobuf/protobuf.dart' show InvalidProtocolBufferException;
import 'dart:typed_data';

import '../protocol/generated/audio_files_extension.pb.dart';
import '../protocol/generated/entity_extension_data.pb.dart';
import '../protocol/generated/extended_metadata.pb.dart';
import '../protocol/generated/extension_kind.pbenum.dart';

enum NativeAudioFilesProblem { missing, ambiguous, missingPayload, wrongPayloadType, invalidPayload }

/// The original provider/entity pair, including status, locale, cache headers,
/// unknown fields and the untouched Any payload.
final class NativeAudioFilesMatch {
  const NativeAudioFilesMatch(this.provider, this.entity);
  final EntityExtensionDataArray provider;
  final EntityExtensionData entity;
}

/// The normal native file-list source is AUDIO_FILES (5), not Track.file or
/// Episode.audio. Original 0x101c198dc consumes this extension and unpacks an
/// AudioFilesExtensionResponse; source variant 0 at 0x101296c50 exposes it to
/// the existing bitrate ranker. Variant 1 embeds the same message at +0x18.
///
/// This is a decoding projection, not the upstream account/status admission
/// policy. No file is selected or authorized here. Keep the complete response
/// so that the original response branch can be applied without losing server
/// restrictions, unknown formats or another extension's playback traits.
final class NativeAudioFilesMetadata {
  NativeAudioFilesMetadata._({required this.uri, required this.response,
    required List<NativeAudioFilesMatch> matches, this.payload, this.problem,
    this.decodeError}) : matches = List.unmodifiable(matches);

  factory NativeAudioFilesMetadata.fromResponse(String uri, BatchedExtensionResponse response) {
    final snapshot = response.deepCopy()..freeze();
    final matches = <NativeAudioFilesMatch>[
      for (final provider in snapshot.extendedMetadata)
        if (provider.extensionKind == ExtensionKind.AUDIO_FILES &&
            !provider.unknownFields.hasField(2))
          for (final entity in provider.extensionData)
            if (entity.entityUri == uri) NativeAudioFilesMatch(provider, entity),
    ];
    if (matches.length != 1) {
      return NativeAudioFilesMetadata._(uri: uri, response: snapshot, matches: matches,
        problem: matches.isEmpty ? NativeAudioFilesProblem.missing : NativeAudioFilesProblem.ambiguous);
    }
    final entity = matches.single.entity;
    if (!entity.hasExtensionData()) {
      return NativeAudioFilesMetadata._(uri: uri, response: snapshot, matches: matches,
        problem: NativeAudioFilesProblem.missingPayload);
    }
    final any = entity.extensionData;
    final slash = any.typeUrl.lastIndexOf('/');
    // Standard protobuf Any::UnpackTo requires a slash and an exact type name.
    if (slash < 0 || any.typeUrl.substring(slash + 1) != payloadType) {
      return NativeAudioFilesMetadata._(uri: uri, response: snapshot, matches: matches,
        problem: NativeAudioFilesProblem.wrongPayloadType);
    }
    try {
      final payload = AudioFilesExtensionResponse.fromBuffer(any.value)..check();
      return NativeAudioFilesMetadata._(uri: uri, response: snapshot, matches: matches,
        payload: payload..freeze());
    } on InvalidProtocolBufferException catch (error) {
      return NativeAudioFilesMetadata._(uri: uri, response: snapshot, matches: matches,
        problem: NativeAudioFilesProblem.invalidPayload, decodeError: error);
    } on StateError catch (error) {
      return NativeAudioFilesMetadata._(uri: uri, response: snapshot, matches: matches,
        problem: NativeAudioFilesProblem.invalidPayload, decodeError: error);
    }
  }

  static const payloadType = 'spotify.extendedmetadata.audiofiles.AudioFilesExtensionResponse';
  final String uri;
  final BatchedExtensionResponse response;
  final List<NativeAudioFilesMatch> matches;
  final AudioFilesExtensionResponse? payload;
  final NativeAudioFilesProblem? problem;
  final Object? decodeError;

  /// Actual streaming-source virtual+0x28 at10129a720 delegates to original
  ///101d0715c: field4 must have exactly16 bytes and is returned unchanged.
  /// It is a distinct source identity and can differ from the requested URI.
  Uint8List get audioIdentity {
    final bytes = payload?.audioId;
    if (bytes == null || bytes.length != 16) throw const FormatException('Spotify audio identity must have16 bytes');
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  /// Preserve the actual values without inventing a Free/Premium rule.
  int? get providerErrorStatus => matches.length == 1 && matches.single.provider.hasHeader()
    ? matches.single.provider.header.providerErrorStatus : null;
  int? get entityStatusCode => matches.length == 1 && matches.single.entity.hasHeader()
    ? matches.single.entity.header.statusCode : null;
}
