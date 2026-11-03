import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/generated/playlist_api.pb.dart';
import '../protocol/generated/playlist_sync_reason.pb.dart';
import '../protocol/request_builder.dart';
import 'sync_plan.dart';
import 'sync_reply.dart';

typedef NativePlaylistHttpSend = Future<http.Response> Function(RequestEnvelope request);

/// Explicit inputs of the original captured fresh primary GET path. These
/// values are caller/configuration state, never inferred from account tier.
class NativePlaylistReadPolicy {
  const NativePlaylistReadPolicy({required this.caller, required this.prioritized,
    required this.acceptListItems, required this.dsaMode,
    required this.listPlayerEnabled, required this.applyAutoLens});
  final PlaylistSyncCaller caller;
  final bool prioritized, acceptListItems, dsaMode, listPlayerEnabled, applyAutoLens;

  void _checkCaptured({required bool artistPopular}) {
    if ((artistPopular ? caller != PlaylistSyncCaller.SYNC_POLICY :
        !const [PlaylistSyncCaller.ESPERANTO, PlaylistSyncCaller.RECENTLY_PLAYED].contains(caller)) ||
        !prioritized || !acceptListItems || dsaMode || !listPlayerEnabled || !applyAutoLens) {
      throw UnsupportedError('Fresh playlist reader requires an explicitly captured caller/configuration policy');
    }
  }
}

/// App-level fields observed on native primary playlist GETs. In particular,
/// this template's explicit UA is distinct from the /0 hw.model fallback.
class NativePlaylistRequestHeaders {
  const NativePlaylistRequestHeaders({required this.locale, required this.timeZone, required this.userAgent});
  final String locale, timeZone, userAgent;
}

class NativePlaylistReadException implements Exception {
  const NativePlaylistReadException(this.reply);
  final PlaylistSyncReply reply;
  @override
  String toString() => 'Native playlist HTTP ${reply.responseStatusCode}, error ${reply.error.value}, status ${reply.status.value}';
}

/// Fresh server content only. This bypasses local synchronization/cache/index
/// ownership and returns the real SelectedListContent, never decoratedGet.
/// The session owner supplies endpoint, explicit policy, native app headers,
/// credentials and its separately admitted native HTTP sender.
class NativePlaylistReadClient {
  NativePlaylistReadClient({required String baseUrl, required this.policy,
    required this.headers, required this.nativeHttpSend}) : _baseUrl = _base(baseUrl);
  final String _baseUrl;
  final NativePlaylistReadPolicy policy;
  final NativePlaylistRequestHeaders headers;
  final NativePlaylistHttpSend nativeHttpSend;

  Future<SelectedListContent> read(String canonicalUri, {CancellationToken? cancellationToken}) async {
    final reply = await readReply(canonicalUri, cancellationToken: cancellationToken);
    if (reply.error.value != 0 || reply.responseStatusCode == null ||
        reply.responseStatusCode! < 200 || reply.responseStatusCode! >= 300 ||
        reply.contentFidelity != PlaylistSyncContentFidelity.complete) {
      throw NativePlaylistReadException(reply);
    }
    if (reply.content.hasDiff() || reply.content.hasSyncResult() || !reply.content.hasContents()) {
      throw UnsupportedError('Fresh playlist reader received no standalone content snapshot');
    }
    return reply.content;
  }

  Future<PlaylistSyncReply> readReply(String canonicalUri, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final artistPopular = RegExp(r'^spotify:list:popular-release-segments-main-roles:artist_[0-9A-Za-z]{22}$').hasMatch(canonicalUri);
    policy._checkCaptured(artistPopular: artistPopular);
    if (!artistPopular && !RegExp(r'^spotify:playlist:[0-9A-Za-z]{22}$').hasMatch(canonicalUri)) {
      throw UnsupportedError('Fresh playlist reader requires an ordinary canonical playlist URI');
    }
    for (final value in [headers.locale, headers.timeZone, headers.userAgent]) {
      if (value.isEmpty || value != value.trim() || value.codeUnits.any((byte) => byte < 0x20 || byte > 0x7e)) {
        throw const FormatException('Native playlist application header is invalid');
      }
    }
    final plan = buildPlaylistSyncPlan(canonicalUri: canonicalUri, caller: policy.caller,
      prioritized: policy.prioritized, acceptListItems: policy.acceptListItems,
      dsaMode: policy.dsaMode, listPlayerEnabled: policy.listPlayerEnabled);
    final response = await nativeHttpSend(RequestEnvelope(method: plan.method,
      url: '$_baseUrl/${plan.path}', responseType: 'bytes', headers: {
        'Accept-Language': headers.locale,
        'app-platform': 'OSX_ARM64',
        'spotify-app-version': '130601921',
        'time-zone': headers.timeZone,
        'User-Agent': headers.userAgent,
        for (final entry in plan.headers) entry.key: entry.value,
        // Actual fresh original captures carry this single requested lens.
        // No applied/revision lens state or arbitrary lens serializer is added.
        'spotify-apply-lenses': 'auto',
      }, cancellationToken: cancellationToken));
    cancellationToken?.throwIfCancelled();
    PlaylistSyncReply? result;
    final processor = PlaylistSyncReplyProcessor(onReply: (reply) => result = reply);
    try {
      processor.receiveResponse(statusCode: response.statusCode, headers: response.headers,
        body: response.bodyBytes);
      return result!;
    } finally { processor.close(); }
  }
}

String _base(String value) {
  final parsed = Uri.tryParse(value);
  if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty || parsed.userInfo.isNotEmpty ||
      parsed.hasQuery || parsed.hasFragment || (parsed.path.isNotEmpty && parsed.path != '/')) {
    throw ArgumentError.value(value, 'baseUrl', 'An explicit HTTPS native server origin is required');
  }
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}
