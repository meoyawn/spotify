import 'dart:convert';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:crypto/crypto.dart';

import 'desktop_identity.dart';
import 'dpop_proof.dart';
import 'native_oauth_exchange.dart';

/// Original PKCE producer 0x1017a6224. Standard secure entropy and SHA-256
/// supply the primitives; the encoded verifier itself is the hash input.
class NativeAccountsPkce {
  const NativeAccountsPkce._(this.verifier, this.challenge);
  final String verifier, challenge;
  String get method => 'S256';

  factory NativeAccountsPkce.generate() {
    final random = Random.secure();
    return NativeAccountsPkce.fromEntropy(List.generate(32, (_) => random.nextInt(256)));
  }

  factory NativeAccountsPkce.fromEntropy(List<int> bytes) {
    if (bytes.length != 32 || bytes.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('Native Accounts PKCE requires 32 entropy bytes');
    }
    String encode(List<int> value) => base64Url.encode(value).replaceAll('=', '');
    final verifier = encode(bytes);
    return NativeAccountsPkce._(verifier, encode(sha256.convert(ascii.encode(verifier)).bytes));
  }
}

/// Campaign fields passed by the original desktop Accounts owner. Presence of
/// msclkid is distinct from its value; a present empty string is serialized.
class NativeAccountsCampaign {
  const NativeAccountsCampaign({this.source = 'spotify', this.medium = 'desktop-macos',
    this.campaign = 'organic', this.referral = '', this.msclkid});
  final String source, medium, campaign, referral;
  final String? msclkid;

  List<MapEntry<String, String>> get _fields => [
    MapEntry('utm_source', source), MapEntry('utm_medium', medium),
    MapEntry('utm_campaign', campaign),
    if (referral.isNotEmpty) MapEntry('referral', referral),
    if (msclkid != null) MapEntry('msclkid', msclkid!),
  ];
}

/// Primary desktop URL owner 0x101673dd8, called by URI task 0x101670628.
/// Produces the exact browser URL without opening a browser or sending HTTP.
class NativeDesktopAccountsAuthorization {
  NativeDesktopAccountsAuthorization({this.clientId = DesktopIdentity.accountsClientId,
    this.scopes = DesktopIdentity.accountsScopes, int Function()? nowSeconds})
    : _nowSeconds = nowSeconds ?? _wallClockSeconds;

  final String clientId;
  final List<String> scopes;
  final int Function() _nowSeconds;

  String url({required NativeAccountsPkce pkce, required String redirectUri,
    required String dpopThumbprint, NativeAccountsCampaign campaign = const NativeAccountsCampaign(),
    String flow = 'login-accounts', bool signUp = false, String flowContext = ''}) {
    MapEntry<String, String> context() => MapEntry('flow_ctx',
      '$flowContext:${_nowSeconds() + 21600}');
    final authorization = _append('https://accounts.spotify.com/oauth2/v2/auth', [
      MapEntry('client_id', clientId), const MapEntry('response_type', 'code'),
      MapEntry('redirect_uri', redirectUri), MapEntry('scope', scopes.join(',')),
      MapEntry('code_challenge_method', pkce.method), MapEntry('code_challenge', pkce.challenge),
      if (flowContext.isNotEmpty) context(),
      MapEntry('dpop_jkt', dpopThumbprint), ...campaign._fields,
    ]);
    final primary = signUp ? _append('https://www.spotify.com/signup', [
      MapEntry('forward_url', authorization), if (flow.isNotEmpty) MapEntry('flow', flow),
    ]) : authorization;
    final creationPoint = _append('https://login.app.spotify.com/', [
      MapEntry('client_id', clientId), ...campaign._fields,
    ]);
    return _append(primary, [
      const MapEntry('creation_flow', 'desktop'), MapEntry('creation_point', creationPoint),
      if (flowContext.isNotEmpty) context(),
    ]);
  }
}

