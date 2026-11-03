import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/dpop_key.dart';
import 'package:spotify_flutter/protocol/dpop_proof.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-dpop-proof.json')
    .readAsStringSync()) as Map<String, dynamic>;
  final keyFixture = fixture['standardKey'] as Map;
  final cases = fixture['cases'] as List;

  group('Original native proof assembly', () {
    for (final scenario in cases) {
      test(scenario['name'] as String, () {
        final claims = scenario['claims'] as Map;
        final generator = DpopProofGenerator(
          key: _OriginalCryptoFixture(scenario),
          clockSeconds: () => scenario['clockSeconds'] as int,
          entropySeed: () => scenario['entropySeed'] as int);
        expect(generator.createProof(method: claims['htm'] as String,
          url: claims['htu'] as String, nonce: claims['nonce'] as String?),
          scenario['proof']);
      });
    }
  });

  test('Imported and generated P-256 keys produce independently verifiable proofs', () async {
    final expected = cases.first as Map;
    final imported = P256DpopKey.fromPem(keyFixture['pkcs8Pem'] as String);
    final generated = P256DpopKey.generate();
    final proofs = <Map<String, Object>>[];
    for (var index = 0; index < 32; index++) {
      final key = index == 0 ? imported : generated;
      final generator = DpopProofGenerator(key: key,
        clockSeconds: () => expected['clockSeconds'] as int,
        entropySeed: () => expected['entropySeed'] as int);
      final proof = generator.createProof(method: 'POST', url: 'https://fixture.invalid/token');
      proofs.add({'proof': proof, 'keyThumbprint': generator.keyThumbprint});
      if (key == imported) {
        expect(proof.substring(0, proof.lastIndexOf('.')), expected['signingInput']);
      }
    }
    final original = proofs.first['proof'] as String;
    final parts = original.split('.');
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1])))) as Map;
    payload['htm'] = 'GET';
    parts[1] = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    proofs.add({'proof': parts.join('.'), 'keyThumbprint': proofs.first['keyThumbprint']!});
    final result = await _verify(proofs);
    expect(result.map((entry) => entry['valid']), [...List.filled(32, true), false]);
    expect(result.first['publicKeyHex'], expected['publicKeyHex']);
  });

  test('SEC1 import preserves key identity and other curves are rejected', () {
    final imported = P256DpopKey.fromPem(keyFixture['sec1Pem'] as String);
    expect(imported.publicKeyBytes, _hex(cases.first['publicKeyHex'] as String));
    expect(() => P256DpopKey.fromPem(keyFixture['wrongCurvePem'] as String),
      throwsFormatException);
    expect(() => P256DpopKey.fromPem(''), throwsFormatException);
  });
}

/// The original oracle executes all proof construction while standard crypto
/// uses this fixed public key/signature. The Dart port receives the same provider
/// results; production signing is independently verified in the following test.
class _OriginalCryptoFixture implements DpopSigningKey {
  _OriginalCryptoFixture(this.scenario);
  final Map scenario;

  @override
  Uint8List get publicKeyBytes => _hex(scenario['publicKeyHex'] as String);

  @override
  Uint8List signDigest(Uint8List digest) {
    expect(digest, sha256.convert(utf8.encode(scenario['signingInput'] as String)).bytes);
    return _hex(scenario['signatureHex'] as String);
  }
}

Uint8List _hex(String input) => Uint8List.fromList(List.generate(input.length ~/ 2,
  (index) => int.parse(input.substring(index * 2, index * 2 + 2), radix: 16)));

Future<List<dynamic>> _verify(List<Map<String, Object>> proofs) async {
  final process = await Process.start('uv', ['run', '--project', 'tools/oracles',
    '--locked', '--no-sync', 'python', 'test/support/verify_dpop.py']);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(jsonEncode(proofs));
  await process.stdin.close();
  expect(await process.exitCode, 0, reason: await errors);
  return jsonDecode(await output) as List;
}
