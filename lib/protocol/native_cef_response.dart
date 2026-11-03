import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZstdDecoder;
import 'package:brotli/brotli.dart' show brotliDecode;
import 'package:http/http.dart' as http;

/// Standard Chromium151 content-coding policy for the native URLRequest body.
/// Header metadata remains the original response metadata. Unencoded responses
/// keep their streaming path; compressed control responses use standard codecs.
http.StreamedResponse decodeNativeCefResponse(http.StreamedResponse response) {
  final contentEncoding = response.headers.entries.where(
    (entry) => entry.key.toLowerCase() == 'content-encoding').map((entry) => entry.value).join(',');
  if (contentEncoding.isEmpty) return response;
  final codings = contentEncoding.split(',').map((value) => value.trim().toLowerCase()).toList();
  // Chromium FilterSourceStream disables the full chain on any unknown/empty
  // coding, passing the original bytes through instead of partially decoding.
  if (codings.any((coding) => !const {'gzip', 'x-gzip', 'deflate', 'br', 'zstd'}.contains(coding))) {
    return response;
  }
  Stream<List<int>> body() async* {
    final encoded = BytesBuilder(copy: false);
    await for (final chunk in response.stream) { encoded.add(chunk); }
    List<int> bytes = encoded.takeBytes();
    for (final coding in codings.reversed) {
      bytes = switch (coding) {
        'gzip' || 'x-gzip' => gzip.decode(bytes),
        'deflate' => _deflate(bytes),
        'br' => brotliDecode(bytes),
        // Chromium's non-dictionary HTTP profile uses an 8 MiB window limit.
        'zstd' => ZstdDecoder(maxWindowSize: 1 << 23).decodeBytes(bytes,
          verify: true, throwOnError: true),
        _ => throw StateError('Unreachable content coding'),
      };
    }
    yield bytes;
  }
  return http.StreamedResponse(body(), response.statusCode,
    headers: response.headers, request: response.request,
    reasonPhrase: response.reasonPhrase, isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection);
}

List<int> _deflate(List<int> bytes) {
  try { return ZLibDecoder().convert(bytes); }
  on FormatException { return ZLibDecoder(raw: true).convert(bytes); }
}
