import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playlist_service/snapshot_revision.dart';
import 'package:spotify_flutter/protocol/generated/lens-model.pb.dart';
import 'package:spotify_flutter/protocol/generated/playlist_api.pb.dart';

List<LensState> lenses(Object? value) => [for (final item in value as List)
  LensState()..mergeFromProto3Json(item)];
List<Delta> deltas(Object? value) => [for (final item in value as List)
  Delta()..mergeFromProto3Json(item)];
List<Op> operations(Object? value) => [for (final item in value as List)
  Op()..mergeFromProto3Json(item)];
List<int> unhex(String value) => [for (var index = 0; index < value.length; index += 2)
  int.parse(value.substring(index, index + 2), radix: 16)];

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/playlist-service-snapshot-revision.json')
    .readAsStringSync()) as Map;
  group('Original full-snapshot revision/cache-owner transition', () {
    for (final scenario in fixture['scenarios'] as List) {
      test(scenario['name'] as String, () {
        final input = scenario['current'] as Map;
        final current = PlaylistSnapshotRevisionState(
          revision: base64Decode(input['revision'] as String),
          revisionLenses: lenses(input['revisionLenses']),
          pendingChanges: deltas(input['pendingChanges']),
          stagedOperations: operations(input['stagedOperations']),
          headless: input['headless'] as bool,
          dropPendingChangesOnSnapshot: input['dropPendingChangesOnSnapshot'] as bool,
          contentGenerationVersion: input['contentGenerationVersion'] as int);
        final reply = SelectedListContent.fromBuffer(unhex(scenario['replyWireHex'] as String));
        final result = advancePlaylistFullSnapshotRevision(current, reply,
          contentGenerationVersion: scenario['contentGenerationVersion'] as int?);
        final expected = scenario['expected'] as Map;
        expect(result.applied, expected['applied']);
        expect(result.state.revision, base64Decode(expected['revision'] as String));
        expect(result.state.revisionLenses, lenses(expected['revisionLenses']));
        expect(result.state.pendingChanges, deltas(expected['pendingChanges']));
        expect(result.state.stagedOperations, operations(expected['stagedOperations']));
        expect(result.state.headless, expected['headless']);
        expect(result.state.dropPendingChangesOnSnapshot, expected['dropPendingChangesOnSnapshot']);
        expect(result.state.contentGenerationVersion, expected['contentGenerationVersion']);
      });
    }
  });

  test('Delta and sync-result admission stays with the separate application owner', () {
    final current = PlaylistSnapshotRevisionState(revision: const [1]);
    for (final branch in ['diff', 'syncResult']) {
      final reply = SelectedListContent()..mergeFromProto3Json({
        'revision': 'Ag==', branch: {'fromRevision': 'AQ==', 'toRevision': 'Ag=='}});
      expect(() => advancePlaylistFullSnapshotRevision(current, reply), throwsUnsupportedError);
    }
  });
}
