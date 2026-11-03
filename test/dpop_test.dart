import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/dpop.dart';

void main() {
  group('Original native DPoP serialization', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-dpop.json')
      .readAsStringSync()) as Map<String, dynamic>;
    for (final scenario in fixture['cases'] as List) {
      test(scenario['name'] as String, () {
        final header = scenario['header'] as Map;
        final jwk = header['jwk'] as Map;
        final claims = scenario['claims'] as Map;
        final encoded = dpopSigningInput(DpopHeader(
          algorithm: header['alg'] as String, type: header['typ'] as String,
          jwk: DpopJwk(curve: jwk['crv'] as String, keyType: jwk['kty'] as String,
            x: jwk['x'] as String, y: jwk['y'] as String)),
          DpopClaims(uri: claims['htu'] as String, method: claims['htm'] as String,
            jwtId: claims['jti'] as String, issuedAt: claims['iat'] as int,
            nonce: claims['nonce'] as String?));
        expect(encoded, scenario['signingInput']);
      });
    }
  });
}
