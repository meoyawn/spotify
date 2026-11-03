import 'dart:typed_data';

import 'package:convert/convert.dart' show hex;

import '../protocol/request_builder.dart';

/// Music POST-key branch of original 0x10048cbcc, before its HTTP executor.
///
/// The actual template producer and serialized body owner remain explicit.
/// This plan supplies no authentication, entitlement, version/token, header,
/// retry or response-decryption policy. It performs no network I/O.
final class NativePlayPlayRequestPlan {
  NativePlayPlayRequestPlan._(this.request, this.fileId20);

  factory NativePlayPlayRequestPlan.musicKey({
    required RequestEnvelope template,
    required List<int> fileId20,
    required List<int> serializedBody,
  }) {
    if (fileId20.length != 20 || fileId20.any((value) => value < 0 || value > 255)) {
      throw ArgumentError('A music PlayPlay file identity must contain exactly20 octets');
    }
    if (serializedBody.any((value) => value < 0 || value > 255)) {
      throw ArgumentError('The serialized PlayPlay body must contain octets');
    }
    final origin = _templateOrigin(template.url);
    final identity = Uint8List.fromList(fileId20).asUnmodifiableView();
    final request = RequestEnvelope(method: 'POST',
      url: '$origin/playplay/v1/key/${hex.encode(identity)}', headers: template.headers,
      body: serializedBody, authorize: template.authorize,
      includeCredentials: template.includeCredentials, responseType: template.responseType,
      nativeTimeoutMilliseconds: template.nativeTimeoutMilliseconds, cancellationToken: template.cancellationToken);
    return NativePlayPlayRequestPlan._(request, identity);
  }

  static const nativeMode = 0;
  static const nativeIdentityKind = 0;

  /// Original explicit builder option before execution. Its backend mapping is
  /// a transport-owner responsibility; it is not inferred as an auth flag.
  final int nativeOption101c20240 = 1;
  final RequestEnvelope request;
  final Uint8List fileId20;
}

String _templateOrigin(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
      uri.userInfo.isNotEmpty || uri.query.isNotEmpty || uri.fragment.isNotEmpty ||
      value.contains('?') || value.contains('#') || value.contains('\\') ||
      uri.path.isNotEmpty && uri.path != '/' ||
      value.codeUnits.any((code) => code <= 32 || code >= 127)) {
    throw ArgumentError.value(value, 'template.url', 'An explicit HTTPS origin is required');
  }
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}
