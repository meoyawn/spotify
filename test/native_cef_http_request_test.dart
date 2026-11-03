import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_cef_context.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_cef_http_transport.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('native CEF context and HTTPS outgoing fields match original producers and shipped peer captures', () async {
    final locale = jsonDecode(File('reverse-engineering/fixtures/native-cef-locales.json').readAsStringSync()) as Map;
    for (final item in locale['expansions'] as List) {
      expect(NativeCefContext.expandPreferredLocale(item['input'] as String), item['expanded'],
        reason: 'original locale expansion ${item['input']}');
    }
    for (final item in locale['languageLists'] as List) {
      final context = NativeCefContext.fromLocale(selectedLocale: item['selectedLocale'] as String,
        appleLanguages: (item['appleLanguages'] as List).cast<String>());
      expect(context.preferredLocales, item['preferredLocales']);
      expect(context.acceptLanguageList, item['acceptLanguageList'], reason: '$item');
    }
    for (final item in locale['defaultSelections'] as List) {
      final context = NativeCefContext.fromPreferences(
        appleLanguages: (item['appleLanguages'] as List).cast<String>(),
        supportedLocales: (item['supportedLocales'] as List).cast<String>(),
        excludedLocales: (item['excludedLocales'] as List).cast<String>());
      expect(context.selectedLocale, item['selectedLocale'], reason: '$item');
      expect(context.acceptLanguageList, item['acceptLanguageList'], reason: '$item');
    }
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles',
      '--locked', '--no-sync', 'python', 'test/support/native_cef_dart_peer.py', '--keepalive']);
    final errors = peer.stderr.transform(utf8.decoder).join();
    final lines = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    NativeCefHttpTransport? transport;
    NativeCefHttpConnectionPool? pool;
    final getSockets = <int>{};
    var crossedIdleWindow = false;
    try {
    expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    final local = jsonDecode(lines.current) as Map;
    final security = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(local['certificate'] as String);
    pool = NativeCefHttpConnectionPool(securityContext: security);
    for (final fixturePath in ['reverse-engineering/fixtures/native-cef-language-loopback.json',
        'reverse-engineering/fixtures/native-cef-template-loopback.json']) {
      final fixture = jsonDecode(File(fixturePath).readAsStringSync()) as Map;
      for (final profile in fixture['profiles'] as List) {
      final native = profile['nativeOptions'] as Map;
      final context = NativeCefContext.fromLocale(selectedLocale: native['selectedLocale'] as String,
        appleLanguages: (native['suppliedAppleLanguages'] as List).cast<String>());
      expect(context.acceptLanguageList, native['acceptLanguageList']);
      expect(context.requestContextSettings.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        native['requestContextSettingsHex']);
      for (final captured in profile['cases'] as List) {
        final input = captured['input'] as Map, expected = captured['result'] as Map;
        final originalUrl = input['url'] as String;
        final originalOrigin = RegExp(r'^https://[^/]+').firstMatch(originalUrl)!.group(0)!;
        // Only the ephemeral loopback authority changes. Target and payload
        // spelling remain the independently captured original inputs.
        final url = '${local['origin']}${originalUrl.substring(originalOrigin.length)}';
        final request = RequestEnvelope(method: input['method'] as String, url: url,
          headers: {for (final pair in input['headers'] as List) pair[0] as String: pair[1] as String},
          body: base64Decode(input['bodyBase64'] as String));
        transport?.close();
        transport = NativeCefHttpTransport(defaults: const NativeHttpDefaults(userAgent: ''),
          options: NativeCefOptions(adapterOption80: input['adapterOption80'] as int),
          adapterUserAgent: input['adapterUserAgent'] as String, context: context,
          securityContext: security, pool: pool);
        final response = await transport.send(request).timeout(const Duration(seconds: 10));
        expect(response.statusCode, 200);
        peer.stdin.writeln('capture');
        expect(await lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final wire = jsonDecode(lines.current) as Map;
        if (request.method == 'GET' && request.body.isEmpty) getSockets.add(wire['socketId'] as int);
        final expectedHeaders = [for (final pair in expected['headers'] as List)
          [pair[0], switch ((pair[0] as String).toLowerCase()) {
            'host' => (local['origin'] as String).substring(8),
            'origin' => local['origin'], _ => pair[1],
          }]];
        expect({'method': wire['method'], 'rawTarget': wire['rawTarget'],
          'version': wire['version'], 'headers': wire['headers'], 'bodyBase64': wire['bodyBase64']},
          {'method': expected['method'], 'rawTarget': expected['rawTarget'],
            'version': 'HTTP/1.1', 'headers': expectedHeaders, 'bodyBase64': expected['bodyBase64']},
          reason: 'actual Dart TLS request: ${captured['name']}');
        final originalWire = latin1.decode(base64Decode(expected['rawRequestBase64'] as String));
        final boundary = originalWire.indexOf('\r\n\r\n');
        final originalLines = originalWire.substring(0, boundary).split('\r\n');
        final expectedWire = [for (final line in originalLines)
          if (line.startsWith('Host: ')) 'Host: ${(local['origin'] as String).substring(8)}'
          else if (line.startsWith('Origin: ')) 'Origin: ${local['origin']}'
          else line].join('\r\n') + originalWire.substring(boundary);
        expect(base64Decode(wire['rawRequestBase64'] as String), latin1.encode(expectedWire),
          reason: 'complete original HTTP/1.1 bytes: ${captured['name']}');
        if (!crossedIdleWindow && request.method == 'GET' && request.body.isEmpty) {
          crossedIdleWindow = true;
          transport.close();
          // The captured Chromium151 used-socket default is300s. Cross Dart's
          // unrelated15s default before the next exact outgoing request.
          await Future<void>.delayed(const Duration(seconds: 16));
        }
      }
      }
    }
    // The independent peer must observe the bodyless GET field plans on one
    // persistent socket, including after adapter close and a16s idle gap.
    expect(getSockets.length, 1);
    } finally {
      transport?.close();
      pool?.close();
      peer.stdin.writeln('stop');
      await peer.stdin.close();
      expect(await peer.exitCode.timeout(const Duration(seconds: 10)), 0, reason: await errors);
      await lines.cancel();
    }
  });
}
