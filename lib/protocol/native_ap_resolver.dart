import 'dart:convert';

import 'native_http_defaults.dart';
import 'native_ap_system_info.dart';
import 'request_builder.dart';

/// Configuration fields read by original resolver owner 0x101a6ed1c. The
/// byte/value names retain raw offsets where higher-level meanings are unknown.
class NativeApResolverProfile {
  NativeApResolverProfile({required int versionValue, required int byte4,
    required int value8, required int byte12, required List<int> endpointTypes,
    this.urlOverride, this.site}) : versionValue = _unsigned(versionValue, 32, 'versionValue'),
      byte4 = _unsigned(byte4, 8, 'byte4'), value8 = _unsigned(value8, 32, 'value8'),
      byte12 = _unsigned(byte12, 8, 'byte12'),
      endpointTypes = List.unmodifiable(endpointTypes.map((value) {
        if (value != value.toSigned(32)) throw RangeError.value(value, 'endpointTypes', 'Must fit int32');
        return value;
      }));

  /// Scalar selection in original credential owner 0x10191b280..374. The
  /// original reads SystemInfo once even with an OS override; this pure
  /// projection consumes the caller's snapshot and performs no system IO.
  /// Version and endpoint selection remain explicit owning-context inputs.
  factory NativeApResolverProfile.fromNativeIdentity({required int versionValue,
    required NativeApSystemInfo systemInfo, required List<int> endpointTypes,
    int? platformOverride, int? productOverride, int? osOverride,
    String? urlOverride, String? site}) => NativeApResolverProfile(
      versionValue: versionValue, byte4: platformOverride ?? 43,
      value8: productOverride ?? 0, byte12: osOverride ?? systemInfo.os,
      endpointTypes: endpointTypes, urlOverride: urlOverride, site: site);

  final int versionValue, byte4, value8, byte12;
  final List<int> endpointTypes;
  /// Null means the native optional is absent; an empty string is present.
  final String? urlOverride, site;
  String get userAgent => 'Spotify/$versionValue ($byte4; $value8; $byte12)';
}

class NativeApResolverPlan {
  const NativeApResolverPlan._(this.request, this.context);
  final RequestEnvelope request;
  /// Opaque caller context forwarded by original 0x101c20210. It is never
  /// interpreted as credentials or converted into invented HTTP headers.
  final Object? context;
  /// Observed argument to native 0x101c20240; its broader meaning is unclaimed.
  int get option101c20240 => 1;
}

/// One member of the native resolver's ordered multimap. Raw endpoint types are
/// 0 accesspoint, 1 dealer-g2, 2 global spclient, and 3 regional spclient.
class NativeApResolverEndpoint {
  const NativeApResolverEndpoint({required this.type, required this.host, required this.port});
  final int type;
  /// Original parsing retains the host bytes, including an empty host. Socket
  /// admission and host validation belong to the eventual connection owner.
  final String host;
  final int port;
}

/// Actual original music/storage requests select the first regional endpoint
/// even while the resolver supplies a global endpoint. No unobserved fallback
/// to global is introduced. See reverse-engineering/evidence/native-regional-spclient.json.
String nativeRegionalSpclientOrigin(List<NativeApResolverEndpoint> endpoints) {
  final endpoint = endpoints.where((entry) => entry.type == 3 && entry.host.isNotEmpty).firstOrNull;
  if (endpoint == null) throw const FormatException('Spotify did not supply a regional server endpoint');
  return 'https://${endpoint.host}${endpoint.port == 443 ? '' : ':${endpoint.port}'}';
}

/// Raw failure codes returned by original 0x101a6eb9c: 1 non-2xx, 2 empty body.
/// A malformed nonempty JSON response follows an exception path, separately.
class NativeApResolverFailure implements Exception {
  const NativeApResolverFailure(this.code);
  final int code;
  @override
  String toString() => 'NativeApResolverFailure($code)';
}

