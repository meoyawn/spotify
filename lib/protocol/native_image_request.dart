/// Forward image URI conversion is original renderer71646 export m. Native
/// image identities are20 octets, formatted as lowercase hex without resizing.
String nativeImageUrlForId(List<int> fileId20,
    {String template = 'https://i.scdn.co/image/{file_id}'}) {
  if (fileId20.length != 20 || fileId20.any((byte) => byte < 0 || byte > 255)) {
    throw ArgumentError('An image identity must contain20 octets');
  }
  return template.replaceAll('{file_id}',
    fileId20.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join());
}

/// The two image priority field values present in original renderer captures.
enum NativeImagePriority { normal, promoted }

/// Shared public artwork/cache admission. Loopback is deliberately excluded;
/// the request planner separately admits the same paths for local wire checks.
bool nativeImagePublicUrlAllowed(String rawUrl) {
  final match = RegExp(r'^https://([^/?#]+)(/[^?#]*)$').firstMatch(rawUrl);
  return match != null && _publicImageRoute(match[1]!, match[2]!) != null;
}

String? _publicImageRoute(String host, String path) {
  if (const {'i.scdn.co', 'image-cdn-fa.spotifycdn.com', 'image-cdn-ak.spotifycdn.com'}.contains(host) &&
      RegExp(r'^/image/[0-9a-f]{40}$').hasMatch(path)) { return 'h2'; }
  if (host == 'pickasso.spotifycdn.com' && _pickassoPath.hasMatch(path)) return 'h2';
  if (host == 'seed-mix-image.spotifycdn.com' && _seedMixPath.hasMatch(path)) return 'h2';
  if (host == 'mosaic.scdn.co' && _mosaicPath.hasMatch(path)) return 'http/1.1';
  return null;
}

// Original renderer URL execution plus the captured Pickasso field context:
// reverse-engineering/fixtures/native-image-generated-covers.json.
({String source, RegExp expression})? _pickassoPatternCache;
RegExp get _pickassoPath {
  const source = r'^/image/ab67c0de(?:0000deef/dt/v1/img/(?:(?:(?:radio/(?:track|artist)|thisisv3|artistmix|topic/(?:ambient|nineties|metal|techno|rock|chill|twenty_twenties|twenty_tens|focus|seventies|eighties))/[A-Za-z0-9]{22}|daily/[1-6]/(?:[A-Za-z0-9]{22}|[0-9a-f]{40})|dw/(?:cover|desktop|mobile))/en|release-radar-header/(?:desktop|mobile))|0000bada/dt/v1/img/release-radar-v4/[A-Za-z0-9]{22}/en)$';
  final cached = _pickassoPatternCache;
  if (cached?.source == source) return cached!.expression;
  final expression = RegExp(source);
  _pickassoPatternCache = (source: source, expression: expression);
  return expression;
}
final _seedMixPath = RegExp(r'^/v6/img/desc/(?:[A-Za-z0-9._~-]|%[0-9A-Fa-f]{2})+/en/(?:default|small|large|xlarge)$');
final _mosaicPath = RegExp(r'^/(?:60|300|640)/(?:[0-9a-f]{40}){4}$');

/// Public artwork GET fields observed in original Spotify 1.3.6.1921 arm64.
/// Decoded field values/presence are proved; CDP does not prove wire ordering.
class NativeImageRequestPlan {
  NativeImageRequestPlan._({required this.url, required this.authority,
    required this.rawTarget, required this.headers, required this.protocol});

  factory NativeImageRequestPlan.fromUrl(String rawUrl,
      {required String acceptLanguage, NativeImagePriority priority = NativeImagePriority.normal}) {
    final match = RegExp(r'^https://([^/?#]+)(/[^?#]*)$').firstMatch(rawUrl);
    String? protocol;
    if (match != null) {
      protocol = _publicImageRoute(match[1]!, match[2]!);
      if (protocol == null && RegExp(r'^(?:localhost|127\.0\.0\.1)(?::[0-9]{1,5})?$').hasMatch(match[1]!)) {
        protocol = _mosaicPath.hasMatch(match[2]!) ? 'http/1.1' :
          RegExp(r'^/image/[0-9a-f]{40}$').hasMatch(match[2]!) ||
          _pickassoPath.hasMatch(match[2]!) || _seedMixPath.hasMatch(match[2]!) ? 'h2' : null;
      }
    }
    if (match == null || protocol == null) {
      throw UnsupportedError('Artwork URL is outside the originally captured HTTPS image routes');
    }
    if (acceptLanguage.isEmpty || acceptLanguage != acceptLanguage.trim() ||
        acceptLanguage.codeUnits.any((code) => code < 0x20 || code > 0x7e)) {
      throw const FormatException('Artwork requires an explicit browser Accept-Language field');
    }
    return NativeImageRequestPlan._(url: rawUrl, authority: match[1]!, rawTarget: match[2]!, protocol: protocol,
      headers: Map.unmodifiable({
        'accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
        'accept-encoding': 'gzip, deflate, br, zstd',
        'accept-language': acceptLanguage,
        if (protocol == 'h2') 'priority': priority == NativeImagePriority.normal ? 'i' : 'u=1, i',
        'referer': 'https://xpui.app.spotify.com/',
        'sec-ch-ua': '"Chromium";v="151", "Not=A?Brand";v="99"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"macOS"',
        'sec-fetch-dest': 'image',
        'sec-fetch-mode': 'no-cors',
        'sec-fetch-site': 'cross-site',
        'sec-fetch-storage-access': 'active',
        'user-agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.7922.138 '
          'Spotify/1.3.6.1921 Safari/537.36',
      }));
  }

  final String url, authority, rawTarget, protocol;
  final Map<String, String> headers;
}
