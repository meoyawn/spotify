import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/native_playplay_request.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/protocol/native_ap_resolver.dart';
import 'package:spotify_flutter/protocol/native_cef_context.dart';
import 'package:spotify_flutter/protocol/native_cef_http_request.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('music and storage authorities follow the original regional resolver selection', () {
    final evidence = jsonDecode(File('reverse-engineering/evidence/native-regional-spclient.json').readAsStringSync()) as Map;
    final endpoints = decodeNativeApResolverResponse(status: 200,
      body: utf8.encode(jsonEncode({'spclient': evidence['resolver']['spclient']})));
    final origin = nativeRegionalSpclientOrigin(endpoints);
    const file = '000102030405060708090a0b0c0d0e0f10111213';
    const headers = {'Accept-Language': 'en', 'app-platform': 'OSX_ARM64',
      'spotify-app-version': '130601921', 'time-zone': 'Europe/Moscow',
      'User-Agent': 'Spotify/130601921 OSX_ARM64/OS X 26.4.0 [arm 2]'};
    const defaults = NativeHttpDefaults(userAgent: 'Spotify/130601921 OSX_ARM64/0 (MacBookPro18,1)');
    final key = NativePlayPlayRequestPlan.musicKey(
      template: RequestEnvelope(method: 'GET', url: origin, headers: headers),
      fileId20: List.generate(20, (index) => index), serializedBody: [1]).request;
    final storage = SpotifyRequests(baseUrl: origin, inheritedHeaders: headers, defaults: defaults)
      .storageResolve(List.generate(20, (index) => index), storageMode: 0, audioFormat: 1);
    for (final original in evidence['requests'] as List) {
      final request = original['method'] == 'POST' ? key : storage;
      final route = (original['route'] as String).replaceAll('<file-id-40hex>', file);
      expect(request.url, '${evidence['observedOrigin']}$route');
      expect(request.method, original['method']);
      final network = defaults.prepareCefNetwork(request,
        options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: defaults.userAgent,
        context: NativeCefContext.fromLocale(selectedLocale: 'en', appleLanguages: const ['en-US']));
      final fields = {for (final header in network.headers) header.key.toLowerCase(): header.value};
      expect(fields['host'], original['authority']);
      if (request.method == 'POST') expect(fields['origin'], evidence['observedOrigin']);
    }
  });
}
