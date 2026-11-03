import 'package:convert/convert.dart' show hex;

import '../protocol/generated/extended_metadata.pb.dart' as metadata;
import '../protocol/native_http_defaults.dart';
import '../protocol/native_protobuf.dart';
import '../protocol/request_builder.dart';

/// Native media request construction recovered with REA from Spotify macOS
/// 1.3.6.1921: metadata 0x100611ecc, storage 0x100780440 and CDN 0x10075cff8.
/// This is an application-field boundary, without a sender or retry policy.
class SpotifyRequests {
  SpotifyRequests({required String baseUrl, required Map<String, String> inheritedHeaders,
    required this.defaults}) : _baseUrl = _origin(baseUrl),
      _inheritedHeaders = Map.unmodifiable(nativeHeaderInsertions(inheritedHeaders, const {})) {
    for (final entry in _inheritedHeaders.entries) {
      _headerValue(entry.key, 'header name');
      _headerValue(entry.value, 'header value', allowEmpty: true);
    }
    _headerValue(defaults.userAgent, 'defaults.userAgent');
  }

  final String _baseUrl;
  // The request template's auth/context owner is a separate native boundary.
  // No authentication header is inferred from the librespot implementation.
  final Map<String, String> _inheritedHeaders;
  final NativeHttpDefaults defaults;

  RequestEnvelope extendedMetadata(metadata.BatchedEntityRequest request) =>
    _native('POST', '/extended-metadata/v0/extended-metadata',
      body: nativeProto3Bytes(request), headers: const {
        'Content-Type': 'application/protobuf', 'Accept': 'application/protobuf'});

  RequestEnvelope storageResolve(List<int> fileId20, {required int storageMode,
    required int audioFormat, String partner = ''}) {
    if (fileId20.length != 20 || fileId20.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('fileId20 must contain exactly 20 octets');
    }
    RangeError.checkValueInInterval(storageMode, -0x80000000, 0x7fffffff, 'storageMode');
    RangeError.checkValueInInterval(audioFormat, -0x80000000, 0x7fffffff, 'audioFormat');
    final mode = storageMode == 1 ? 'offline' : storageMode == 2 ? 'interactive_prefetch' : 'interactive';
    // Original concatenation does not URL-encode the optional partner value.
    final suffix = partner.isEmpty ? '' : '&partner=$partner';
    return _native('GET',
      '/storage-resolve/v2/files/audio/$mode/$audioFormat/${hex.encode(fileId20)}?product=0$suffix',
      headers: const {'cache-control': 'no-cache'});
  }

  /// The backend-provided URL retains its spelling. The public inclusive range
  /// maps to the native owner's signed int32 end-exclusive interval. Native
  /// whole-file requests omit Range above the zero-start cutoff. Optional
  /// playback identity/timestamp come from the caller; none is synthesized.
  /// This uses an isolated GET template and the explicit User-Agent policy.
  RequestEnvelope signedCdnRange({required String signedUrl, required int firstByte,
    required int lastByte, List<int>? playbackId16, int? segmentTimestampMilliseconds}) {
    _httpsUrl(signedUrl, 'signedUrl');
    if (firstByte < 0 || lastByte < firstByte) {
      throw RangeError('The inclusive CDN range must satisfy 0 <= firstByte <= lastByte');
    }
    RangeError.checkValueInInterval(lastByte, 0, 0x7ffffffe, 'lastByte');
    if (playbackId16 != null && (playbackId16.length != 16 ||
        playbackId16.any((byte) => byte < 0 || byte > 255))) {
      throw ArgumentError('playbackId16 must contain exactly 16 octets');
    }
    if (segmentTimestampMilliseconds != null) {
      RangeError.checkValueInInterval(segmentTimestampMilliseconds,
        -0x8000000000000000, 0x7fffffffffffffff, 'segmentTimestampMilliseconds');
    }
    final endExclusive = lastByte + 1;
    return defaults.prepare(RequestEnvelope(method: 'GET', url: signedUrl,
      headers: {'Accept-Encoding': '', 'Cache-Control': 'no-cache, no-store',
        if (playbackId16 != null) 'x-playback-id': hex.encode(playbackId16),
        if (segmentTimestampMilliseconds != null)
          'x-segment-timestamp-ms': '$segmentTimestampMilliseconds',
        if (firstByte != 0 || endExclusive <= 0x7fffbffe) 'Range': 'bytes=$firstByte-$lastByte'}, authorize: false,
      includeCredentials: false, responseType: 'bytes'));
  }

  RequestEnvelope _native(String method, String path,
    {List<int> body = const [], Map<String, String> headers = const {}}) {
    return defaults.prepare(RequestEnvelope(method: method, url: '$_baseUrl$path',
      headers: nativeHeaderOverrides(_inheritedHeaders, headers), body: body,
      authorize: false, includeCredentials: false, responseType: 'bytes'));
  }
}

String _origin(String value) {
  final uri = _httpsUrl(value, 'baseUrl');
  if (uri.query.isNotEmpty || value.contains('?') || uri.path.isNotEmpty && uri.path != '/') {
    throw ArgumentError.value(value, 'baseUrl', 'An explicit HTTPS origin is required');
  }
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}

Uri _httpsUrl(String value, String name) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.authority.contains('@') ||
      value.contains('#') || value.contains('\\') || value.codeUnits.any((c) => c <= 32 || c >= 127)) {
    throw ArgumentError.value(value, name, 'An absolute HTTPS URL without user info, fragment or raw whitespace is required');
  }
  _percentEscapes(value, name);
  return uri;
}

void _headerValue(String value, String name, {bool allowEmpty = false}) {
  if ((!allowEmpty && value.isEmpty) || value.contains('\r') || value.contains('\n') || value.contains('\u0000')) {
    throw ArgumentError.value(value, name, 'An explicit nonempty header value is required');
  }
}

void _percentEscapes(String value, String name) {
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) != 37) continue;
    if (i + 2 >= value.length || !RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(value.substring(i + 1, i + 3))) {
      throw ArgumentError.value(value, name, 'Malformed percent escape');
    }
    i += 2;
  }
}

