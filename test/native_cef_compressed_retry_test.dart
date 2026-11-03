import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_cef_context.dart';
import 'package:spotify_flutter/protocol/native_cef_http_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_http2_transport.dart';
import 'package:spotify_flutter/protocol/native_cef_request.dart';
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/native_oauth_exchange.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void main() {
  test('compressed OAuth nonce JSON produces exact original retry headers and form bytes over H1 and H2', () async {
    Map fixture(String name) => jsonDecode(File('reverse-engineering/fixtures/$name.json').readAsStringSync()) as Map;
    final form = (fixture('native-form')['cases'] as List).singleWhere((row) => row['name'] == 'authorization code') as Map;
    final fields = (form['fields'] as Map).cast<String, String>();
    final originalBody = utf8.encode(form['body'] as String);
    final proofs = (fixture('native-dpop-proof')['cases'] as List).take(2).map((row) => row['proof'] as String).toList();
    final h1 = (fixture('native-cef-template-loopback')['profiles'] as List).first as Map;
    final h2 = fixture('native-cef-h2-loopback');
    final template = fixture('native-oauth-refresh')['template'] as Map;
    final originalTarget = (template['url'] as String).substring('https://accounts.spotify.com'.length);
    final peer = await Process.start('uv', ['run', '--project', 'tools/oracles', '--locked', '--no-sync',
      'python', 'test/support/native_cef_compressed_retry_peer.py']);
    final errors = peer.stderr.transform(utf8.decoder).join();
    final output = StreamIterator(peer.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    try {
      expect(await output.moveNext().timeout(const Duration(seconds: 15)), isTrue);
      final ready = jsonDecode(output.current) as Map;
      final authority = 'localhost:${ready['port']}', origin = 'https://$authority';
      final trust = SecurityContext(withTrustedRoots: false)..setTrustedCertificates(ready['certificate'] as String);
      final native = h1['nativeOptions'] as Map;
      final context = NativeCefContext.fromLocale(selectedLocale: native['selectedLocale'] as String,
        appleLanguages: (native['suppliedAppleLanguages'] as List).cast<String>());
      final sourceH1 = (h1['cases'] as List).singleWhere((row) => (row['name'] as String).contains('OAuth')) as Map;
      final sourceH2 = (h2['cases'] as List).singleWhere((row) => (row['name'] as String).contains('OAuth')) as Map;
      final userAgent = sourceH1['input']['adapterUserAgent'] as String;
      for (final protocol in ['http/1.1', 'h2']) {
        for (final encoding in ['gzip', 'deflate', 'br', 'zstd', if (protocol == 'http/1.1') 'deflate-raw']) {
          peer.stdin.writeln(jsonEncode({'encoding': encoding}));
          expect(await output.moveNext().timeout(const Duration(seconds: 5)), isTrue);
          final sendH1 = NativeCefHttpTransport(defaults: const NativeHttpDefaults(userAgent: ''),
            options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: userAgent,
            context: context, securityContext: trust);
          final sendH2 = NativeCefHttp2Transport(defaults: const NativeHttpDefaults(userAgent: ''),
            options: NativeCefOptions(adapterOption80: 0), adapterUserAgent: userAgent,
            context: context, securityContext: trust);
          try {
            final service = NativeOAuthExchange(nowMicroseconds: () => 0,
              proof: ({required method, required url, required nonce}) async => proofs[nonce == null ? 0 : 1],
              send: (request) {
                final local = RequestEnvelope(method: request.method, url: '$origin$originalTarget',
                  headers: request.headers, body: request.body);
                return protocol == 'http/1.1' ? sendH1.send(local) : sendH2.send(local);
              });
            await service.exchangeAuthorizationCode(clientId: fields['client_id']!, code: fields['code']!,
              codeVerifier: fields['code_verifier']!, redirectUri: fields['redirect_uri']!)
              .timeout(const Duration(seconds: 10));
            for (var attempt = 0; attempt < 2; attempt++) {
              expect(await output.moveNext().timeout(const Duration(seconds: 5)), isTrue);
              final capture = (jsonDecode(output.current) as Map)['capture'] as Map;
              final source = protocol == 'http/1.1' ? sourceH1 : sourceH2;
              final expectedHeaders = [for (final pair in source['result']['headers'] as List)
                [pair[0], switch ((pair[0] as String).toLowerCase()) {
                  'host' || ':authority' => authority, 'origin' => origin,
                  ':path' => originalTarget, 'content-length' => '${originalBody.length}',
                  'dpop' => proofs[attempt], _ => pair[1],
                }]];
              expect({'headers': capture['headers'], 'bodyBase64': capture['bodyBase64']},
                {'headers': expectedHeaders, 'bodyBase64': base64Encode(originalBody)},
                reason: '$protocol $encoding outgoing attempt ${attempt + 1}');
              if (protocol == 'http/1.1') {
                expect([capture['method'], capture['rawTarget']], [template['method'], originalTarget]);
              }
            }
          } finally { sendH1.close(); sendH2.close(); }
        }
      }
    } finally {
      peer.stdin.writeln('stop');
      await peer.stdin.close();
      expect(await peer.exitCode.timeout(const Duration(seconds: 10)), 0, reason: await errors);
      await output.cancel();
    }
  });
}
