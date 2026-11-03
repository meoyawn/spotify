import 'dart:convert';

import 'native_http_defaults.dart';
import 'request_builder.dart';

/// The native encoder (0x101f553dc) uses RFC 3986 unreserved characters and
/// replaces spaces with '+'. Unlike the renderer it escapes '*' and keeps '~'.
/// The original std::map serializer (0x10167d228) orders keys by UTF-8 bytes.
String encodeNativeForm(Map<String, String> fields) {
  final entries = fields.entries.map((entry) =>
    (entry.key, entry.value, utf8.encode(entry.key))).toList();
  entries.sort((a, b) {
    final left = a.$3;
    final right = b.$3;
    for (var i = 0; i < left.length && i < right.length; i++) {
      final comparison = left[i].compareTo(right[i]);
      if (comparison != 0) return comparison;
    }
    return left.length.compareTo(right.length);
  });
  return entries.map((entry) =>
    '${Uri.encodeQueryComponent(entry.$1)}=${Uri.encodeQueryComponent(entry.$2)}').join('&');
}

/// Application-level construction from 0x101671540 and 0x1016721e0.
/// The caller supplies the original DPoP proof and native HTTP defaults;
/// neither authentication identity nor transport defaults are fabricated here.
RequestEnvelope nativeAuthorizationCodeRequest({required String clientId,
    required String code, required String codeVerifier, required String redirectUri,
    required String dpopProof, Map<String, String> nativeHeaders = const {}}) {
  final template = nativeAuthorizationCodeTemplate(clientId: clientId, code: code,
    codeVerifier: codeVerifier, redirectUri: redirectUri, nativeHeaders: nativeHeaders);
  return RequestEnvelope(method: template.method, url: template.url, authorize: false,
    nativeTimeoutMilliseconds: template.nativeTimeoutMilliseconds,
    cancellationToken: template.cancellationToken,
    headers: nativeHeaderInsertions(template.headers, {'dpop': dpopProof}), body: template.body);
}

/// The native saved template precedes proof generation and contains no added
/// DPoP placeholder. Each attempt inserts its proof into a fresh template copy.
RequestEnvelope nativeAuthorizationCodeTemplate({required String clientId,
    required String code, required String codeVerifier, required String redirectUri,
    Map<String, String> nativeHeaders = const {}}) =>
  RequestEnvelope(method: 'POST', url: 'https://accounts.spotify.com/api/token', authorize: false,
    nativeTimeoutMilliseconds: 30000,
    headers: nativeHeaderOverrides(nativeHeaders, {
      'Content-Type': 'application/x-www-form-urlencoded'}),
    body: utf8.encode(encodeNativeForm({
      'client_id': clientId, 'grant_type': 'authorization_code', 'code': code,
      'code_verifier': codeVerifier, 'redirect_uri': redirectUri,
    })));
