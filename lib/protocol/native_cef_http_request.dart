import 'dart:collection';
import 'dart:typed_data';

import 'native_cef_context.dart';
import 'native_cef_request.dart';
import 'native_cef_request_object.dart';
import 'native_http_defaults.dart';
import 'request_builder.dart';

/// HTTPS HTTP/1.1 application fields after the captured native CEF context.
/// A pure projection: it never creates a transport or enables remote requests.
class NativeCefHttpRequestPlan {
  NativeCefHttpRequestPlan._({required this.method, required this.url,
    required this.rawTarget, required this.headers, required this.body});

  factory NativeCefHttpRequestPlan.fromObject(NativeCefRequestObjectPlan input,
      {required NativeCefContext context}) {
    final match = RegExp(r'^https://([^/?#]+)([^#]*)(?:#.*)?$').firstMatch(input.url);
    if (match == null || input.flags != 0xd0) {
      throw UnsupportedError('CEF final-field projection requires the captured HTTPS native flags');
    }
    final body = input.body ?? Uint8List(0);
    final upload = input.method == 'POST' || input.method == 'PUT';
    if ((!upload && input.method != 'GET') || upload != body.isNotEmpty) {
      throw UnsupportedError('CEF final-field projection requires a captured GET or bytes-upload method');
    }
    final values = LinkedHashMap<String, String>(
      equals: (left, right) => _lower(left) == _lower(right),
      hashCode: (value) => _lower(value).hashCode);
    for (final header in input.headers) {
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(header.key) ||
          header.value.contains(RegExp(r'[\r\n\x00]'))) {
        throw const FormatException('Invalid HTTP header input');
      }
      values[header.key] = header.value.replaceAll(RegExp(r'^[ \t]+|[ \t]+$'), '');
    }
    const automatic = {'host', 'connection', 'content-length', 'pragma', 'origin',
      'accept-language', 'sec-fetch-site', 'sec-fetch-mode', 'sec-fetch-dest',
      'cookie', 'cookie2', 'proxy-authorization'};
    // The original adapter + shipped CEF preserve the native application
    // language on unrelated paths too. Service-specific request contracts
    // belong to their producers; remote admission remains with each sender.
    final nativeAppLanguage = _nativeAppLanguage(values);
    if (values.keys.any((key) => automatic.contains(_lower(key)) &&
        !(_lower(key) == 'accept-language' && nativeAppLanguage))) {
      throw UnsupportedError('Explicit browser-managed header overrides need a separate original capture');
    }
    final cache = values['Cache-Control'];
    if (cache != null && cache != 'no-cache' && cache != 'no-cache, no-store' &&
        cache != 'no-cache, no-store, max-age=0') {
      throw UnsupportedError('CEF final-field projection requires an absent or captured native cache policy');
    }
    // Public pinned BrowserURLRequest supplies this type for a single bytes
    // element. Independent original/CEF execution proves both insertion when
    // absent and replacement in the existing position when explicitly empty.
    if (upload && (values['Content-Type'] ?? '').isEmpty) {
      values['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    if ((values['User-Agent'] ?? '').isEmpty ||
        (values.containsKey('Accept-Encoding') && values['Accept-Encoding'] != '')) {
      throw UnsupportedError('CEF final-field projection requires explicit UA and captured encoding policy');
    }
    final origin = 'https://${match[1]}';
    final headers = <MapEntry<String, String>>[
      MapEntry('Host', match[1]!), const MapEntry('Connection', 'keep-alive'),
      if (upload) MapEntry('Content-Length', body.length.toString()),
      if (cache != null) ...[const MapEntry('Pragma', 'no-cache'), MapEntry('Cache-Control', cache)],
      ...values.entries.where((entry) => _lower(entry.key) != 'cache-control'),
      if (upload) MapEntry('Origin', origin),
      if (!values.containsKey('Accept-Language'))
        MapEntry('Accept-Language', context.acceptLanguageHeader),
      const MapEntry('Sec-Fetch-Site', 'same-origin'),
      const MapEntry('Sec-Fetch-Mode', 'no-cors'),
      const MapEntry('Sec-Fetch-Dest', 'empty'),
      if (!values.containsKey('Accept-Encoding'))
        const MapEntry('Accept-Encoding', 'gzip, deflate, br, zstd'),
    ];
    return NativeCefHttpRequestPlan._(method: input.method, url: input.url,
      rawTarget: match[2]!.isEmpty ? '/' : match[2]!, headers: List.unmodifiable(headers),
      body: body);
  }

  final String method, url, rawTarget;
  final List<MapEntry<String, String>> headers;
  final Uint8List body;
}

extension NativeCefHttpDefaults on NativeHttpDefaults {
  NativeCefHttpRequestPlan prepareCefNetwork(RequestEnvelope request,
      {required NativeCefOptions options, required String adapterUserAgent,
      required NativeCefContext context}) =>
    NativeCefHttpRequestPlan.fromObject(prepareCefObject(request,
      options: options, adapterUserAgent: adapterUserAgent), context: context);
}

String _lower(String value) => String.fromCharCodes(value.codeUnits.map(
  (code) => code >= 65 && code <= 90 ? code + 32 : code));

bool _nativeAppLanguage(Map<String, String> headers) =>
  (headers['Accept-Language'] ?? '').isNotEmpty && headers['app-platform'] == 'OSX_ARM64' &&
  headers['spotify-app-version'] == '130601921' && (headers['time-zone'] ?? '').isNotEmpty &&
  (headers['User-Agent'] ?? '').startsWith('Spotify/130601921 OSX_ARM64/OS X ');
