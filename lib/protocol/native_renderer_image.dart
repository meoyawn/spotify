import 'dart:math' as math;

import 'native_renderer_image_projections.dart';

final _imageShape = RegExp(r'^(https://(?:i\.scdn\.co|image-cdn-[^.]+\.spotifycdn\.com)/image/|spotify:image:)([0-9a-f]{8})([0-9a-f]{8})(.*)$');

/// Original renderer43575 optimizer with original27744 projection data. The
/// caller supplies layout, standard display/data-saving inputs and enabled
/// collections. No host substitution, native map request or entitlement input.
String? nativeRendererImageUrl(String? input, {double? width, double? height,
    double devicePixelRatio = 1, bool saveData = false,
    Set<String>? enabledCollections, bool rewriteForPlatform = false}) {
  if (width != null && (!width.isFinite || width < 0) ||
      height != null && (!height.isFinite || height < 0) || !devicePixelRatio.isFinite) {
    throw ArgumentError('Image layout must contain finite nonnegative dimensions');
  }
  var result = input;
  final match = input == null ? null : _imageShape.firstMatch(input);
  if (match != null) {
    final collection = match[2]!, current = match[3]!;
    final groups = nativeRendererImageProjections[collection];
    if (groups != null && (enabledCollections == null || enabledCollections.contains(collection))) {
      final defaults = groups['defaultGroup']!, webp = groups['webp']!;
      if (defaults.containsKey(current) || webp.containsKey(current)) {
        String selected = current;
        if (!_truthy(width) && !_truthy(height) && defaults.containsKey(current)) {
          final dimensions = defaults[current]!;
          for (final entry in webp.entries) {
            if (entry.value.length == dimensions.length && entry.value.indexed.every(
                (item) => item.$2 == dimensions[item.$1])) { selected = entry.key; break; }
          }
        } else if (_truthy(width) || _truthy(height)) {
          final ratio = saveData ? 1.0 : math.max(devicePixelRatio, 1.0);
          final group = webp.isNotEmpty ? webp : defaults;
          final scores = [for (final (index, entry) in group.entries.indexed) (
            id: entry.key, area: entry.value[0] * (entry.value.elementAtOrNull(1) ?? entry.value[0]),
            index: index, score: _score(entry.value, width, height, ratio))];
          scores.sort((a, b) {
            final score = a.score.compareTo(b.score);
            if (score != 0) return score;
            final area = a.area.compareTo(b.area);
            return area != 0 ? area : a.index.compareTo(b.index);
          });
          selected = scores.first.id;
        }
        if (selected != current) result = '${match[1]}$collection$selected${match[4]}';
      }
    }
  }
  if (rewriteForPlatform && result != null) {
    final rewritten = _imageShape.firstMatch(result);
    if (rewritten != null) result = 'spotify:image:${rewritten[2]}${rewritten[3]}${rewritten[4]}';
  }
  return result;
}

bool _truthy(double? value) => value != null && value != 0;

double _score(List<int> dimensions, double? width, double? height, double ratio) {
  final w = dimensions[0], h = dimensions.elementAtOrNull(1) ?? w;
  final ratios = [if (_truthy(width)) w / width!, if (_truthy(height)) h / height!];
  double average(double Function(double) contribution) =>
    ratios.map(contribution).reduce((a, b) => a + b) / ratios.length;
  final targetArea = _truthy(width) && _truthy(height) ? width! * height! :
    math.pow(width ?? height ?? 1, 2);
  final multiplier = 1.7 * math.max(math.sqrt(targetArea) / 300, 1);
  return math.sqrt(w * h / 1000000) + multiplier * average((value) =>
    math.pow(math.max(math.log(ratio / math.max(value, 1)), 0), 2).toDouble()) +
    average((value) => value < 1 ? math.pow(1 / value, 2.5).toDouble() - 1 : 0);
}

/// Whole original43575 source wrapper and50242 nearest-area fallback. An
/// optimized first source supplies one URL. Without a size it preserves each
/// source's metadata while applying the original format conversion.
List<Map<String, Object?>> nativeRendererImageSources(List<Map<String, Object?>> sources,
    {double? width, double? height, double devicePixelRatio = 1, bool saveData = false,
     Set<String>? enabledCollections, bool rewriteForPlatform = false}) {
  String? optimize(Object? url) => nativeRendererImageUrl(url as String?, width: width,
    height: height, devicePixelRatio: devicePixelRatio, saveData: saveData,
    enabledCollections: enabledCollections, rewriteForPlatform: rewriteForPlatform);
  if (sources.isNotEmpty) {
    if (width == null && height == null) {
      return [for (final source in sources) {...source, 'url': optimize(source['url']) ?? source['url']}];
    }
    final original = sources.first['url'], optimized = optimize(original);
    if (optimized != original) return [{'url': optimized}];
  }
  if (sources.length <= 1) return sources;
  final target = (width ?? 9007199254740991) * (height ?? width ?? 9007199254740991);
  double area(Map<String, Object?> image) {
    final w = (image['width'] as num?)?.toDouble(), h = (image['height'] as num?)?.toDouble();
    return (_truthy(w) ? w! : _truthy(h) ? h! : 0) *
      (_truthy(h) ? h! : _truthy(w) ? w! : 0);
  }
  double distance(Map<String, Object?> image) {
    final pixels = area(image);
    return math.max(pixels, target) / math.min(pixels, target);
  }
  var selected = sources.first, best = distance(sources.first);
  for (final source in sources.skip(1)) {
    final score = distance(source);
    if (score < best) { selected = source; best = score; }
  }
  return [selected];
}