/// Owns one primary authorization attempt's PKCE and DPoP identity in Dart.
/// The caller owns browser/callback-server delivery and the supplied sender.
/// Creating an attempt sends nothing; receiving its callback starts the
/// original authorization-code exchange with this same signing key.
class NativeDesktopAccountsLogin {
  NativeDesktopAccountsLogin({required this.send, required this.proofs,
    required this.nowMicroseconds, NativeDesktopAccountsAuthorization? authorization,
    this.nativeHeaders = const {}})
    : authorization = authorization ?? NativeDesktopAccountsAuthorization();

  final NativeOAuthSend send;
  final DpopProofGenerator proofs;
  final int Function() nowMicroseconds;
  final NativeDesktopAccountsAuthorization authorization;
  final Map<String, String> nativeHeaders;

  NativeAccountsLoginAttempt begin({required String redirectUri,
    NativeAccountsCampaign campaign = const NativeAccountsCampaign(),
    String flow = 'login-accounts', bool signUp = false, String flowContext = ''}) {
    final pkce = NativeAccountsPkce.generate();
    return NativeAccountsLoginAttempt._(
      authorization.url(pkce: pkce, redirectUri: redirectUri,
        dpopThumbprint: proofs.keyThumbprint, campaign: campaign,
        flow: flow, signUp: signUp, flowContext: flowContext),
      NativeAccountsRedirectExchange(pkce: pkce, redirectUri: redirectUri,
        clientId: authorization.clientId, nativeHeaders: nativeHeaders,
        exchange: NativeOAuthExchange(send: send, nowMicroseconds: nowMicroseconds,
          proof: ({required method, required url, required nonce}) async =>
            proofs.createProof(method: method, url: url, nonce: nonce))));
  }
}

class NativeAccountsLoginAttempt {
  NativeAccountsLoginAttempt._(this.authorizationUrl, this._redirect);
  final String authorizationUrl;
  final NativeAccountsRedirectExchange _redirect;
  Future<NativeOAuthTokenResponse>? _result;

  Future<NativeOAuthTokenResponse> complete(String callbackUrl, {CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    return _result ??= _redirect.complete(callbackUrl, cancellationToken: cancellationToken);
  }
}

class NativeAccountsRedirectFailure implements Exception {
  const NativeAccountsRedirectFailure(this.code);
  final int code;
  @override
  String toString() => 'Native Accounts redirect failed ($code)';
}

/// Original callback0x101670c9c forwards the first raw code member. Its query
/// lookup0x101f54d20 does not percent-decode, translate '+', or strip '#'.
/// The native form encoder escapes this raw value when producing the POST.
class NativeAccountsRedirectExchange {
  const NativeAccountsRedirectExchange({required this.pkce, required this.redirectUri,
    required this.exchange, this.clientId = DesktopIdentity.accountsClientId,
    this.nativeHeaders = const {}});
  final NativeAccountsPkce pkce;
  final String redirectUri, clientId;
  final NativeOAuthExchange exchange;
  final Map<String, String> nativeHeaders;

  Future<NativeOAuthTokenResponse> complete(String callbackUrl, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final question = callbackUrl.indexOf('?');
    String? code;
    if (question >= 0) {
      for (final member in callbackUrl.substring(question + 1).split('&')) {
        final equals = member.indexOf('=');
        final key = equals < 0 ? member : member.substring(0, equals);
        if (key != 'code') continue;
        code = equals < 0 ? '' : member.substring(equals + 1);
        break;
      }
    }
    if (code == null || code.isEmpty) throw const NativeAccountsRedirectFailure(108);
    return exchange.exchangeAuthorizationCode(clientId: clientId, code: code,
      codeVerifier: pkce.verifier, redirectUri: redirectUri, nativeHeaders: nativeHeaders,
      cancellationToken: cancellationToken);
  }
}

String _append(String base, List<MapEntry<String, String>> fields) {
  String encode(String value) => Uri.encodeQueryComponent(value).replaceAll('+', '%20');
  return '$base${base.contains('?') ? '&' : '?'}${fields.map(
    (field) => '${encode(field.key)}=${encode(field.value)}').join('&')}';
}

int _wallClockSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
