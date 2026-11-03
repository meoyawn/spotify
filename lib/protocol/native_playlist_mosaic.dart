import 'native_image_request.dart';
import 'generated/metadata.pb.dart' as metadata;

/// Original101b8e99c: TrackData ready byte must equal1; native class bits are
/// masked by0xc69 unless the explicit collector override is enabled. A normal
/// online TrackModel (+38) classifies0 only with a ready metadata context in
/// 101ce54bc. These are native source-state inputs, not country restrictions or
/// a permission inferred from a successful HTTP response.
bool nativePlaylistMosaicTrackDataAdmitted({required bool ready,
    required int rawClass, required bool includeOtherClasses}) =>
  ready && (includeOtherClasses || ((1 << (rawClass & 31)) & 0xc69) != 0);

/// Installed Album adapter102676250/+18 ->101d051bc ->101d08ec4 reads only
/// cover_group, finds the FIRST Image.size==0 in server order and requires a
/// twenty-byte file_id. A malformed first match does not select a later match.
/// Original packed rank-zero reader101cb4c5c treats an all-zero ID as absent.
/// No deprecated Album.cover or alternative-size fallback is inferred.
List<int>? nativePlaylistMosaicTrackRankZeroImageId(metadata.Track track,
    {required bool nativeTrackDataReady, required int nativeTrackDataClass,
      required bool includeOtherClasses}) {
  if (!nativePlaylistMosaicTrackDataAdmitted(ready: nativeTrackDataReady,
      rawClass: nativeTrackDataClass, includeOtherClasses: includeOtherClasses) ||
      !track.hasAlbum() || !track.album.hasCoverGroup()) return null;
  for (final image in track.album.coverGroup.image) {
    // The original reader compares the proto2 enum's effective numeric value;
    // it does not inspect the optional size field's has-bit.
    if (image.size.value != 0) continue;
    final identity = image.fileId;
    if (identity.length != 20 || identity.every((byte) => byte == 0)) return null;
    return List.unmodifiable(identity);
  }
  return null;
}

/// Original101afe750 grid2 collector,101b8eb58 uniqueness,101b8ed38 readiness
/// and101b8ed6c finalizer. Inputs must be already selected/admitted rank0 online
/// image IDs in original playlist order; this does not select a TrackV4 cover,
/// apply source flags or fetch missing metadata. Independent original execution:
/// reverse-engineering/evidence/native-playlist-mosaic-selector.json.
String nativePlaylistMosaicUri(Iterable<List<int>> orderedSelectedImageIds) {
  final selected = <String>[];
  for (final identity in orderedSelectedImageIds) {
    if (identity.length != 20 || identity.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('A selected playlist cover must contain20 octets');
    }
    final hex = identity.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    if (!selected.contains(hex)) selected.add(hex);
    if (selected.length == 4) break;
  }
  if (selected.isEmpty) return '';
  if (selected.length < 4) return 'spotify:image:${selected.first}';
  return 'spotify:mosaic:${selected.join(':')}';
}

/// Original71646 forward projection for already selected components. Single
/// images retain the caller's actual AP template; mosaics use the original
/// public renderer URL and its explicit/default300 size, with no host swapping.
String nativePlaylistMosaicImageUrl(Iterable<List<int>> orderedSelectedImageIds,
    {required String imageUrlTemplate, int desiredMosaicSize = 300}) {
  if (desiredMosaicSize < 1) throw ArgumentError('Mosaic size must be positive');
  final uri = nativePlaylistMosaicUri(orderedSelectedImageIds);
  if (uri.isEmpty) return '';
  if (uri.startsWith('spotify:image:')) {
    final hex = uri.substring('spotify:image:'.length);
    return nativeImageUrlForId([for (var at = 0; at < hex.length; at += 2)
      int.parse(hex.substring(at, at + 2), radix: 16)], template: imageUrlTemplate);
  }
  return 'https://mosaic.scdn.co/$desiredMosaicSize/${uri.split(':').skip(2).join()}';
}
