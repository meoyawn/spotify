/// URL fields from original interactive Accounts owner 0x1003031ac, mode 2.
/// The owner supplies the real client/scope/PKCE/redirect inputs. This class
/// neither chooses an authentication mode nor opens a browser or sends HTTP.
class NativeAccountsAuthorization {
  const NativeAccountsAuthorization({required this.clientId, required this.scope,
    required this.codeChallenge, required this.redirectUri});
  final String clientId, scope, codeChallenge, redirectUri;

  /// Original query-vector order is retained. Values remain length-bearing;
  /// an explicitly empty id-token hint is still an included query member.
  String consentUrl({required String idTokenHint}) {
    final fields = <MapEntry<String, String>>[
      MapEntry('client_id', clientId),
      const MapEntry('response_type', 'code'),
      MapEntry('scope', scope),
      MapEntry('code_challenge', codeChallenge),
      const MapEntry('code_challenge_method', 'S256'),
      MapEntry('redirect_uri', redirectUri),
      MapEntry('id_token_hint', idTokenHint),
      const MapEntry('nolinks', 'true'),
      const MapEntry('nosignout', 'true'),
      const MapEntry('prompt', 'consent'),
    ];
    String encode(String value) => Uri.encodeQueryComponent(value).replaceAll('+', '%20');
    return 'https://accounts.spotify.com/oauth2/v2/auth?${fields.map(
      (field) => '${encode(field.key)}=${encode(field.value)}').join('&')}';
  }
}
