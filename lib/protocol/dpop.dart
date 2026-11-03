import 'dart:convert';

/// Encoded public-key fields supplied to the original native JWT serializer.
/// Key creation and the native crypto-provider lifecycle are separate concerns.
class DpopJwk {
  const DpopJwk({required this.curve, required this.keyType,
    required this.x, required this.y});
  final String curve;
  final String keyType;
  final String x;
  final String y;

  Map<String, Object?> _json() => {'crv': curve, 'kty': keyType, 'x': x, 'y': y};
}

class DpopHeader {
  const DpopHeader({required this.algorithm, required this.type, required this.jwk});
  final String algorithm;
  final String type;
  final DpopJwk jwk;

  Map<String, Object?> _json() => {'alg': algorithm, 'typ': type, 'jwk': jwk._json()};
}

class DpopClaims {
  const DpopClaims({required this.uri, required this.method,
    required this.jwtId, required this.issuedAt, this.nonce});
  final String uri;
  final String method;
  final String jwtId;
  final int issuedAt;
  final String? nonce;

  Map<String, Object?> _json() => {'htu': uri, 'htm': method,
    'jti': jwtId, 'iat': issuedAt, if (nonce != null) 'nonce': nonce};
}

/// JSON schemas 0x1017a258c/26f0/2a24 and signing-input assembly 0x1017a2cb8.
/// The caller supplies identity, clock, nonce, and key fields; nothing is signed.
String dpopSigningInput(DpopHeader header, DpopClaims claims) {
  String encode(Map<String, Object?> value) =>
    base64Url.encode(utf8.encode(_nativeJson(value))).replaceAll('=', '');
  return '${encode(header._json())}.${encode(claims._json())}';
}

String _nativeJson(Map<String, Object?> value) {
  final encoded = jsonEncode(value);
  final output = StringBuffer();
  for (var i = 0; i < encoded.length; i++) {
    final character = encoded.codeUnitAt(i);
    output.writeCharCode(character);
    if (character != 0x5c) continue;
    final escape = encoded.codeUnitAt(++i);
    output.writeCharCode(escape);
    if (escape == 0x75) {
      // The native writer uses uppercase hex only for actual Unicode escapes.
      output.write(encoded.substring(i + 1, i + 5).toUpperCase());
      i += 4;
    }
  }
  return output.toString();
}
