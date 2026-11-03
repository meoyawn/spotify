import 'dart:convert';
import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playlist_service/query.dart';
import 'package:spotify_flutter/playlist_service/sync_path.dart';
import 'package:spotify_flutter/playlist_service/sync_plan.dart';
import 'package:spotify_flutter/playlist_service/native_write_plan.dart';
import 'package:spotify_flutter/protocol/generated/playlist_api.pb.dart';
import 'package:spotify_flutter/protocol/generated/playlist_query.pb.dart';
import 'package:spotify_flutter/protocol/generated/playlist_sync_reason.pbenum.dart';
import 'package:spotify_flutter/protocol/generated/policy/supported_link_types_in_playlists.pbenum.dart';

void main() {
  test('Native single-track ListChanges outgoing body matches original Add Remove staging and writer bytes', () {
    final fixture = jsonDecode(File('reverse-engineering/evidence/native-playlist-list-changes.json').readAsStringSync()) as Map;
    for (final scenario in fixture['cases'] as List) {
      final input = scenario['inputs'] as Map;
      final revision = base64Decode(input['revision'] as String);
      final NativePlaylistChangesBody plan;
      if (input['kind'] == 'add') {
        final ItemAttributes attributes;
        if (input.containsKey('freshRowAlgorithm')) {
          final hex = input['freshRowEntropyHex'] as String? ?? '';
          final entropy = [for (var offset = 0; offset < hex.length; offset += 2)
            int.parse(hex.substring(offset, offset + 2), radix: 16)];
          attributes = NativePlaylistChangesBody.freshRowAttributes(
            username: input['username'] as String, clockMicroseconds: input['clockMicroseconds'] as int,
            uri: input['uri'] as String,
            itemIdAlgorithm: ItemIdAlgorithm.valueOf(input['freshRowAlgorithm'] as int)!,
            entropy: (_) => entropy);
        } else {
          final values = input['attributes'] as Map;
          attributes = ItemAttributes();
          if (values.containsKey('addedBy')) attributes.addedBy = values['addedBy'] as String;
          if (values.containsKey('timestamp')) attributes.timestamp = Int64.parseInt(values['timestamp'] as String);
          if (values.containsKey('itemId')) attributes.itemId = base64Decode(values['itemId'] as String);
        }
        plan = NativePlaylistChangesBody.add(currentRevision: revision,
          priorNonce: input['priorNonce'] as int, username: input['username'] as String,
          clockMicroseconds: input['clockMicroseconds'] as int, uri: input['uri'] as String,
          previousLength: input['previousLength'] as int, rowAttributes: attributes);
      } else {
        plan = NativePlaylistChangesBody.remove(currentRevision: revision,
          priorNonce: input['priorNonce'] as int, username: input['username'] as String,
          clockMicroseconds: input['clockMicroseconds'] as int, uri: input['uri'] as String,
          index: input['index'] as int, itemId: base64Decode(input['itemId'] as String));
      }
      final actual = plan.body.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(actual, scenario['bodyHex'], reason: scenario['name'] as String);
    }
  });
  group('Original native Playlist Get query compilation', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/playlist-service-query.json').readAsStringSync()) as Map;
    for (final scenario in fixture['scenarios'] as List) {
      test(scenario['name'] as String, () {
        final input = (scenario['query'] as Map).cast<String, Object?>();
        final query = PlaylistQuery();
        for (final value in (input['boolPredicates'] as List? ?? []).cast<int>()) {
          final predicate = PlaylistQuery_BoolPredicate.valueOf(value);
          if (predicate == null) { query.unknownFields.mergeVarintField(1, Int64(value)); }
          else { query.boolPredicates.add(predicate); }
        }
        final sort = input['sortBy'] as int? ?? 0;
        final sortValue = PlaylistQuery_SortBy.valueOf(sort);
        if (sortValue == null) { query.unknownFields.mergeVarintField(3, Int64(sort)); }
        else { query.sortBy = sortValue; }
        final source = input['sourceRestriction'] as int? ?? 0;
        final sourceValue = PlaylistSourceRestriction.valueOf(source);
        if (sourceValue == null) { query.unknownFields.mergeVarintField(7, Int64(source)); }
        else { query.sourceRestriction = sourceValue; }
        query
          ..textFilter = input['textFilter'] as String? ?? ''
          ..itemIdFilter = input['itemIdFilter'] as String? ?? ''
          ..providedSortInternalId = input['providedSortInternalId'] as String? ?? ''
          ..showUnavailable = input['showUnavailable'] as bool? ?? false
          ..includePremiumContent = input['includePremiumContent'] as bool? ?? false
          ..includeAllPlaceholders = input['includeAllPlaceholders'] as bool? ?? false
          ..dontLoadItemMetadata = input['dontLoadItemMetadata'] as bool? ?? false;
        query.supportedPlaceholderTypes.addAll((input['supportedPlaceholderTypes'] as List? ?? [])
          .cast<int>().map((value) => LinkType.valueOf(value)!));
        query.descriptorFilter.addAll((input['descriptorFilter'] as List? ?? []).cast<String>());
        query.languageFilter.addAll((input['languageFilter'] as List? ?? []).cast<String>());
        query.tagIdFilter.addAll((input['tagIdFilter'] as List? ?? []).cast<int>());
        query.attributeFilter.addAll([for (final values in input['attributeFilter'] as List? ?? [])
          PlaylistQuery_AttributeFilter(containsOneOf: (values as List).cast<String>())]);
        expect(compilePlaylistQuery(query).toJson(), scenario['expected']);
      });
    }
  });
  group('Original primary synchronization request plan', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/playlist-service-sync-plan.json').readAsStringSync()) as Map;
    for (final scenario in fixture['scenarios'] as List) {
      test(scenario['name'] as String, () {
        final input = scenario['input'] as Map;
        expect(buildPlaylistSyncPlan(canonicalUri: input['uri'] as String,
          caller: PlaylistSyncCaller.valueOf(input['caller'] as int)!, prioritized: input['prioritized'] as bool,
          mode: PlaylistSyncMode.values[input['mode'] as int? ?? 0],
          acceptListItems: input['acceptListItems'] as bool? ?? false,
          handlesContent: input['handlesContent'] as bool? ?? false, force: input['force'] as bool? ?? false,
          hintRevision: input['hintRevision'] as String? ?? '', dsaMode: input['dsa'] as bool?,
          listPlayerEnabled: input['listPlayerEnabled'] as bool? ?? false).toJson(), scenario['expected']);
      });
    }
    test('unrecovered lens URI does not become a plain synchronization path', () {
      expect(() => buildPlaylistSyncPlan(canonicalUri: 'spotify:playlist:0000000000000000000001:tag-filter:fixture',
        caller: PlaylistSyncCaller.ESPERANTO, prioritized: false), throwsUnsupportedError);
    });
  });
  group('Original synchronization query bytes', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/playlist-service-sync-query.json').readAsStringSync()) as Map;
    for (final scenario in fixture['scenarios'] as List) {
      test('${scenario['uri']} with${(scenario['values'] as List).length} entries', () {
        final route = PlaylistSyncRoute(path: scenario['uri'] as String, method: 'GET').withQuery([
          for (final pair in scenario['values'] as List) MapEntry((pair as List)[0] as String, pair[1] as String)]);
        expect(route.path, scenario['expected']);
      });
    }
  });
}
