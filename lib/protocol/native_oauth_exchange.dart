import 'dart:convert';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:http/http.dart' as http;

import 'native_http_defaults.dart';
import 'native_oauth.dart';
import 'request_builder.dart';

typedef NativeOAuthSend = Future<http.Response> Function(RequestEnvelope request);
typedef NativeOAuthProof = Future<String?> Function({required String method,
  required String url, required String? nonce});

enum NativeOAuthFailureReason { proofUnavailable, httpStatus, accessDenied }

class NativeOAuthFailure implements Exception {
  const NativeOAuthFailure(this.code, this.reason, {this.httpStatus});
  final int code;
  final NativeOAuthFailureReason reason;
  final int? httpStatus;

  @override
  String toString() => 'Native OAuth exchange failed: ${reason.name} ($code)';
}

/// Response fields from 0x10166ec58 and expiry arithmetic from 0x10166f180.
/// The clock remains an injected native-clock value, expressed in microseconds.
class NativeOAuthTokenResponse {
  const NativeOAuthTokenResponse({required this.accessToken, required this.tokenType,
    required this.expiresIn, required this.expiresAtMicroseconds, required this.refreshToken,
    required this.scope, required this.username, this.idToken, this.issuedTokenType,
    this.dpopNonce = ''});
  final String accessToken;
  final String tokenType;
  final int expiresIn;
  final int expiresAtMicroseconds;
  final String refreshToken;
  final String scope;
  final String username;
  final String? idToken;
  final String? issuedTokenType;
  /// Original0x101672b8c retains the nonce challenge accepted by this grant.
  /// An ordinary successful grant has the original empty-string state.
  final String dpopNonce;
}

/// Authorization-code callbacks 0x1016724ac, 0x1016726e0 and 0x101672b8c.
/// There is no default sender, account access, credential persistence or retry
/// policy beyond the original single HTTP 400 DPoP nonce challenge.
class NativeOAuthExchange {
  NativeOAuthExchange({required this.send, required this.proof,
    required this.nowMicroseconds});
  final NativeOAuthSend send;
  final NativeOAuthProof proof;
  final int Function() nowMicroseconds;

  Future<NativeOAuthTokenResponse> exchangeAuthorizationCode({required String clientId,
      required String code, required String codeVerifier, required String redirectUri,
      Map<String, String> nativeHeaders = const {}, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final saved = nativeAuthorizationCodeTemplate(clientId: clientId, code: code,
      codeVerifier: codeVerifier, redirectUri: redirectUri,
      nativeHeaders: nativeHeaders);
    String? nonce;
    var retryAvailable = true;
    while (true) {
      cancellationToken?.throwIfCancelled();
      final String? generated;
      try {
        generated = await proof(method: saved.method, url: saved.url, nonce: nonce).asCancellable(cancellationToken);
      } on CancelledException { rethrow; } catch (_) {
        cancellationToken?.throwIfCancelled();
        throw const NativeOAuthFailure(104, NativeOAuthFailureReason.proofUnavailable);
      }
      if (generated == null) {
        throw const NativeOAuthFailure(104, NativeOAuthFailureReason.proofUnavailable);
      }
      final request = RequestEnvelope(method: saved.method, url: saved.url,
        headers: nativeHeaderInsertions(saved.headers, {'dpop': generated}), body: saved.body,
        authorize: saved.authorize, includeCredentials: saved.includeCredentials,
        responseType: saved.responseType, nativeTimeoutMilliseconds: saved.nativeTimeoutMilliseconds,
        cancellationToken: cancellationToken);
      cancellationToken?.throwIfCancelled();
      final response = await send(request).asCancellable(cancellationToken);
      cancellationToken?.throwIfCancelled();
      if (response.statusCode == 200) {
        return _decodeToken(response.bodyBytes, nowMicroseconds, nonce ?? '');
      }
      final error = response.statusCode == 400 ? _backendError(response.bodyBytes) : null;
      if (response.statusCode == 400 && error == 'use_dpop_nonce' && retryAvailable) {
        final challenge = _nonceHeader(response.headers);
        if (challenge != null) {
          nonce = challenge;
          retryAvailable = false;
          continue;
        }
      }
      if (response.statusCode == 400 && error == 'access_denied') {
        throw const NativeOAuthFailure(15, NativeOAuthFailureReason.accessDenied, httpStatus: 400);
      }
      final nativeCode = switch (response.statusCode) {
        400 => 108, 401 => 107, 403 => 105, 408 || 504 => 109, 429 => 110, _ => 106,
      };
      throw NativeOAuthFailure(nativeCode, NativeOAuthFailureReason.httpStatus,
        httpStatus: response.statusCode);
    }
  }
}

String? _backendError(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic> && decoded['error'] is String) {
      return decoded['error'] as String;
    }
  } on FormatException {
    // A malformed error document does not replace the original HTTP mapping.
  }
  return null;
}

