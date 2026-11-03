import 'dart:collection';

import 'native_cef_request.dart';
import 'native_cef_request_object.dart';
import 'native_foundation_request.dart';
import 'request_builder.dart';

/// Native request-constructor header policy from 0x101c20ccc. The separately
/// constructed native identity is explicit; renderer requests use another path.
class NativeHttpDefaults {
  const NativeHttpDefaults({required this.userAgent});
  final String userAgent;

  /// The Foundation-backed request constructor first applies this shared
  /// native header policy. It then converts into standard API inputs; final
  /// CFNetwork output and runtime backend selection remain separate contracts.
  NativeFoundationRequestPlan prepareFoundation(RequestEnvelope request,
      {required NativeFoundationOptions options}) =>
    NativeFoundationRequestPlan.fromRequest(prepare(request), options: options);

  /// Preserve the CEF adapter's separate User-Agent input and multimap stage.
  /// Native constructor defaults are applied first; no backend is selected.
  NativeCefRequestPlan prepareCef(RequestEnvelope request,
      {required NativeCefOptions options, required String adapterUserAgent}) =>
    NativeCefRequestPlan.fromRequest(prepare(request), options: options,
      adapterUserAgent: adapterUserAgent);

  /// Complete the independently captured default -> proprietary adapter ->
  /// shipped public CefRequest-object projection. Later browser/network-service
  /// processing remains separate; construction never enables a sender.
  NativeCefRequestObjectPlan prepareCefObject(RequestEnvelope request,
      {required NativeCefOptions options, required String adapterUserAgent}) =>
    NativeCefRequestObjectPlan.fromAdapter(prepareCef(request, options: options,
      adapterUserAgent: adapterUserAgent));

  RequestEnvelope prepare(RequestEnvelope request) {
    final headers = nativeHeaderOverrides(request.headers, const {});
    // Native insertion retains the first spelling and value, including empty
    // values. A request's User-Agent wins over the factory default in any case.
    if (userAgent.isNotEmpty) headers.putIfAbsent('User-Agent', () => userAgent);
    return RequestEnvelope(method: request.method, url: request.url,
      headers: headers, body: request.body, authorize: request.authorize,
      includeCredentials: request.includeCredentials, responseType: request.responseType,
      nativeTimeoutMilliseconds: request.nativeTimeoutMilliseconds, cancellationToken: request.cancellationToken);
  }
}

/// Explicit builder setters (0x101c24924) replace an existing value while
/// retaining its first spelling. This differs from constructor insertion.
Map<String, String> nativeHeaderOverrides(Map<String, String> original,
    Map<String, String> replacements) {
  final headers = nativeHeaderInsertions(original, const {});
  for (final entry in replacements.entries) {
    headers[entry.key] = entry.value;
  }
  return headers;
}

/// Bulk application headers (0x101c249b0) use unique insertion. Existing values,
/// including empty ones and differently cased spellings, win.
Map<String, String> nativeHeaderInsertions(Map<String, String> original,
    Map<String, String> additions) {
  final headers = LinkedHashMap<String, String>(
    equals: (left, right) => _asciiLower(left) == _asciiLower(right),
    hashCode: (key) => _asciiLower(key).hashCode,
  );
  for (final entry in original.entries) {
    headers.putIfAbsent(entry.key, () => entry.value);
  }
  for (final entry in additions.entries) {
    headers.putIfAbsent(entry.key, () => entry.value);
  }
  return headers;
}

String _asciiLower(String text) => String.fromCharCodes(text.codeUnits.map(
  (code) => code >= 65 && code <= 90 ? code + 32 : code));
