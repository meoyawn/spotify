import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import 'native_http_defaults.dart';
import 'native_oauth.dart';
import 'native_oauth_exchange.dart' show NativeOAuthProof, NativeOAuthSend;
import 'request_builder.dart';

/// The request operation's state interface from 0x101638254/0x101639160.
/// Persistence and the surrounding stored-session manager remain separate.
class NativeOAuthRefreshState {
  NativeOAuthRefreshState({required this.refreshToken, required this.dpopNonce});
  String refreshToken;
  String dpopNonce;
}

class NativeOAuthRefreshedToken {
  const NativeOAuthRefreshedToken({required this.accessToken, required this.tokenType,
    required this.expiresIn, required this.expiresAtMicroseconds});
  final String accessToken;
  final String tokenType;
  final int expiresIn;
  final int expiresAtMicroseconds;
}

enum NativeOAuthRefreshFailureReason {
  proofFailure, transport, httpStatus, credentialsRejected, invalidProof,
  invalidClient, missingNonce, nonceRetryExhausted, cancelled,
}

class NativeOAuthRefreshFailure implements Exception {
  const NativeOAuthRefreshFailure(this.code, this.reason, {this.httpStatus});
  final int code;
  final NativeOAuthRefreshFailureReason reason;
  final int? httpStatus;

  @override
  String toString() => 'Native OAuth refresh failed: ${reason.name} ($code)';
}

/// Identifies the native category named "http", rather than an arbitrary
/// exception with the same integer. 0x10163a654 maps its code 10
/// (http_error_aborted) to refresh failure 5. Other cancellations are not inferred.
class NativeOAuthRefreshHttpError implements Exception {
  const NativeOAuthRefreshHttpError(this.code);
  final int code;
}

/// Owns one actual send. Abort must release its transport work; the wrapper
/// makes repeated abort calls inert. No default or simulated abort is supplied.
class NativeOAuthRefreshOwnedSend {
  NativeOAuthRefreshOwnedSend({required this.response, required void Function() abort}) : _abortOwnedWork = abort;
  final Future<http.Response> response;
  final void Function() _abortOwnedWork;
  CancellationToken? _cancellation;
  void abort() {
    final token = _cancellation ??= CancellationToken();
    if (token.isCancelled) return;
    token.cancel(const NativeOAuthRefreshHttpError(10));
    _abortOwnedWork();
  }
}

typedef NativeOAuthRefreshSendOwner = NativeOAuthRefreshOwnedSend Function(RequestEnvelope request);

class NativeOAuthRefreshRun {
  NativeOAuthRefreshRun._();
  late final Future<NativeOAuthRefreshedToken> result;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  NativeOAuthRefreshOwnedSend? _activeSend;
  bool get isCancelled => _token.isCancelled;

  void cancel() {
    if (isCancelled) return;
    _token.cancel(const NativeOAuthRefreshFailure(5, NativeOAuthRefreshFailureReason.cancelled));
    _activeSend?.abort();
  }

  void _check() {
    // 0x10163891c cancels the owned request then publishes literal refresh 5.
    if (isCancelled) throw const NativeOAuthRefreshFailure(5, NativeOAuthRefreshFailureReason.cancelled);
  }

  Future<T> _wait<T>(Future<T> pending) async {
    final value = await pending.asCancellable(_token);
    _check();
    return value;
  }

  Future<http.Response> _send(RequestEnvelope request, NativeOAuthRefreshSendOwner sendOwned) async {
    _check();
    final owner = sendOwned(request.withCancellation(_token));
    _activeSend = owner;
    // Observe the response even if creating its owner raced cancellation. Late
    // successes and errors then have a consumer and cannot commit state.
    final pending = _wait(owner.response);
    try {
      if (isCancelled) owner.abort();
      return await pending;
    } finally {
      if (identical(_activeSend, owner)) _activeSend = null;
    }
  }
}

