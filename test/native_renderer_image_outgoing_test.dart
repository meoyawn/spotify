import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_renderer_image.dart';

void main() {
  test('outgoing image URLs and source choices match the unchanged original renderer', () {
    final fixture = jsonDecode(File('reverse-engineering/evidence/native-renderer-image-projection.json').readAsStringSync()) as Map;
    double? dimension(Object? value) => (value as num?)?.toDouble();
    Set<String>? collections(Map input) => input['enabledCollections'] == null ? null :
      (input['enabledCollections'] as List).cast<String>().toSet();
    for (final entry in fixture['cases'] as List) {
      final input = entry['input'] as Map;
      expect(nativeRendererImageUrl(input['url'] as String?, width: dimension(input['width']),
        height: dimension(input['height']), devicePixelRatio: dimension(input['devicePixelRatio'])!,
        saveData: input['saveData'] as bool, enabledCollections: collections(input),
        rewriteForPlatform: input['rewrite'] as bool), entry['originalUrl'], reason: entry['name'] as String);
    }
    for (final entry in fixture['selections'] as List) {
      final input = entry['input'] as Map;
      expect(nativeRendererImageSources((input['images'] as List).map((image) =>
        (image as Map).cast<String, Object?>()).toList(), width: dimension(input['width']),
        height: dimension(input['height']), devicePixelRatio: dimension(input['devicePixelRatio'])!,
        saveData: input['saveData'] as bool, enabledCollections: collections(input),
        rewriteForPlatform: input['rewrite'] as bool), entry['originalSources'], reason: entry['name'] as String);
    }
  });
}
