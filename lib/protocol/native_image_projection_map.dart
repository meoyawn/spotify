import 'dart:typed_data';

import 'package:convert/convert.dart' show hex;

import 'generated/image_resolve.pb.dart';
import 'request_builder.dart';

/// Original 0x10059005c registers false fallbacks for all four flags. The owner
/// supplies an explicit app feature choice or actual remote-config values;
/// enabling a Dart feature does not establish the original user's assignment.
final class NativeImageResolveConfiguration {
  const NativeImageResolveConfiguration({required this.enableProjectionMapLoading,
    required this.enableImageResolve, required this.enableOnlineImageResolve,
    required this.enableOnlineSizeImageResolve});
  final bool enableProjectionMapLoading;
  final bool enableImageResolve;
  final bool enableOnlineImageResolve;
  final bool enableOnlineSizeImageResolve;
}

/// Whole original GET owner 0x10059dcc0 sets only method and relative path.
/// Its explicit inherited template owns headers, body, credentials and context.
final class NativeImageProjectionMapRequestPlan {
  NativeImageProjectionMapRequestPlan._(this.request);

  factory NativeImageProjectionMapRequestPlan.forEnabledLoading({
    required RequestEnvelope template,
    required NativeImageResolveConfiguration configuration,
  }) {
    if (!configuration.enableProjectionMapLoading) {
      throw StateError('Native projection-map loading is disabled');
    }
    final uri = Uri.tryParse(template.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.query.isNotEmpty || uri.fragment.isNotEmpty ||
        uri.path.isNotEmpty && uri.path != '/' || template.url.contains('?') ||
        template.url.contains('#') || template.url.contains('\\') ||
        template.url.codeUnits.any((code) => code <= 32 || code >= 127)) {
      throw ArgumentError.value(template.url, 'template.url', 'An explicit HTTPS origin is required');
    }
    final base = template.url.endsWith('/') ? template.url : '${template.url}/';
    return NativeImageProjectionMapRequestPlan._(RequestEnvelope(method: 'GET',
      url: '$base$relativePath', headers: template.headers, body: template.body,
      authorize: template.authorize, includeCredentials: template.includeCredentials,
      responseType: template.responseType,
      nativeTimeoutMilliseconds: template.nativeTimeoutMilliseconds, cancellationToken: template.cancellationToken));
  }

  static const relativePath = 'image-resolve/v1/resolve/map';
  final RequestEnvelope request;
}

final class NativeImageProjection {
  const NativeImageProjection._({required this.id, required this.template,
    required this.width, required this.height, required this.fetchOnline,
    required this.downloadForOffline});
  final String id;
  final String template;
  final int width;
  final int height;
  final bool fetchOnline;
  final bool downloadForOffline;
  int get _order => (width + height).toSigned(32);
}

final class NativeImageProjectionResult {
  NativeImageProjectionResult._(List<String> urls, this.preferredUrl, this.scale)
    : urls = List.unmodifiable(urls);
  final List<String> urls;
  final String preferredUrl;
  final double? scale;
}

/// Exact image_resolve.proto response plus proprietary expansion0x10059e788
/// and online projection0x10059bf48. The schema is extracted, not handwritten.
/// Source/proof: reverse-engineering/evidence/native-image-projection-map.json. No transport,
/// original cache migration, hostname substitution or remote-config inference.
final class NativeImageProjectionMap {
  NativeImageProjectionMap._(this.response, Map<String, List<NativeImageProjection>> collections)
    : collections = Map.unmodifiable(collections);

  factory NativeImageProjectionMap.fromResponseBytes(List<int> body) {
    final response = ProjectionsResponse.fromBuffer(body)..check();
    final map = response.projectionMap;
    final collections = <String, List<NativeImageProjection>>{};
    for (final collection in map.collections) {
      final key = hex.encode(collection.id);
      final projections = <NativeImageProjection>[];
      for (final projection in collection.projections) {
        final metadataIndex = projection.metadataIndex;
        final templateIndex = projection.urlTemplateIndex;
        if (metadataIndex < 0 || metadataIndex >= map.projectionMetas.length ||
            templateIndex < 0 || templateIndex >= map.urlTemplates.length) continue;
        final metadata = map.projectionMetas[metadataIndex];
        projections.add(NativeImageProjection._(id: hex.encode(projection.id),
          template: map.urlTemplates[templateIndex], width: metadata.width,
          height: metadata.height, fetchOnline: metadata.fetchOnline,
          downloadForOffline: metadata.downloadForOffline));
      }
      if (projections.isEmpty) continue;
      projections.sort((a, b) => a._order.compareTo(b._order));
      // Native unordered_map insertion retains the first nonempty collection.
      collections.putIfAbsent(key, () => List.unmodifiable(projections));
    }
    return NativeImageProjectionMap._(response..freeze(), collections);
  }