String? _nonceHeader(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'dpop-nonce') return entry.value;
  }
  return null;
}

NativeOAuthTokenResponse _decodeToken(Uint8List bytes, int Function() nowMicroseconds, String dpopNonce) {
  final String source;
  final Object? decoded;
  try {
    source = utf8.decode(bytes);
    decoded = jsonDecode(source);
  } on FormatException {
    throw const FormatException('Invalid native OAuth token JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Native OAuth token response must be an object');
  }
  final object = decoded;
  String string(String field) {
    final value = object[field];
    if (value is! String) throw FormatException('Invalid native OAuth string field: $field');
    return value;
  }
  String? optionalString(String field) => object.containsKey(field) ? string(field) : null;
  final accessToken = string('access_token');
  final tokenType = string('token_type');
  final refreshToken = string('refresh_token');
  final username = string('username');
  final scope = object.containsKey('scope') ? string('scope') : '';
  final idToken = optionalString('id_token');
  final issuedTokenType = optionalString('issued_token_type');
  if (object['expires_in'] is! num) {
    throw const FormatException('Invalid native OAuth numeric field: expires_in');
  }
  final expiresIn = _nativeInt32(_rootNumber(source, 'expires_in')!);
  return NativeOAuthTokenResponse(accessToken: accessToken, tokenType: tokenType,
    refreshToken: refreshToken, username: username, scope: scope, idToken: idToken,
    issuedTokenType: issuedTokenType, expiresIn: expiresIn,
    expiresAtMicroseconds: nowMicroseconds() + expiresIn * 1000000, dpopNonce: dpopNonce);
}

// Standard JSON decoding validates the document first. Only the root numeric
// lexeme is retained here, avoiding binary64 rounding before native truncation.
String? _rootNumber(String source, String field) {
  var depth = 0;
  String? result;
  final number = RegExp(r'-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?');
  bool whitespace(int index) => ' \t\r\n'.contains(source[index]);
  for (var i = 0; i < source.length; i++) {
    final code = source.codeUnitAt(i);
    if (code == 0x22) {
      final start = i;
      while (++i < source.length) {
        if (source.codeUnitAt(i) == 0x5c) { i++; continue; }
        if (source.codeUnitAt(i) == 0x22) break;
      }
      if (depth != 1) continue;
      var next = i + 1;
      while (next < source.length && whitespace(next)) { next++; }
      if (next == source.length || source[next] != ':') continue;
      if (jsonDecode(source.substring(start, i + 1)) != field) continue;
      while (++next < source.length && whitespace(next)) {}
      result = number.matchAsPrefix(source, next)?.group(0);
    } else if (code == 0x7b || code == 0x5b) {
      depth++;
    } else if (code == 0x7d || code == 0x5d) {
      depth--;
    }
  }
  return result;
}

// Original callback 0x10166f924 truncates decimal/exponent input toward zero
// and rejects values outside signed int32. It does not first round to a double.
int _nativeInt32(String token) {
  final parts = RegExp(r'^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$').firstMatch(token)!;
  final fraction = parts.group(3) ?? '';
  var digits = '${parts.group(2)}$fraction'.replaceFirst(RegExp(r'^0+'), '');
  if (digits.isEmpty) return 0;
  final shift = BigInt.parse(parts.group(4) ?? '0') - BigInt.from(fraction.length);
  final length = BigInt.from(digits.length) + shift;
  if (length <= BigInt.zero) return 0;
  if (length > BigInt.from(10)) throw const FormatException('Native OAuth expires_in integer overflow');
  digits = shift.isNegative ? digits.substring(0, length.toInt()) : digits.padRight(length.toInt(), '0');
  final value = int.parse(digits) * (parts.group(1) == '-' ? -1 : 1);
  if (value < -2147483648 || value > 2147483647) {
    throw const FormatException('Native OAuth expires_in integer overflow');
  }
  return value;
}
