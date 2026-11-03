import 'dart:typed_data';

import 'request_builder.dart';

/// Raw proprietary adapter input read at 0x1017d876c. The context owner must
/// supply its actual byte; no high-level redirect option is inferred.
class NativeCefOptions {
  NativeCefOptions({required int adapterOption80})
    : adapterOption80 = RangeError.checkValueInInterval(adapterOption80, 0, 255, 'adapterOption80');
  final int adapterOption80;
}

/// Inputs Spotify's proprietary adapter passes to standard CefRequest APIs.
/// This is before CEF header filtering, URL parsing and network serialization;
/// construction does not create a transport or send a request.
class NativeCefRequestPlan {
  NativeCefRequestPlan._({required this.method, required this.urlInput,
    required this.headers, required this.body, required this.flags});

  factory NativeCefRequestPlan.fromRequest(RequestEnvelope request,
      {required NativeCefOptions options, required String adapterUserAgent}) {
    // CefRequest::HeaderMap is a case-sensitive multimap, distinct from the
    // native request's CI unique map. Seed insertion is unconditional, even
    // for empty text or an existing User-Agent in the native request.
    final entries = [MapEntry('User-Agent', adapterUserAgent), ...request.headers.entries];
    final order = List.generate(entries.length, (index) => index)..sort((left, right) {
      final comparison = entries[left].key.compareTo(entries[right].key);
      // std::multimap preserves insertion order among equivalent keys.
      return comparison != 0 ? comparison : left.compareTo(right);
    });
    return NativeCefRequestPlan._(method: request.method, urlInput: request.url,
      headers: List.unmodifiable(order.map((index) => entries[index])),
      body: request.body.isEmpty ? null : request.body,
      flags: options.adapterOption80 == 0 ? 0xd0 : 0x50);
  }

  final String method, urlInput;
  /// Sorted CEF multimap entries. Equal and differently cased names survive;
  /// consumers must not flatten this list into a case-insensitive map here.
  final List<MapEntry<String, String>> headers;
  /// Null means no post-data element. Nonempty bytes form one element even
  /// when the supplied method is GET. No filename source is constructed.
  final Uint8List? body;
  final int flags;
}
