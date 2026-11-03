import '../protocol/generated/extension_kind.pbenum.dart';
import '../protocol/generated/metadata.pb.dart';
import 'native_spotify_gid.dart';
import 'native_track_restriction.dart';
import 'spotify_metadata.dart';
import 'package:cancellation_token/cancellation_token.dart';
typedef NativeTrackMetadataLookup = Future<SpotifyEntityMetadata> Function(String uri,
  {CancellationToken? cancellationToken});

final class NativeTrackRelinkResult {
  const NativeTrackRelinkResult._({required this.originalUri,
    required this.originalMetadata, required this.originalDecision,
    this.selectedUri, this.selectedMetadata, this.selectedDecision});

  final String originalUri;
  final SpotifyEntityMetadata originalMetadata;
  final NativeTrackRestrictionDecision originalDecision;

  /// Absent when neither the original nor a direct alternative passes the
  /// recovered restriction leaf. Other playback/source guards remain required.
  final String? selectedUri;
  final SpotifyEntityMetadata? selectedMetadata;
  final NativeTrackRestrictionDecision? selectedDecision;

  bool get wasRelinked => selectedUri != null && selectedUri != originalUri;
}

/// Bounded ordinary Track path: 0x101ce1d18 enters the ordered alternative
/// iterator only for a nonzero current status. Callback 0x101ce26d8 admits only
/// status0; concrete setter 0x101ce452c replaces the previous link each time.
/// Original captures are in reverse-engineering/evidence/native-track-restrictions.json.
///
/// The injected lookup owns verified metadata requests/cache and their status
/// handling. This class performs no I/O itself, reads no canonical_uri and has
/// no license/HTTP-error fallback. Native readiness/source/streaming guards and
/// nonempty Availability projection remain outside this bounded policy.
final class NativeTrackRelinker {
  const NativeTrackRelinker({required this.country, required this.catalogue,
    required this.lookup});

  final String country;
  final String catalogue;
  final NativeTrackMetadataLookup lookup;

  Future<NativeTrackRelinkResult> resolve(String originalUri, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    nativeSpotifyTrackGid(originalUri);
    final original = await lookup(originalUri, cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    final originalTrack = _successfulTrack(originalUri, original);
    if (originalTrack == null) {
      throw StateError('Track relinking requires successful typed TrackV4 metadata for $originalUri');
    }
    final originalDecision = _decision(originalTrack);
    if (originalDecision.status == 0) {
      return NativeTrackRelinkResult._(originalUri: originalUri,
        originalMetadata: original, originalDecision: originalDecision,
        selectedUri: nativeSpotifyTrackUri(originalTrack.gid),
        selectedMetadata: original, selectedDecision: originalDecision);
    }

    String? selectedUri;
    SpotifyEntityMetadata? selectedMetadata;
    NativeTrackRestrictionDecision? selectedDecision;
    // Traverse only this original response's direct alternatives, preserving
    // source order. A nested GID is an explicit lookup input, not an admitted
    // Track response. The metadata provider may satisfy it from its own cache.
    for (final alternative in originalTrack.alternative) {
      if (!alternative.hasGid() || alternative.gid.length != 16) continue;
      final candidateUri = nativeSpotifyTrackUri(alternative.gid);
      cancellationToken?.throwIfCancelled();
      final candidate = candidateUri == originalUri ? original
        : await lookup(candidateUri, cancellationToken: cancellationToken);
      cancellationToken?.throwIfCancelled();
      final candidateTrack = _successfulTrack(candidateUri, candidate);
      if (candidateTrack == null) continue;
      final decision = _decision(candidateTrack);
      if (decision.status != 0) continue;
      selectedUri = nativeSpotifyTrackUri(candidateTrack.gid);
      selectedMetadata = candidate;
      selectedDecision = decision;
    }
    return NativeTrackRelinkResult._(originalUri: originalUri,
      originalMetadata: original, originalDecision: originalDecision,
      selectedUri: selectedUri, selectedMetadata: selectedMetadata,
      selectedDecision: selectedDecision);
  }

  NativeTrackRestrictionDecision _decision(Track track) =>
    NativeTrackRestrictionPolicy.forTrackWithNoAvailability(track,
      country: country, catalogue: catalogue);

  static Track? _successfulTrack(String requestedUri, SpotifyEntityMetadata metadata) {
    final track = metadata.track;
    if (metadata.uri != requestedUri || metadata.extensionKind != ExtensionKind.TRACK_V4 ||
        metadata.problem != null || metadata.matches.length != 1 ||
        metadata.providerErrorStatus != 200 || metadata.entityStatusCode != 200 ||
        track == null || !track.hasGid() || track.gid.length != 16) {
      return null;
    }
    return track;
  }
}
