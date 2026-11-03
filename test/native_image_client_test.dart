import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_image_client.dart';
import 'package:spotify_flutter/protocol/native_image_request.dart' show nativeImagePublicUrlAllowed;

void main() {
  test('Artwork GET sends every original H2 field and exact empty body to independent peer', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-image-request.json').readAsStringSync()) as Map;
    final additional = jsonDecode(File('reverse-engineering/fixtures/native-image-extra-cdns.json').readAsStringSync()) as Map;
    final generated = jsonDecode(File('reverse-engineering/fixtures/native-image-generated-covers.json').readAsStringSync()) as Map;
    final cases = [...generated['cases'] as List, ...fixture['cases'] as List, ...(additional['cases'] as List)
      .where((item) => item['expected']['protocol'] == 'h2')];
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/native_cef_h2_peer.py']);
    final errors = <String>[];
    final stderr = peer.stderr.transform(utf8.decoder).listen(errors.add);
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final clients = <String, NativeImageClient>{};
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map, authority = 'localhost:${ready['port']}';
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ready['certificate'] as String);
      final expectedByPath = <String, Map>{};
      final loads = Future.wait([
        for (final item in cases) () {
          expect(nativeImagePublicUrlAllowed(item['rawUrl'] as String), isTrue);
          final expectedHeaders = (item['expected']['headers'] as Map).cast<String, String>();
          expectedByPath['${expectedHeaders[':path']}\n${expectedHeaders['priority']}'] = item as Map;
          final client = clients.putIfAbsent('${item['acceptLanguage']}/${item['priority']}',
            () => NativeImageClient(acceptLanguage: item['acceptLanguage'] as String,
              priority: item['priority'] == 'normal' ? NativeImagePriority.normal : NativeImagePriority.promoted,
              securityContext: trust));
          return client.load('https://$authority${expectedHeaders[':path']}');
        }(),
      ]);
      for (var index = 0; index < cases.length; index++) {
        expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final actual = (jsonDecode(output.current) as Map)['capture'] as Map, pairs = actual['headers'] as List;
        final fields = {for (final pair in pairs) pair[0] as String: pair[1] as String};
        final item = expectedByPath.remove('${fields[':path']}\n${fields['priority']}');
        expect(item, isNotNull);
        if (item == null) continue;
        final expected = item['expected'] as Map, expectedHeaders = (expected['headers'] as Map).cast<String, String>();
        expect(fields.length, pairs.length, reason: 'No duplicate is hidden by map conversion');
        expect(actual['alpn'], expected['protocol']);
        expect(fields, {...expectedHeaders, ':authority': authority}, reason: item['name'] as String);
        expect(actual['bodyBase64'], expected['bodyBase64'], reason: item['name'] as String);
      }
      await loads;
    } finally {
      for (final client in clients.values) { client.close(); }
      peer.stdin.writeln('stop'); await peer.stdin.close(); await output.cancel();
      await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () { peer.kill(); return -1; });
      await stderr.cancel(); expect(errors, isEmpty);
    }
  });

  test('Mosaic artwork GET sends original HTTP1 fields raw target and empty body', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-image-extra-cdns.json').readAsStringSync()) as Map;
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/native_cef_dart_peer.py']);
    final stderr = peer.stderr.transform(utf8.decoder).join();
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    NativeImageClient? client;
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map, origin = ready['origin'] as String;
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ready['certificate'] as String);
      for (final item in (fixture['cases'] as List).where((item) => item['expected']['protocol'] == 'http/1.1')) {
        expect(nativeImagePublicUrlAllowed(item['rawUrl'] as String), isTrue);
        client?.close();
        client = NativeImageClient(acceptLanguage: item['acceptLanguage'] as String, securityContext: trust);
        await client.load('$origin${item['rawTarget']}');
        peer.stdin.writeln('capture');
        expect(await output.moveNext().timeout(const Duration(seconds: 10)), isTrue);
        final actual = jsonDecode(output.current) as Map, pairs = actual['headers'] as List;
        final fields = {for (final pair in pairs) (pair[0] as String).toLowerCase(): pair[1] as String};
        expect(fields.length, pairs.length);
        expect(fields, {...(item['expected']['headers'] as Map), 'host': origin.substring(8)},
          reason: item['name'] as String);
        expect(actual['method'], 'GET');
        expect(actual['version'], 'HTTP/1.1');
        expect(actual['rawTarget'], item['rawTarget']);
        expect(actual['bodyBase64'], '');
      }
    } finally {
      client?.close();
      peer.stdin.writeln('stop'); await peer.stdin.close(); await output.cancel();
      await peer.exitCode.timeout(const Duration(seconds: 10), onTimeout: () { peer.kill(); return -1; });
      expect(await stderr, isEmpty);
    }
  });
}
