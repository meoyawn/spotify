import 'generated/playlist_api.pb.dart';
import 'native_image_request.dart';

/// Playlist4 ListAttributes fields13/3: retain server picture-size URLs, or
/// project an actual20-byte image identity using the explicit AP image template.
/// Original renderer71646 and native10059aa2c own the image ID/URL projection;
/// reverse-engineering/evidence/native-image-uri.json records independent original execution.
/// target_name is retained without inferring pixel sizes. Unknown picture byte
/// formats and absent covers do not become invented mosaics or CDN endpoints.
List<Map<String, Object?>> nativePlaylistImages(ListAttributes attributes,
    {required String imageUrlTemplate}) {
  final supplied = <Map<String, Object?>>[
    for (final picture in attributes.pictureSize)
      if (picture.url.isNotEmpty) {
        'url': picture.url,
        if (picture.hasTargetName()) 'targetName': picture.targetName,
      },
  ];
  if (supplied.isNotEmpty) return List.unmodifiable(supplied);
  if (attributes.picture.length != 20) return const [];
  return [
    {'url': nativeImageUrlForId(attributes.picture, template: imageUrlTemplate)},
  ];
}
