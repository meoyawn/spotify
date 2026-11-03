import 'dart:convert';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

/// Port of installed build 1.3.6.1921, embedded modules 41332 and 87337.
/// The output is the application request before native transport additions.
class RequestEnvelope {
  RequestEnvelope({
    required this.method,
    required this.url,
    required Map<String, String> headers,
    List<int> body = const [],
    this.authorize = true,
    this.includeCredentials = false,
    this.responseType = 'json',
    this.nativeTimeoutMilliseconds,
    this.cancellationToken,
  }) : headers = Map.unmodifiable(headers),
       body = Uint8List.fromList(body).asUnmodifiableView();

  final String method;
  final String url;
  final Map<String, String> headers;
  final Uint8List body;
  final bool authorize;
  final bool includeCredentials;
  final String responseType;

  /// Explicit native builder override (0x101c20378), before backend handling.
  /// Null inherits the native template; renderer construction does not set it.
  final int? nativeTimeoutMilliseconds;

  /// Local lifetime only. Never serialized into application protocol fields.
  final CancellationToken? cancellationToken;

  RequestEnvelope withCancellation(CancellationToken token) => RequestEnvelope(
    method: method, url: url, headers: headers, body: body, authorize: authorize,
    includeCredentials: includeCredentials, responseType: responseType,
    nativeTimeoutMilliseconds: nativeTimeoutMilliseconds,
    cancellationToken: cancellationToken == null ? token : cancellationToken!.merge(token));

  Map<String, Object?> toJson() => {
    'method': method,
    'url': url,
    'headers': headers,
    'bodyBase64': base64Encode(body),
    'authorize': authorize,
    'includeCredentials': includeCredentials,
    'responseType': responseType,
    if (nativeTimeoutMilliseconds != null) 'nativeTimeoutMilliseconds': nativeTimeoutMilliseconds,
  };
}

/// WHATWG application/x-www-form-urlencoded encoding used by URLSearchParams.
String encodeQuery(Map<String, Object?> values) => values.entries
    .map((entry) {
      String component(String value) => utf8.encode(value).map((byte) {
        if (byte >= 65 && byte <= 90 ||
            byte >= 97 && byte <= 122 ||
            byte >= 48 && byte <= 57 ||
            const [42, 45, 46, 95].contains(byte)) {
          return String.fromCharCode(byte);
        }
        if (byte == 32) return '+';
        return '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}';
      }).join();
      return '${component(entry.key)}=${component(jsString(entry.value))}';
    })
    .join('&');

