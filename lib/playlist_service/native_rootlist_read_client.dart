import 'dart:convert';

import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/generated/playlist_api.pb.dart';
import '../protocol/generated/playlist_sync_reason.pb.dart';
import '../protocol/request_builder.dart';
import 'native_read_client.dart';
import 'sync_path.dart';
import 'sync_reply.dart';

/// Fresh rootlist RELOGIN read from native 0x101aac180/0x101aaca54 and the
/// original source575 capture. The owner supplies a decoded canonical username,
/// regional origin, native application headers and an authenticated sender.
/// No account tier, cached revision, lens or transport is selected here.
class NativeRootlistReadClient {
  NativeRootlistReadClient({required String baseUrl, required this.username,
    required this.headers, required this.nativeHttpSend}) : _baseUrl = _origin(baseUrl) {
    if (username.isEmpty) throw ArgumentError.value(username, 'username');
  }
  final String _baseUrl;
  final String username;
  final NativePlaylistRequestHeaders headers;
  final NativePlaylistHttpSend nativeHttpSend;

  Future<SelectedListContent> read({int from = 0, int length = 120, CancellationToken? cancellationToken}) async {
    final reply = await readReply(from: from, length: length, cancellationToken: cancellationToken);
    if (reply.error.value != 0 || reply.responseStatusCode == null ||
        reply.responseStatusCode! < 200 || reply.responseStatusCode! >= 300 ||
        reply.contentFidelity != PlaylistSyncContentFidelity.complete) {
      throw NativePlaylistReadException(reply);
    }
    if (reply.content.hasDiff() || reply.content.hasSyncResult() || !reply.content.hasContents()) {
      throw UnsupportedError('Fresh rootlist reader requires a standalone content snapshot');
    }
    if (reply.content.contents.pos != from) {
      throw const FormatException('Rootlist response position differs from the requested range');
    }
    return reply.content;
  }

  Future<PlaylistSyncReply> readReply({int from = 0, int length = 120, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (from < 0 || length <= 0 || from > 0x7fffffffffffffff - length) {
      throw RangeError('A nonnegative rootlist offset and positive bounded length are required');
    }
    for (final value in [headers.locale, headers.timeZone, headers.userAgent]) {
      if (value.isEmpty || value != value.trim() ||
          value.codeUnits.any((byte) => byte < 0x20 || byte > 0x7e)) {
        throw const FormatException('Native rootlist application header is invalid');
      }
    }
    final route = PlaylistSyncRoute(method: 'GET',
      path: 'playlist/v2/user/${_username(username)}/rootlist').withQuery([
        const MapEntry('decorate', 'revision,attributes,length,owner,capabilities,status_code,timestamp'),
        MapEntry('from', '$from'), MapEntry('length', '$length'),
      ]);
    // Original RELOGIN caller=5, prioritized=false. Proto3 omits false on wire.
    final reason = PlaylistSyncReason(caller: PlaylistSyncCaller.RELOGIN);
    final response = await nativeHttpSend(RequestEnvelope(method: route.method,
      url: '$_baseUrl/${route.path}', responseType: 'bytes', headers: {
        'Accept-Language': headers.locale,
        'app-platform': 'OSX_ARM64',
        'spotify-app-version': '130601921',
        'time-zone': headers.timeZone,
        'User-Agent': headers.userAgent,
        'Cache-Control': 'no-cache, no-store',
        'spotify-accept-geoblock': 'dummy',
        'spotify-playlist-sync-reason': base64Encode(reason.writeToBuffer()),
        'spotify-dsa-mode-enabled': 'false',
        'spotify-list-player-enabled': 'true',
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

// Original 0x101f5255c keeps RFC3986 unreserved bytes; encodeComponent's
// additional punctuation must be escaped. Original synthetic execution owns
// the Unicode, slash, percent, space, plus and punctuation examples.
String _username(String value) => Uri.encodeComponent(value)
  .replaceAll('!', '%21').replaceAll('*', '%2A').replaceAll("'", '%27')
  .replaceAll('(', '%28').replaceAll(')', '%29');

String _origin(String value) {
  final parsed = Uri.tryParse(value);
  if (parsed == null || parsed.scheme != 'https' || parsed.host.isEmpty || parsed.userInfo.isNotEmpty ||
      parsed.hasQuery || parsed.hasFragment || (parsed.path.isNotEmpty && parsed.path != '/')) {
    throw ArgumentError.value(value, 'baseUrl', 'An explicit HTTPS native server origin is required');
  }
  return value.endsWith('/') ? value.substring(0, value.length - 1) : value;
}
