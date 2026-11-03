import 'dart:typed_data';

import 'generated/connect.pb.dart';
import 'native_gzip.dart';
import 'native_http_defaults.dart';
import 'native_protobuf.dart';
import 'request_builder.dart';

/// Bounded normal device PUT of original0x1013257e4. The state DTO and all
/// identities, clocks, capabilities, reasons and common header values are
/// explicit owner inputs. This plan creates no state or account permission.
/// Actual startup captures provide the independent protobuf/gzip authority.
final class NativeConnectStatePutRequestPlan {
  NativeConnectStatePutRequestPlan._(this.request, this.putStateRequest, this.protobufBody);

  factory NativeConnectStatePutRequestPlan({required String origin,
    required String deviceId, required PutStateRequest request,
    required RequestEnvelope template, String? connectionId}) {
    final base = Uri.tryParse(origin);
    if (base == null || base.scheme != 'https' || base.host.isEmpty ||
        base.userInfo.isNotEmpty || base.query.isNotEmpty || base.fragment.isNotEmpty ||
        base.path.isNotEmpty && base.path != '/' || origin.contains('?') ||
        origin.contains('#') || origin.contains('\\') ||
        origin.codeUnits.any((code) => code <= 32 || code >= 127)) {
      throw ArgumentError('An explicit HTTPS Connect-state origin is required');
    }
    // Unchanged original101f5538c preserves unreserved ASCII, including UUID
    // identities. Keep the actual caller identity; do not synthesize40hex IDs.
    if (!RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(deviceId)) {
      throw ArgumentError('The proved Connect device path requires nonempty unreserved ASCII');
    }
    if (request.memberType == MemberType.ACTIVE_DEVICE_TRACKER) {
      throw UnsupportedError('The native member_type6 wake-devices query branch needs its explicit owner input');
    }
    final headers = nativeHeaderInsertions(template.headers, const {
      'Content-Encoding': 'gzip', 'Content-Type': 'application/protobuf',
    });
    if (headers['Content-Encoding'] != 'gzip' || headers['Content-Type'] != 'application/protobuf') {
      throw UnsupportedError('The captured Connect-state PUT requires gzip/application-protobuf template values');
    }
    if (connectionId != null) {
      if (connectionId.isEmpty) {
        throw StateError('The native Connect connection-ID provider rejects an empty value');
      }
      if (headers.containsKey('X-Spotify-Connection-Id')) {
        throw UnsupportedError('A preexisting Connect connection-ID header requires its original merge policy');
      }
      headers['X-Spotify-Connection-Id'] = connectionId;
    }
    final snapshot = request.deepCopy()..freeze();
    final protobuf = nativeProto3Bytes(snapshot).asUnmodifiableView();
    final authority = origin.endsWith('/') ? origin.substring(0, origin.length - 1) : origin;
    return NativeConnectStatePutRequestPlan._(RequestEnvelope(method: 'PUT',
      url: '$authority/connect-state/v1/devices/$deviceId', headers: headers,
      body: NativeGzip.encode(protobuf), authorize: template.authorize,
      includeCredentials: template.includeCredentials, responseType: template.responseType,
      nativeTimeoutMilliseconds: 3000, cancellationToken: template.cancellationToken), snapshot, protobuf);
  }

  final RequestEnvelope request;
  final PutStateRequest putStateRequest;
  final Uint8List protobufBody;
}
