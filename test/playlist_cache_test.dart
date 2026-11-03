import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playlist_service/cache_snapshot.dart';
import 'package:spotify_flutter/protocol/generated/lens-model.pb.dart';
import 'package:spotify_flutter/protocol/generated/playlist_api.pb.dart' as api;
import 'package:spotify_flutter/protocol/generated/playlist_cache.pb.dart' as cache;
import 'package:spotify_flutter/protocol/generated/playlist_permission.pb.dart' as permission;
import 'package:spotify_flutter/protocol/generated/signal-model.pb.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/playlist-service-cache.json').readAsStringSync()) as Map;
  group('Original native playlist cache projection bytes', () {
    for (final scenario in fixture['scenarios'] as List) {
      test(scenario['name'] as String, () {
        final input = scenario['state'] as Map;
        final encoded = encodePlaylistCacheSnapshot(PlaylistCacheState(
          revision: base64Decode(input['revision'] as String),
          attributes: api.ListAttributes()..mergeFromProto3Json(input['attributes']),
          items: [for (final value in input['items'] as List) PlaylistCacheItem(
            canonicalUri: (value as Map)['canonicalUri'] as String,
            attributes: api.ItemAttributes()..mergeFromProto3Json(value['attributes']))],
          ownerUsername: input['ownerUsername'] as String,
          timestampMicroseconds: input['timestampMicroseconds'] as int,
          createdAtMicroseconds: input['createdAtMicroseconds'] as int,
          abuseReportingEnabled: input['abuseReportingEnabled'] as bool,
          members: permission.GetMemberPermissionsResponse()..mergeFromProto3Json(input['members']),
          permissions: permission.Permissions()..mergeFromProto3Json(input['permissions']),
          contentGenerationVersion: input['contentGenerationVersion'] as int,
          cacheRefreshNeeded: input['cacheRefreshNeeded'] as bool,
          headlessState: input['headlessState'] as bool,
          appliedLenses: [for (final value in input['appliedLenses'] as List)
            LensState()..mergeFromProto3Json(value)],
          availableSignals: [for (final value in input['availableSignals'] as List)
            Signal()..mergeFromProto3Json(value)],
          pendingChanges: [for (final value in input['pendingChanges'] as List)
            api.Delta()..mergeFromProto3Json(value)],
          requestedLenses: (input['requestedLenses'] as List).cast<String>(),
          geoblock: [for (final value in input['geoblock'] as List)
            api.GeoblockBlockingType.valueOf(value as int)!],
          capabilities: input['capabilities'] == null ? null :
            (permission.Capabilities()..mergeFromProto3Json(input['capabilities'])),
          cacheHintInfo: input['cacheHintInfo'] == null ? null :
            (cache.CacheHintInfo()..mergeFromProto3Json(input['cacheHintInfo'])),
        ), errorMode: input['errorMode'] as int? ?? 0,
          errorCode: input['errorCode'] as int?,
          storedInfo: input['storedInfo'] == null || input['storedReadSucceeded'] == false ? null :
            (cache.PlaylistCacheInfo()..mergeFromProto3Json(input['storedInfo'])));
        final hex = encoded.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        expect(hex, scenario['wireHex'], reason: 'Original target: ${scenario['expected']}');
      });
    }
  });
}
