/// Presentation policy: SpotX-Official/SpotX at 06f7fa2eac989c84613b2e0efc9b18acaf97f6cb,
/// free.emptyblock and VariousJs.banner_home. Protocol state stays unmodified.
bool isAdvertisement(String uri, [Map<String, String> metadata = const {}]) {
  final value = uri.split('?').first.split('#').first;
  return RegExp(r'^(?:spotify:ad(?:$|:)|/ad(?:$|/)|https?://(?:open|play)\.spotify\.com/ad(?:$|/))').hasMatch(value) ||
    metadata['is_podcast_advertisement']?.toLowerCase() == 'true' ||
    metadata['ad_id']?.isNotEmpty == true;
}

bool isAdvertisingSection(String type) => const {
  'HomeNativeAdsSectionData', 'HomePromotionSectionData',
}.contains(type);