/// Projects the HTTP response through the v2 schema and endpoint rules of
/// original 0x101a701dc / 0x101a7099c. No request or socket is created.
///
/// Standard UTF-8/JSON decoding owns syntax and decoded-object validation.
/// The original exception type/unwinding and malformed UTF-8 behavior are not
/// reconstructed. Duplicate valid JSON fields use the observed last value;
/// errors in an overwritten earlier field are not retained by JsonDecoder.
List<NativeApResolverEndpoint> decodeNativeApResolverResponse({
  required int status, required List<int> body,
}) {
  if (status < 200 || status > 299) throw const NativeApResolverFailure(1);
  if (body.isEmpty) throw const NativeApResolverFailure(2);
  final value = jsonDecode(utf8.decode(body));
  if (value is! Map<String, dynamic>) throw const FormatException('AP resolver response must be an object');
  List<String> strings(Map<String, dynamic> object, String key) {
    if (!object.containsKey(key)) return const [];
    final vector = object[key];
    if (vector is! List || vector.any((element) => element is! String)) {
      throw FormatException('AP resolver $key must be an array of strings');
    }
    return vector.cast<String>();
  }
  final accesspoint = strings(value, 'accesspoint');
  final dealer = strings(value, 'dealer-g2');
  Map<String, dynamic> spclient = const {};
  if (value.containsKey('spclient')) {
    final nested = value['spclient'];
    if (nested is! Map<String, dynamic>) throw const FormatException('AP resolver spclient must be an object');
    spclient = nested;
  }
  final groups = [accesspoint, dealer, strings(spclient, 'global'), strings(spclient, 'regional')];
  final endpoints = <NativeApResolverEndpoint>[];
  final decimal = RegExp(r'[0-9]+');
  for (var type = 0; type < groups.length; type++) {
    for (final text in groups[type]) {
      final colon = text.indexOf(':');
      if (colon < 0) continue;
      final portText = text.substring(colon + 1);
      final digits = decimal.matchAsPrefix(portText);
      if (digits == null || digits.end != portText.length) continue;
      final port = int.tryParse(portText);
      if (port == null || port < 1 || port > 65535) continue;
      endpoints.add(NativeApResolverEndpoint(type: type, host: text.substring(0, colon), port: port));
    }
  }
  return List.unmodifiable(endpoints);
}

/// Original resolver URL/UA construction at 0x101a6ed1c, independently executed
/// in reverse-engineering/fixtures/native-ap-resolver.json through the pre-send boundary.
/// This plans an application request only; it creates no sender or network.
class NativeApResolver {
  NativeApResolver({required this.profile, required this.template,
    required this.nowMicroseconds});
  final NativeApResolverProfile profile;
  /// The native owner changes the supplied template's URL and User-Agent; it
  /// does not establish its method or inherited authentication/context headers.
  final RequestEnvelope template;
  final int Function() nowMicroseconds;

  NativeApResolverPlan plan({Object? context}) {
    var url = profile.urlOverride ?? 'https://apresolve.spotify.com/v2';
    final site = profile.site;
    if (site != null) url = _append(url, 'site', site);
    // libc++ system_clock::to_time_t truncates signed microseconds toward zero.
    final seconds = nowMicroseconds() ~/ 1000000;
    url = _append(url, 'time', '$seconds');
    final types = profile.endpointTypes;
    if (types.contains(0)) url = _append(url, 'type', 'accesspoint');
    if (types.contains(2) || types.contains(3)) url = _append(url, 'type', 'spclient');
    if (types.contains(1)) url = _append(url, 'type', 'dealer-g2');
    final request = RequestEnvelope(method: template.method, url: url,
      headers: nativeHeaderOverrides(template.headers, {'User-Agent': profile.userAgent}),
      body: template.body, authorize: template.authorize,
      includeCredentials: template.includeCredentials, responseType: template.responseType,
      nativeTimeoutMilliseconds: template.nativeTimeoutMilliseconds, cancellationToken: template.cancellationToken);
    return NativeApResolverPlan._(request, context);
  }
}

/// Native 0x101f52d30/0x101f53aa0 split at the first '?', retain the raw existing
/// query, then append. They do not parse a URI fragment or replace an existing
/// site/time/type key. Existing percent escapes and separators stay unchanged.
String _append(String url, String key, String value) {
  final question = url.indexOf('?');
  final base = question < 0 ? url : url.substring(0, question);
  final query = question < 0 ? '' : url.substring(question + 1);
  String component(String text) => Uri.encodeQueryComponent(text).replaceAll('+', '%20');
  return '$base?${query.isEmpty ? '' : '$query&'}${component(key)}=${component(value)}';
}

int _unsigned(int value, int width, String name) {
  if (value < 0 || value != value.toUnsigned(width)) throw RangeError.value(value, name, 'Must fit uint$width');
  return value;
}

