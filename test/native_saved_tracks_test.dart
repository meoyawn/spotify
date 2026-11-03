import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/library/native_saved_tracks.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';

void main() {
  test('Saved-track calls match unchanged original native service method and payload bytes', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-saved-tracks.json').readAsStringSync()) as Map<String, dynamic>;
    for (final raw in fixture['scenarios'] as List) {
      final scenario = raw as Map<String, dynamic>;
      final expected = scenario['expected'] as Map<String, dynamic>;
      final response = _hex(scenario['responseHex'] as String);
      final calls = <Map<String, Object?>>[];
      final dispatcher = EsperantoDispatcher();
      for (final service in [NativeSavedTracksRepository.collectionService, NativeSavedTracksRepository.playlistService]) {
        dispatcher.register(service, EsperantoService(single: {
          for (final method in ['Contains', 'Add', 'Remove', 'Modify']) method: (payload) {
            calls.add({'service': service, 'method': method,
              'payloadHex': payload.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()});
            return response;
          },
        }));
      }
      final source = scenario['saveSource'] as Map<String, dynamic>?;
      final repository = NativeSavedTracksRepository(dispatcher,
        likedSongsListPlatformEnabled: scenario['listPlatform'] as bool,
        likedSongsUri: scenario['likedSongsUri'] as String,
        saveSource: source == null ? null : (_, _) => NativeSavedTrackSaveSource(
          originalUri: source['originalUri'] as String?, interactionId: source['interactionId'] as String?));
      final uris = (scenario['uris'] as List).cast<String>();
      if (scenario['action'] == 'contains') {
        expect(await repository.contains(uris), expected['membership'], reason: scenario['name'] as String);
      } else {
        await repository.setSaved(uris.single, scenario['action'] == 'add');
      }
      expect(calls, expected['calls'], reason: scenario['name'] as String);
    }
  });
}

List<int> _hex(String input) => [for (var i = 0; i < input.length; i += 2) int.parse(input.substring(i, i + 2), radix: 16)];