/// One explicit refresh operation from 0x1016382ec, 0x101638a68 and 0x101639160.
/// No background scheduling, token cache, account access or generic retry is
/// introduced. Each attempt snapshots the owner's current refresh token/nonce.
class NativeOAuthRefresh {
  NativeOAuthRefresh({required this.clientId, required this.state, required this.send,
    required this.nowMicroseconds, this.proof, Map<String, String> nativeHeaders = const {}})
    : _nativeHeaders = Map.unmodifiable(nativeHeaders);
  final String clientId;
  final NativeOAuthRefreshState state;
  final NativeOAuthSend send;
  final NativeOAuthProof? proof;
  final int Function() nowMicroseconds;
  final Map<String, String> _nativeHeaders;

  Future<NativeOAuthRefreshedToken> refresh() => _refresh();

  /// Reuses this operation's request/proof/state rules with a real send owner.
  /// The ordinary Future-only [send] is not invoked by this owned run.
  NativeOAuthRefreshRun startOwned({required NativeOAuthRefreshSendOwner sendOwned}) {
    final run = NativeOAuthRefreshRun._();
    run.result = _refresh(run: run, sendOwned: sendOwned);
    return run;
  }

  Future<NativeOAuthRefreshedToken> _refresh({NativeOAuthRefreshRun? run,
      NativeOAuthRefreshSendOwner? sendOwned}) async {
    var retryAvailable = true;
    while (true) {
      run?._check();
      final refreshToken = state.refreshToken;
      final nonce = state.dpopNonce;
      final headers = nativeHeaderOverrides(_nativeHeaders, {
        'Content-Type': 'application/x-www-form-urlencoded'});
      final provider = proof;
      if (provider != null) {
        final String? generated;
        try {
          final pending = provider(method: 'POST',
            url: 'https://accounts.spotify.com/api/token', nonce: nonce);
          generated = run == null ? await pending : await run._wait(pending);
        } catch (_) {
          run?._check();
          throw const NativeOAuthRefreshFailure(7, NativeOAuthRefreshFailureReason.proofFailure);
        }
        run?._check();
        if (generated == null) {
          throw const NativeOAuthRefreshFailure(7, NativeOAuthRefreshFailureReason.proofFailure);
        }
        // The native bulk-header insertion keeps an inherited CI-equivalent
        // value; Content-Type above uses a distinct replacing setter.
        headers.putIfAbsent('dpop', () => generated!);
      }
      final request = RequestEnvelope(method: 'POST', url: 'https://accounts.spotify.com/api/token',
        nativeTimeoutMilliseconds: 30000,
        headers: headers, authorize: false, body: utf8.encode(encodeNativeForm({
          'client_id': clientId, 'grant_type': 'refresh_token', 'refresh_token': refreshToken,
        })));
      final http.Response response;
      try {
        response = run == null ? await send(request) : await run._send(request, sendOwned!);
      } catch (error) {
        run?._check();
        throw NativeOAuthRefreshFailure(error is NativeOAuthRefreshHttpError && error.code == 10 ? 5 : 1,
          NativeOAuthRefreshFailureReason.transport);
      }
      run?._check();
      if (response.statusCode == 200) {
        final payload = _payload(response.bodyBytes);
        run?._check();
        if (payload.refreshToken.isNotEmpty) state.refreshToken = payload.refreshToken;
        final nonce = _nonceHeader(response.headers);
        run?._check();
        if (nonce != null) state.dpopNonce = nonce;
        final expiresAt = (BigInt.from(nowMicroseconds()) +
          BigInt.from(payload.expiresIn) * BigInt.from(1000000)).toSigned(64).toInt();
        run?._check();
        return NativeOAuthRefreshedToken(accessToken: payload.accessToken,
          tokenType: payload.tokenType, expiresIn: payload.expiresIn, expiresAtMicroseconds: expiresAt);
      }
      if (response.statusCode == 503) {
        throw const NativeOAuthRefreshFailure(4, NativeOAuthRefreshFailureReason.httpStatus, httpStatus: 503);
      }
      if (response.statusCode != 400) {
        throw NativeOAuthRefreshFailure(1, NativeOAuthRefreshFailureReason.httpStatus,
          httpStatus: response.statusCode);
      }
      final object = _object(response.bodyBytes).$2;
      final error = object.containsKey('error') ? _string(object, 'error') : '';
      switch (error) {
        case 'invalid_grant' || 'access_denied':
          throw const NativeOAuthRefreshFailure(2, NativeOAuthRefreshFailureReason.credentialsRejected,
            httpStatus: 400);
        case 'invalid_dpop_proof':
          throw const NativeOAuthRefreshFailure(7, NativeOAuthRefreshFailureReason.invalidProof, httpStatus: 400);
        case 'invalid_client':
          throw const NativeOAuthRefreshFailure(8, NativeOAuthRefreshFailureReason.invalidClient, httpStatus: 400);
        case 'use_dpop_nonce':
          final challenge = _nonceHeader(response.headers);
          if (challenge == null) {
            throw const NativeOAuthRefreshFailure(1, NativeOAuthRefreshFailureReason.missingNonce, httpStatus: 400);
          }
          run?._check();
          state.dpopNonce = challenge;
          if (!retryAvailable) {
            throw const NativeOAuthRefreshFailure(6, NativeOAuthRefreshFailureReason.nonceRetryExhausted,
              httpStatus: 400);
          }
          retryAvailable = false;
        default:
          throw const NativeOAuthRefreshFailure(1, NativeOAuthRefreshFailureReason.httpStatus, httpStatus: 400);
      }
    }
  }
}

