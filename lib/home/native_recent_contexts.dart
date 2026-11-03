import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import '../protocol/generated/recently_played_backend.pb.dart' as wire;
import '../protocol/request_builder.dart';

RequestEnvelope nativeRecentContextsRequest({required String baseUrl,
    required Map<String, String> inheritedHeaders}) {
  final base = Uri.tryParse(baseUrl);
  if (base == null || base.scheme != 'https' || base.host.isEmpty || base.userInfo.isNotEmpty ||
      base.hasQuery || base.hasFragment || base.path.isNotEmpty && base.path != '/') {
    throw ArgumentError.value(baseUrl, 'baseUrl', 'An explicit native HTTPS origin is required');
  }
  final origin = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  return RequestEnvelope(method: 'GET', url: '$origin$nativeRecentContextsTarget',
    headers: inheritedHeaders, responseType: 'bytes');
}

const nativeRecentContextsTarget = '/recently-played/v3/recently-played?limit=50&filter=default,collection-new-episodes';

class NativeRecentContextsSnapshot {
  const NativeRecentContextsSnapshot(this.response, this.expiresAtMicroseconds);
  final wire.RecentlyPlayed response;
  final int expiresAtMicroseconds;
}

/// Original fixed fifty-context read. One in-flight request and one snapshot;
/// response cache fields determine freshness, with no background timer.
class NativeRecentContextsClient {
  NativeRecentContextsClient({required this.baseUrl, required this.inheritedHeaders,
    required this.send, required this.nowMicroseconds});
  final String baseUrl;
  final Map<String, String> inheritedHeaders;
  final Future<http.Response> Function(RequestEnvelope request) send;
  final int Function() nowMicroseconds;
  NativeRecentContextsSnapshot? _snapshot;
  SharedTask<NativeRecentContextsSnapshot>? _pending;

  void invalidate() { _snapshot = null; _pending?.token.cancel(); _pending = null; }

  Future<NativeRecentContextsSnapshot> read({bool refresh = false, CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    final snapshot = _snapshot;
    if (!refresh && snapshot != null && snapshot.expiresAtMicroseconds > nowMicroseconds()) {
      return Future.value(snapshot);
    }
    if (_pending?.token.isCancelled == true) _pending = null;
    late final SharedTask<NativeRecentContextsSnapshot> pending;
    final task = _pending ??= pending = SharedTask((token) => _read(token).whenComplete(() {
      if (identical(_pending, pending)) _pending = null;
    }));
    return task.wait(cancellationToken);
  }

  Future<NativeRecentContextsSnapshot> _read(CancellationToken token) async {
    final response = await send(nativeRecentContextsRequest(baseUrl: baseUrl,
      inheritedHeaders: inheritedHeaders).withCancellation(token));
    token.throwIfCancelled();
    if (response.statusCode != 200) throw HttpException('Recent Contexts returned HTTP ${response.statusCode}');
    final body = wire.RecentlyPlayed.fromBuffer(response.bodyBytes)..check()..freeze();
    final snapshot = NativeRecentContextsSnapshot(body,
      nowMicroseconds() + _freshness(response.headers).inMicroseconds);
    _snapshot = snapshot;
    return snapshot;
  }
}

Duration _freshness(Map<String, String> headers) {
  final fields = (headers['cache-control'] ?? '').toLowerCase().split(',').map((s) => s.trim()).toList();
  if (fields.any((s) => s == 'no-cache' || s == 'no-store') || headers.containsKey('vary')) return Duration.zero;
  final maximum = fields.where((s) => s.startsWith('max-age=')).firstOrNull;
  final seconds = maximum == null ? null : int.tryParse(maximum.substring(8).replaceAll('"', ''));
  if (seconds == null || seconds <= 0) return Duration.zero;
  final receivedAge = int.tryParse(headers['age'] ?? '') ?? 0;
  final DateTime date;
  try { date = HttpDate.parse(headers['date'] ?? ''); }
  on HttpException { return Duration.zero; }
  final apparentAge = math.max(0, DateTime.now().toUtc().difference(date).inSeconds);
  return Duration(seconds: math.max(0, seconds - math.max(receivedAge, apparentAge)));
}