  final ProjectionsResponse response;
  final Map<String, List<NativeImageProjection>> collections;

  /// Raw preference is provider virtual+0x20 (0x10059ed1c, owner+0x38).
  /// It is required because its concrete storage/update policy is separate.
  /// The returned candidate URLs are server-configured values; the image client
  /// still owns URL admission and public requests without account credentials.
  NativeImageProjectionResult? project({required List<int> imageId20,
    required NativeImageResolveConfiguration configuration,
    required bool nativePreference, int? width, int? height}) {
    if (!configuration.enableOnlineImageResolve) return null;
    if (imageId20.length != 20 || imageId20.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('A native Spotify image identity must contain20 octets');
    }
    if (width != null && width != width.toSigned(32) ||
        height != null && height != height.toSigned(32)) {
      throw ArgumentError('Native image dimensions must be signed32 values');
    }
    final identity = hex.encode(imageId20);
    final collection = collections[identity.substring(0, 8)];
    if (collection == null) return null;
    var targetWidth = width;
    var targetHeight = height;
    if (!configuration.enableOnlineSizeImageResolve || width == null || height == null) {
      final current = _firstEquivalent(collection.where((entry) => entry.id == identity.substring(8, 16)).toList());
      if (current == null) return null;
      targetWidth = current.width;
      targetHeight = current.height;
    }
    final resolvedWidth = targetWidth!;
    final resolvedHeight = targetHeight!;
    final online = _choose(collection.where((entry) => entry.fetchOnline).toList(), resolvedWidth, resolvedHeight);
    final offline = _choose(collection.where((entry) => entry.downloadForOffline).toList(), resolvedWidth, resolvedHeight);
    if (online == null || offline == null) return null;
    final neutral = _choose(collection.where((entry) => !entry.fetchOnline && !entry.downloadForOffline).toList(),
      resolvedWidth, resolvedHeight);
    String url(NativeImageProjection projection) => projection.template.replaceAll('{file_id}',
      '${identity.substring(0, 8)}${projection.id}${identity.substring(16)}');
    final onlineUrl = url(online);
    final offlineUrl = url(offline);
    double? scale;
    if (width != null && height != null && width != 0 && height != 0) {
      final x = _float32(_float32(width.toDouble()) / _float32(online.width.toDouble()));
      final y = _float32(_float32(height.toDouble()) / _float32(online.height.toDouble()));
      scale = y <= x ? x : y;
    }
    return NativeImageProjectionResult._([offlineUrl, onlineUrl,
      if (neutral != null) url(neutral), 'spotify:image:$identity'],
      nativePreference ? offlineUrl : onlineUrl, scale);
  }

  static NativeImageProjection? _choose(List<NativeImageProjection> entries, int width, int height) {
    if (entries.isEmpty) return null;
    final matching = entries.where((entry) => entry.width >= width && entry.height >= height).toList();
    if (matching.isNotEmpty) return _firstEquivalent(matching);
    final lastOrder = entries.last._order;
    return _equivalent(entries.where((entry) => entry._order == lastOrder).toList());
  }

  static NativeImageProjection? _firstEquivalent(List<NativeImageProjection> entries) {
    if (entries.isEmpty) return null;
    final firstOrder = entries.first._order;
    return _equivalent(entries.where((entry) => entry._order == firstOrder).toList());
  }

  static NativeImageProjection _equivalent(List<NativeImageProjection> entries) {
    final first = entries.first;
    if (entries.any((entry) => entry.id != first.id || entry.template != first.template ||
        entry.width != first.width || entry.height != first.height)) {
      throw UnsupportedError('Native equal-size projection ordering requires independent evidence');
    }
    return first;
  }

  static double _float32(double value) {
    final bytes = ByteData(4)..setFloat32(0, value, Endian.little);
    return bytes.getFloat32(0, Endian.little);
  }
}
