import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show hex;
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/native_audio_quality.dart';
import 'package:spotify_flutter/playback/native_audio_rank.dart';
import 'package:spotify_flutter/playback/native_audio_selection.dart';
import 'package:spotify_flutter/playback/native_product_state.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/playback/spotify_media_source.dart';
import 'package:spotify_flutter/playback/spotify_audio_stager.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/generated/es_prefs.pb.dart' as prefs;
import 'package:spotify_flutter/protocol/prefs_store.dart';

void main() {
  test('Outgoing storage format and file fields match original native admission and construction', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-audio-format-selection.json').readAsStringSync()) as Map;
    const defaults = NativeHttpDefaults(userAgent: 'Spotify/offline-fixture');
    final requests = SpotifyRequests(baseUrl: 'https://spclient.example.test',
      inheritedHeaders: const {}, defaults: defaults);
    for (final input in fixture['cases'] as List) {
      final row = input as Map;
      final policy = NativeAudioFormatPolicy(nativeFlag50: row['nativeFlag50'] as bool,
        nativeFlag51: row['nativeFlag51'] as bool, nativeFlag52: row['nativeFlag52'] as bool,
        supportsFormat: (_) => row['supportedByDecoder'] as bool);
      final selected = policy.selectOrdered([NativeAudioFileCandidate(
        fileId: hex.decode(row['fileIdHex'] as String), format: row['format'] as int)]);
      final original = row['storageRequest'] as Map?;
      if (original == null) {
        expect(selected, isNull, reason: row['name'] as String);
        continue;
      }
      expect(selected, isNotNull, reason: row['name'] as String);
      final request = requests.storageResolve(selected!.fileId,
        storageMode: 0, audioFormat: selected.format);
      expect(request.method, (fixture['injectedTemplate'] as Map)['method']);
      expect(request.url, 'https://spclient.example.test/${original['relativePath']}',
        reason: row['name'] as String);
      expect(request.headers, {...original['headers'] as Map, 'User-Agent': defaults.userAgent},
        reason: row['name'] as String);
      expect(request.body, isEmpty);
    }
  });

  test('Outgoing storage request matches original online rank and selected file', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-audio-rank-requests.json').readAsStringSync()) as Map;
    const defaults = NativeHttpDefaults(userAgent: 'Spotify/offline-fixture');
    final requests = SpotifyRequests(baseUrl: 'https://spclient.example.test',
      inheritedHeaders: const {}, defaults: defaults);
    for (final input in fixture['cases'] as List) {
      final row = input as Map;
      final rank = NativeAudioRankPolicy(nativeSetting: row['nativeSetting'] as int,
        nativeClassLimit: row['nativeClassLimit'] as int);
      final ordered = rank.order((row['files'] as List).map((file) => NativeAudioFileCandidate(
        fileId: hex.decode((file as Map)['fileIdHex'] as String), format: file['format'] as int)));
      final selected = const NativeAudioFormatPolicy(nativeFlag50: true,
        nativeFlag51: true, nativeFlag52: true, supportsFormat: _supports).selectOrdered(ordered);
      final original = row['storageRequest'] as Map?;
      final reason = 'setting ${row['nativeSetting']}, class ${row['nativeClassLimit']}, files ${row['files']}';
      if (original == null) {
        expect(selected, isNull, reason: reason);
        continue;
      }
      expect(selected, isNotNull, reason: reason);
      final request = requests.storageResolve(selected!.fileId, storageMode: 0,
        audioFormat: selected.format);
      expect(request.method, (fixture['injectedTemplate'] as Map)['method']);
      expect(request.url, 'https://spclient.example.test/${original['relativePath']}', reason: reason);
      expect(request.headers, {...original['headers'] as Map, 'User-Agent': defaults.userAgent});
      expect(request.body, isEmpty);
    }
  });

  test('Outgoing storage request follows original product entitlement and streaming preferences', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-audio-quality-requests.json').readAsStringSync()) as Map;
    const defaults = NativeHttpDefaults(userAgent: 'Spotify/offline-fixture');
    final requests = SpotifyRequests(baseUrl: 'https://spclient.example.test',
      inheritedHeaders: const {}, defaults: defaults);
    for (final input in fixture['cases'] as List) {
      final row = input as Map, result = row['result'] as Map;
      final store = PrefsStore();
      for (final entry in (row['preferences'] as Map).entries) {
        final snapshot = entry.value as Map, value = snapshot['value'];
        final message = value is bool ? prefs.Value(bool_2: value) : prefs.Value(number: Int64(value as int));
        store.register(entry.key as String, message);
        if (snapshot['overridden'] == true) store.register(entry.key as String, message, flags: 0x100);
      }
      try {
        final policy = NativeAudioQualityPolicy(preferences: store,
          productState: (row['productState'] as Map).cast<String, String>());
        final backend = row['backend'] as Map;
        NativeAudioQuality resolve() => policy.resolve(backend: NativeAudioBackendSettings(
          meteredSetting: backend['meteredSetting'] as int?, unmeteredSetting: backend['unmeteredSetting'] as int?,
          unmeteredSecondarySetting: backend['unmeteredSecondarySetting'] as int,
          supportsCarMode: backend['supportsCarMode'] as bool, downgradeOverride: backend['downgradeOverride'] as bool),
          isMetered: row['isMetered'] as bool, useNetworkSelection: row['useNetworkSelection'] as bool,
          forcedUnmeteredSetting: row['forcedUnmeteredSetting'] as int?);
        if (result['conversionError'] != null) {
          expect(resolve, throwsFormatException, reason: row['name'] as String);
          continue;
        }
        final quality = resolve();
        SpotifyAudioSelection select() => SpotifyAudioSelection.fromNativePolicy(
          uri: 'spotify:track:0000000000000000000000', trackGid: List.filled(16, 0), storageMode: 0,
          eligibleFiles: (row['files'] as List).map((file) => NativeAudioFileCandidate(
            fileId: hex.decode((file as Map)['fileIdHex'] as String), format: file['format'] as int)),
          quality: quality, formatPolicy: const NativeAudioFormatPolicy(nativeFlag50: true,
            nativeFlag51: true, nativeFlag52: true, supportsFormat: _supports),
          // This request-only check never opens a decoder or media file.
          containerFor: (_) => SpotifyAudioContainer.ogg);
        final original = result['storageRequest'] as Map?;
        if (original == null) {
          expect(select, throwsFormatException, reason: row['name'] as String);
          continue;
        }
        final selected = select();
        final request = requests.storageResolve(selected.fileId, storageMode: selected.storageMode,
          audioFormat: selected.audioFormat);
        expect(request.method, 'GET');
        expect(request.url, 'https://spclient.example.test/${original['relativePath']}', reason: row['name'] as String);
        expect(request.headers, {...original['headers'] as Map, 'User-Agent': defaults.userAgent});
        expect(request.body, isEmpty);
      } finally { await store.close(); }
    }
  });
  test('Outgoing storage requests follow original ProductInfo and bitrate configuration', () async {
    final fixtures = ['native-product-state-requests', 'native-bitrate-configuration-requests']
      .map((name) => jsonDecode(File('reverse-engineering/fixtures/$name.json').readAsStringSync()) as Map);
    const defaults = NativeHttpDefaults(userAgent: 'Spotify/offline-fixture');
    final requests = SpotifyRequests(baseUrl: 'https://spclient.example.test',
      inheritedHeaders: const {}, defaults: defaults);
    for (final fixture in fixtures) {
    for (final input in fixture['cases'] as List) {
      final row = input as Map, originalResult = row['result'] as Map;
      final store = PrefsStore();
      final Map<String, String> productState;
      if (row['packetHex'] != null) {
        final product = NativeProductState();
        for (final bytes in row['packetHex'] as List) { product.applyPayload(hex.decode(bytes as String)); }
        productState = product.attributes;
      } else {
        productState = (row['productState'] as Map).cast<String, String>();
      }
      final config = row['configuration'] as Map?;
      final configuration = config == null ? null : NativeCoreBitrateConfiguration(
        integers: (config['integers'] as Map? ?? {}).cast<String, int>(),
        booleans: (config['booleans'] as Map? ?? {}).cast<String, bool>(),
        petrelMaxRate: config['petrelMaxRate'] as String?);
      for (final entry in (row['preferences'] as Map).entries) {
        final snapshot = entry.value as Map;
        final raw = snapshot['value'];
        final value = raw is bool ? prefs.Value(bool_2: raw) : prefs.Value(number: Int64(raw as int));
        store.register(entry.key as String, value);
        if (snapshot['overridden'] == true) store.register(entry.key as String, value, flags: 0x100);
      }
      try {
        SpotifyAudioSelection select() {
          final backend = fixture['backend'] as Map?;
          final settings = configuration?.backendSettings(productState) ?? NativeAudioBackendSettings(
            meteredSetting: backend!['meteredSetting'] as int?, unmeteredSetting: backend['unmeteredSetting'] as int?,
            unmeteredSecondarySetting: backend['unmeteredSecondarySetting'] as int,
            supportsCarMode: backend['supportsCarMode'] as bool, downgradeOverride: backend['downgradeOverride'] as bool);
          final quality = NativeAudioQualityPolicy(preferences: store, productState: productState)
            .resolve(backend: settings, isMetered: row['isMetered'] as bool? ?? false,
              useNetworkSelection: row['useNetworkSelection'] as bool? ?? true);
          return SpotifyAudioSelection.fromNativePolicy(uri: 'spotify:track:0000000000000000000000',
            trackGid: List.filled(16, 0), storageMode: 0,
            eligibleFiles: (row['files'] as List? ?? fixture['files'] as List).map((file) => NativeAudioFileCandidate(
              fileId: hex.decode((file as Map)['fileIdHex'] as String), format: file['format'] as int)),
            quality: quality, formatPolicy: configuration?.formatPolicy(
              supportsFormat: (_) => row['supportedByDecoder'] as bool? ?? true) ??
              const NativeAudioFormatPolicy(nativeFlag50: true,
                nativeFlag51: true, nativeFlag52: true, supportsFormat: _supports),
            containerFor: (_) => SpotifyAudioContainer.ogg);
        }
        final original = originalResult['storageRequest'] as Map?;
        if (original == null) {
          expect(select, throwsFormatException, reason: row['name'] as String);
          continue;
        }
        final SpotifyAudioSelection selected;
        try { selected = select(); }
        catch (error) { fail('${row['name']}: $error; product $productState'); }
        final request = requests.storageResolve(selected.fileId, storageMode: selected.storageMode,
          audioFormat: selected.audioFormat);
        expect(request.method, 'GET', reason: row['name'] as String);
        expect(request.url, 'https://spclient.example.test/${original['relativePath']}', reason: row['name'] as String);
        expect(request.headers, {...original['headers'] as Map, 'User-Agent': defaults.userAgent},
          reason: row['name'] as String);
        expect(request.body, isEmpty, reason: row['name'] as String);
      } finally { await store.close(); }
    }
    }
  });
}

bool _supports(int format) => true;
