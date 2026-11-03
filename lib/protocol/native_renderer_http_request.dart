import 'dart:convert';
import 'dart:typed_data';

import 'request_builder.dart';

/// The renderer profile observed in original 1.3.6.1921 Pathfinder HTTP requests.
/// Explicit locale and credentials are application inputs. These are decoded
/// HTTP fields. Original NetLog sends and their joined HTTP3_HEADERS_SENT
/// blocks establish ordering; CDP maps separately establish field values.
class NativeRendererSearchProfile {
  const NativeRendererSearchProfile({required this.locale,
    this.endpoint = 'https://api-partner.spotify.com/pathfinder/v2/query'});

  final String locale;
  final String endpoint;
  static const origin = 'https://xpui.app.spotify.com';
  static const userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.7922.138 '
    'Spotify/1.3.6.1921 Safari/537.36';
  static const globalHeaders = {'App-Platform': 'OSX_ARM64', 'Spotify-App-Version': '1.3.6.1921'};

  NativeRendererHttpRequestPlan prepareSearch(RequestEnvelope request,
      {required String clientToken}) {
    final target = Uri.tryParse(endpoint);
    final loopback = target != null && const {'localhost', '127.0.0.1'}.contains(target.host);
    if (target == null || target.scheme != 'https' || target.userInfo.isNotEmpty ||
        target.hasFragment || target.hasQuery || target.path != '/pathfinder/v2/query' ||
        (!loopback && endpoint != 'https://api-partner.spotify.com/pathfinder/v2/query') ||
        request.url != endpoint || request.method != 'POST' || !request.authorize ||
        request.includeCredentials || request.responseType != 'json') {
      throw UnsupportedError('Renderer Search requires the captured HTTPS Pathfinder POST endpoint and fetch options');
    }
    final payload = jsonDecode(utf8.decode(request.body));
    const operationHashes = {
      'searchSuggestions': 'f244254b94c0e824d458ac216e0f8406a73f2f69a9ff52831a2f78fa774ff6ce',
      'recentSearches': 'ece96d7b82c820fb9938dd1df50dee3e53737d808c3883e3d01c467c423601b0',
      // Original full-page/category/history producers and shared fetch:
      // reverse-engineering/fixtures/native-renderer-full-search.json.
      'searchDesktop': 'eef7cc54888d91bdd6802623477873caa3948ae173a0c34fd86827b267e94c03',
      'searchTracks': 'b02683192a98dde7966b5e6655a79eeb62713eab703eda9902c932818dd52751',
      'searchAlbums': '202cb3305e31e5a0767ba7925f28bd728cf8f8b0217e6da43909056071cd70e9',
      'searchArtists': '7bf95d754fdbe32c8b161fbbe54d1ae50974900df4dce4c8f1afcbcad153224d',
      'searchPlaylists': 'd520014e748f9ea44f7707d8df1819867ac1205e8b7f3e28f22fe5fc858921b1',
      'searchPodcasts': '0195d9f61b43606d490bca64c3456e3593528cea6cc05c7e822c7c42beed0f4e',
      'searchFullEpisodes': '397a4e93a21d140d088cfd26641133c5146a2f5f08e420654868153e720f5571',
      'searchAudiobooks': 'e05ac765d02c084f8783d3c1572b23d57761c43f47eb8b87ce2f9ccced3fa068',
      'searchAuthors': '4a9d403a7cbc7e19da5520d619a865472b35382b043bfa458154e73a5c6f46bd',
      'searchGenres': '9e1c0e056c46239dd1956ea915b988913c87c04ce3dadccdb537774490266f46',
      'searchUsers': '8f358dd82e62f61dd4ceaa9f8cd0889e644c9b707f1b724fbfb356a757cb7e5a',
      'saveRecentSearches': 'ece96d7b82c820fb9938dd1df50dee3e53737d808c3883e3d01c467c423601b0',
      'removeRecentSearches': 'ece96d7b82c820fb9938dd1df50dee3e53737d808c3883e3d01c467c423601b0',
      // Original provider36922 -> descriptor65250 -> shared loader/fetch:
      // reverse-engineering/fixtures/native-renderer-home.json, native-home-netlog.json.
      'home': '5fb7da7a03ee2776c0670856609cb85a189a3cecc36cc160b91cde79063b9cf1',
      // Original drilldown/Browse producers and shared fetch boundary:
      // reverse-engineering/fixtures/native-renderer-home-destinations.json.
      'homeSection': '5fb7da7a03ee2776c0670856609cb85a189a3cecc36cc160b91cde79063b9cf1',
      'browsePage': 'f5c4e6d668f5716464a231c1cc8b22c1cbf6ad68b09929fd7de813a30581298b',
      'browseSection': 'b13c1cccbfcb6947753c2613411b3566485c21fd5f36d80a80bb64be61ba2d51',
      // Independent original modal producer + loader capture:
      // reverse-engineering/fixtures/search-modal-original.json. Fetch header context stays
      // the separately captured renderer Search profile above.
      'searchModalResults': '9a79751378a306d87d9789fa0c4a8f7c7213891c47a3993a0d0b58ff26514e59',
      // Original album producers + module50278 header normalization/fetch:
      // reverse-engineering/fixtures/native-renderer-album.json.
      'getAlbum': '11c9cad9cb24c4f9e25ef9456f68621cfd6006a90f679e729c1d2f2fd70dfe16',
      'queryAlbumTracks': '11c9cad9cb24c4f9e25ef9456f68621cfd6006a90f679e729c1d2f2fd70dfe16',
      // Original artist producers and shared loader/header normalization:
      // reverse-engineering/evidence/native-renderer-artist.json.
      'queryArtistOverview': '9f8134ef565e78621f1e1793555bd6633c5ac144ae0f89604ed3ae3f80b3c8e6',
      'getArtistNameAndTracks': '0adaf1a1a8a94c7ed095639c4d9456d2b1cfac16ac511d5dd2b01b6dd89f748a',
      'queryArtistDiscographyOverview': '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599',
      'queryArtistDiscographyAlbums': '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599',
      'queryArtistDiscographySingles': '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599',
      'queryArtistDiscographyCompilations': '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599',
      'queryArtistDiscographyAll': '5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599',
      'queryArtistRelated': '3d031d6cb22a2aa7c8d203d49b49df731f58b1e2799cc38d9876d58771aa66f3',
      'queryArtistAppearsOn': '9a4bb7a20d6720fe52d7b47bc001cfa91940ddf5e7113761460b4a288d18a4c1',
      'queryArtistFeaturing': '20842d6d9d2d28ef945984b68cb927bb33edd00eab84a8da1667def21f1f2c54',
      'queryArtistDiscoveredOn': '71c2392e4cecf6b48b9ad1311ae08838cbdabcfd189c6bf0c66c2430b8dcfdb1',
    };
    if (payload is! Map || !operationHashes.containsKey(payload['operationName']) ||
        payload['extensions'] is! Map || payload['extensions']['persistedQuery'] is! Map ||
        payload['extensions']['persistedQuery']['version'] != 1 ||
        payload['extensions']['persistedQuery']['sha256Hash'] !=
          operationHashes[payload['operationName']]) {
      throw UnsupportedError('Renderer request profile covers the verified desktop Pathfinder operations only');
    }
    final numericVersion = const {'getAlbum', 'queryArtistOverview'}.contains(payload['operationName']);
    final headers = <String, String>{};
    for (final entry in request.headers.entries) {
      final key = entry.key.toLowerCase();
      // Original transport HeaderCollection J lowercases keys, ignores empty
      // inputs and overwrites with the last truthy value. Admit precisely the
      // original album/artist overview case-variant version override here.
      final versionOverride = numericVersion && key == 'spotify-app-version' &&
        headers[key] == '1.3.6.1921' && entry.value == '896000000';
      if ((headers.containsKey(key) && !versionOverride) || !_field(entry.value)) {
        throw const FormatException('Invalid or duplicate renderer request header');
      }
      if (entry.value.isNotEmpty) headers[key] = entry.value;
    }
    const names = {'accept-language', 'authorization', 'accept', 'app-platform',
      'spotify-app-version', 'content-type'};
    if (headers.length != names.length || !headers.keys.every(names.contains) ||
        !_field(locale) || locale.isEmpty || headers['accept-language'] != locale ||
        !(headers['authorization'] ?? '').startsWith('Bearer ') ||
        headers['authorization']!.length <= 7 || headers['accept'] != 'application/json' ||
        headers['app-platform'] != 'OSX_ARM64' ||
        headers['spotify-app-version'] != (numericVersion ? '896000000' : '1.3.6.1921') ||
        headers['content-type'] != 'application/json;charset=UTF-8' ||
        clientToken.isEmpty || !_field(clientToken)) {
      throw UnsupportedError('Renderer Search requires explicit original locale, global fields and both credentials');
    }
    return NativeRendererHttpRequestPlan._(url: endpoint, authority: target.authority,
      rawTarget: '/pathfinder/v2/query', body: request.body, headers: Map.unmodifiable({
        // All80 original H3 POSTs and14 H2 POSTs agree on this sequence.
        // Keep its ownership here so both transports use identical fields.
        'content-length': '${request.body.length}',
        'origin': origin,
        'user-agent': userAgent,
        'accept': headers['accept']!,
        'accept-language': headers['accept-language']!,
        'app-platform': headers['app-platform']!,
        'authorization': headers['authorization']!,
        'client-token': clientToken,
        'content-type': headers['content-type']!,
        'sec-ch-ua': '"Chromium";v="151", "Not=A?Brand";v="99"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"macOS"',
        'spotify-app-version': headers['spotify-app-version']!,
        'sec-fetch-site': 'same-site',
        'sec-fetch-mode': 'cors',
        'sec-fetch-dest': 'empty',
        'referer': '$origin/',
        'accept-encoding': 'gzip, deflate, br, zstd',
        'priority': 'u=1, i',
      }));
  }