String? _nonceHeader(Map<String, String> headers) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'dpop-nonce') return entry.value;
  }
  return null;
}

(String, Map<String, dynamic>) _object(Uint8List bytes) {
  final String source;
  final Object? decoded;
  try {
    source = utf8.decode(bytes);
    decoded = jsonDecode(source);
  } on FormatException {
    throw const FormatException('Invalid native OAuth refresh JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Native OAuth refresh response must be an object');
  }
  return (source, decoded);
}

String _string(Map<String, dynamic> object, String field) {
  final value = object[field];
  if (value is! String) throw FormatException('Invalid native OAuth refresh string field: $field');
  return value;
}

({String accessToken, String tokenType, String refreshToken, int expiresIn}) _payload(Uint8List bytes) {
  final (source, object) = _object(bytes);
  final accessToken = _string(object, 'access_token');
  final tokenType = _string(object, 'token_type');
  final refreshToken = object.containsKey('refresh_token') ? _string(object, 'refresh_token') : '';
  if (object['expires_in'] is! num) {
    throw const FormatException('Invalid native OAuth refresh numeric field: expires_in');
  }
  return (accessToken: accessToken, tokenType: tokenType, refreshToken: refreshToken,
    expiresIn: _nativeInt64(_rootNumber(source)!));
}

// This schema uses a distinct signed-int64 duration reader, not the code-grant
// int32 parser. Standard JSON validates syntax; retain the root numeric lexeme
// so decimal truncation cannot be changed by binary64 rounding.
String? _rootNumber(String source) {
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
      if (jsonDecode(source.substring(start, i + 1)) != 'expires_in') continue;
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

int _nativeInt64(String token) {
  final parts = RegExp(r'^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$').firstMatch(token)!;
  final fraction = parts.group(3) ?? '';
  var digits = '${parts.group(2)}$fraction'.replaceFirst(RegExp(r'^0+'), '');
  if (digits.isEmpty) return 0;
  final shift = BigInt.parse(parts.group(4) ?? '0') - BigInt.from(fraction.length);
  final length = BigInt.from(digits.length) + shift;
  if (length <= BigInt.zero) return 0;
  if (length > BigInt.from(19)) throw const FormatException('Native OAuth refresh expires_in integer overflow');
  digits = shift.isNegative ? digits.substring(0, length.toInt()) : digits.padRight(length.toInt(), '0');
  final magnitude = BigInt.parse(digits);
  final value = parts.group(1) == '-' ? -magnitude : magnitude;
  if (value < -(BigInt.one << 63) || value >= (BigInt.one << 63)) {
    throw const FormatException('Native OAuth refresh expires_in integer overflow');
  }
  return value.toInt();
}