String jsString(Object? value) {
  if (value == null) return 'null';
  if (value is String) return value;
  if (value is Map) return '[object Object]';
  if (value is List) {
    return value.map((v) => v == null ? '' : jsString(v)).join(',');
  }
  if (value is double && value == value.truncateToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

/// Preserves JavaScript object property order and integer JSON representation.
String jsJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList();
    int? index(String key) {
      final n = int.tryParse(key);
      return n != null && n >= 0 && n < 4294967295 && '$n' == key ? n : null;
    }

    final integerKeys = keys.where((k) => index(k) != null).toList()
      ..sort((a, b) => index(a)!.compareTo(index(b)!));
    final otherKeys = keys.where((k) => index(k) == null);
    return '{${[...integerKeys, ...otherKeys].map((k) => '${jsonEncode(k)}:${jsJson(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(jsJson).join(',')}]';
  if (value is double) {
    if (!value.isFinite) return 'null';
    if (value == 0) return '0';
    if (value == value.truncateToDouble() && value.abs() < 1e21) {
      return value.toInt().toString();
    }
  }
  return jsonEncode(value);
}

class SpotifyRequestBuilder {
  SpotifyRequestBuilder({
    this.accessToken,
    this.market = '',
    this.locale = '',
    this.globalHeaders = const {},
  });

  String? accessToken;
  String market;
  String locale;
  Map<String, String> globalHeaders;
  SpotifyRequest build() => SpotifyRequest(this);
}

class SpotifyRequest {
  SpotifyRequest(SpotifyRequestBuilder builder)
    : _token = builder.accessToken,
      _market = builder.market,
      _locale = builder.locale,
      _globals = {...builder.globalHeaders};
  final String? _token;
  final String _market;
  String _locale;
  final Map<String, String> _globals;
  String _host = '', _path = '', _method = 'GET', _responseType = 'json';
  bool _sendMarket = true,
      _sendLocale = false,
      _sendGlobals = true,
      _authorize = true,
      _json = false,
      _credentials = false;
  Map<String, Object?> _query = {};
  Map<String, String> _headers = {};
  Object? _body;
  CancellationToken? _cancellationToken;

  SpotifyRequest withCancellation(CancellationToken? token) {
    _cancellationToken = token;
    return this;
  }

  SpotifyRequest withHost(String value) {
    _host = value;
    return this;
  }

  SpotifyRequest withPath(String value) {
    _path = value;
    return this;
  }

  SpotifyRequest withMethod(String value) {
    _method = value;
    return this;
  }

  SpotifyRequest withResponseType(String value) {
    _responseType = value;
    return this;
  }

  SpotifyRequest withQueryParameters(Map<String, Object?> value) {
    _query = {...value};
    return this;
  }

  SpotifyRequest withBody(Object? value) {
    _body = value;
    return this;
  }

  SpotifyRequest withHeaders(Map<String, String> value) {
    _headers = {...value};
    return this;
  }

  SpotifyRequest withoutMarket() {
    _sendMarket = false;
    return this;
  }

  SpotifyRequest withoutGlobalHeaders() {
    _sendGlobals = false;
    return this;
  }

  SpotifyRequest withoutAuthorization() {
    _authorize = false;
    return this;
  }

  SpotifyRequest withLocale([String? value]) {
    _sendLocale = true;
    if (value != null && value.isNotEmpty) _locale = value;
    return this;
  }

  SpotifyRequest withJsonContentType() {
    _json = true;
    return this;
  }

  SpotifyRequest withCredentials() {
    _credentials = true;
    return this;
  }

  RequestEnvelope envelope() {
    final query = {..._query};
    if (_sendMarket && _market.isNotEmpty) query['market'] = _market;
    if (_sendLocale && _locale.isNotEmpty) query['locale'] = _locale;
    final headers = <String, String>{
      if (_locale.isNotEmpty) 'Accept-Language': _locale,
      if (_authorize && _token != null && _token.isNotEmpty)
        'Authorization': 'Bearer $_token',
      'Accept': 'application/json',
      if (_sendGlobals) ..._globals,
      ..._headers,
      if (_json) 'Content-Type': 'application/json;charset=UTF-8',
    };
    final encoded = encodeQuery(query);
    final value = _body;
    final truthy = value != null && value != false && value != 0 && value != '';
    final List<int> bytes;
    if (!truthy) {
      bytes = [];
    } else if (headers['Content-Type']?.startsWith(
          'application/json;charset=UTF-8',
        ) ??
        false) {
      bytes = utf8.encode(jsJson(value));
    } else if (value is String) {
      bytes = utf8.encode(value);
    } else if (value is List<int>) {
      bytes = value;
    } else {
      throw ArgumentError('Non-JSON bodies must already be strings or bytes');
    }
    return RequestEnvelope(
      method: _method,
      url: '$_host$_path${encoded.isEmpty ? '' : '?$encoded'}',
      headers: headers,
      body: bytes,
      authorize: _authorize,
      includeCredentials: _credentials,
      responseType: _responseType,
      cancellationToken: _cancellationToken,
    );
  }
}

RequestEnvelope persistedQuery(
  SpotifyRequestBuilder builder, {
  required String operationName,
  required String sha256Hash,
  required Map<String, Object?> variables,
  Map<String, Object?> query = const {},
}) => builder
    .build()
    .withHost('https://api-partner.spotify.com/pathfinder/v2')
    .withMethod('POST')
    .withoutMarket()
    .withPath('/query')
    .withJsonContentType()
    .withQueryParameters(query)
    .withBody({
      'variables': variables,
      'operationName': operationName,
      'extensions': {
        'persistedQuery': {'version': 1, 'sha256Hash': sha256Hash},
      },
    })
    .envelope();