  /// Original module68900 GETs; original NetLog owns the browser field order.
  /// See reverse-engineering/fixtures/native-renderer-lyrics.json.
  NativeRendererHttpRequestPlan prepareLyrics(RequestEnvelope request, {required String clientToken}) {
    final target = Uri.parse(request.url);
    final availability = RegExp(r'^/metadata/4/track/[0-9a-f]{32}$').hasMatch(target.path);
    final lyrics = RegExp(r'^/color-lyrics/v2/track/[0-9A-Za-z]{22}/image/.+$').hasMatch(target.path);
    final query = target.queryParameters;
    if (target.scheme != 'https' || target.host != 'spclient.wg.spotify.com' ||
        target.hasPort || target.hasFragment || target.userInfo.isNotEmpty ||
        (!availability && !lyrics) || request.method != 'GET' || request.body.isNotEmpty ||
        !request.authorize || request.includeCredentials || request.responseType != 'json' ||
        query['market'] != 'from_token' ||
        (availability ? query.length != 1 : query['format'] != 'json' || query['vocalRemoval'] != 'false' ||
          query.keys.any((key) => !const {'market', 'format', 'vocalRemoval', 'clientLanguage'}.contains(key)))) {
      throw UnsupportedError('Renderer lyrics requires the verified metadata/lyrics GET contract');
    }
    final fields = {for (final entry in request.headers.entries) entry.key.toLowerCase(): entry.value};
    if (fields.length != 5 || request.headers.length != fields.length ||
        fields['accept-language'] != locale || locale.isEmpty || !_field(locale) ||
        fields['accept'] != 'application/json' || fields['app-platform'] != 'OSX_ARM64' ||
        fields['spotify-app-version'] != '1.3.6.1921' ||
        !(fields['authorization'] ?? '').startsWith('Bearer ') ||
        fields['authorization']!.length <= 7 || !fields.values.every(_field) ||
        clientToken.isEmpty || !_field(clientToken)) {
      throw UnsupportedError('Renderer lyrics requires the original locale, global fields and credentials');
    }
    return NativeRendererHttpRequestPlan._(method: 'GET', url: request.url, authority: target.authority,
      rawTarget: '${target.path}?${target.query}', body: request.body, headers: Map.unmodifiable({
        'origin': origin, 'user-agent': userAgent,
        'accept': fields['accept']!, 'accept-language': locale,
        'app-platform': fields['app-platform']!, 'authorization': fields['authorization']!,
        'client-token': clientToken,
        'sec-ch-ua': '"Chromium";v="151", "Not=A?Brand";v="99"',
        'sec-ch-ua-mobile': '?0', 'sec-ch-ua-platform': '"macOS"',
        'spotify-app-version': fields['spotify-app-version']!,
        'sec-fetch-site': 'same-site', 'sec-fetch-mode': 'cors', 'sec-fetch-dest': 'empty',
        'referer': '$origin/', 'accept-encoding': 'gzip, deflate, br, zstd', 'priority': 'u=1, i',
      }));
  }

  /// Original browser preflight context. Its language is browser-managed;
  /// the subsequent POST carries the explicitly supplied application locale.
  NativeRendererHttpRequestPlan preparePreflight(NativeRendererHttpRequestPlan request) {
    if (request.method != 'POST' && request.method != 'GET') {
      throw UnsupportedError('Renderer preflight requires a prepared renderer request');
    }
    return NativeRendererHttpRequestPlan._(method: 'OPTIONS', url: request.url,
      authority: request.authority, rawTarget: request.rawTarget, body: Uint8List(0),
      headers: Map.unmodifiable({
        'accept': '*/*', 'access-control-request-method': request.method,
        'access-control-request-headers': preflightHeaderNames(request).join(','),
        'origin': origin, 'user-agent': userAgent,
        'sec-fetch-mode': 'cors', 'sec-fetch-site': 'same-site', 'sec-fetch-dest': 'empty',
        'referer': '$origin/', 'accept-encoding': 'gzip, deflate, br, zstd',
        'accept-language': 'en-US,en;q=0.9', 'priority': 'u=1, i',
      }));
  }

  List<String> preflightHeaderNames(NativeRendererHttpRequestPlan request) {
    // The original CORS input already includes client-token. Browser-managed
    // Origin/UA/hints/fetch fields are excluded from the author's unsafe list.
    final names = ['app-platform', 'authorization', 'client-token',
      if (request.headers.containsKey('content-type')) 'content-type', 'spotify-app-version'];
    final language = request.headers['accept-language']!;
    if (language.length > 128 || !RegExp(r'^[0-9A-Za-z *,.\-;=]*$').hasMatch(language)) {
      names.add('accept-language');
    }
    return names..sort();
  }
}

class NativeRendererHttpRequestPlan {
  NativeRendererHttpRequestPlan._({required this.url, required this.authority,
    required this.rawTarget, required this.headers, required this.body, this.method = 'POST'});
  final String method, url, authority, rawTarget;
  final Map<String, String> headers;
  final Uint8List body;
}

bool _field(String value) => value.codeUnits.every((code) => code >= 0x20 && code <= 0x7e) &&
  value == value.trim();
