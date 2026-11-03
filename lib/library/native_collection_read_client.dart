import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import '../protocol/generated/collection2v2.pb.dart';
import '../protocol/request_builder.dart';

const nativeCollectionMime = 'application/vnd.collection-v2.spotify.proto';

/// Original101b3cf5c through101b3d230, before native context/transport execution.
/// Regional routing is represented by the owner's actual regional origin.
RequestEnvelope nativeCollectionPageRequest({required String baseUrl,
    required String username, required String collectionSet,
    required Map<String, String> inheritedHeaders, String paginationToken = ''}) {
  final base = Uri.tryParse(baseUrl);
  if (base == null || base.scheme != 'https' || base.host.isEmpty || base.userInfo.isNotEmpty ||
      base.hasQuery || base.hasFragment || base.path.isNotEmpty && base.path != '/') {
    throw ArgumentError.value(baseUrl, 'baseUrl', 'An explicit HTTPS native regional origin is required');
  }
  final message = PageRequest(limit: 300);
  // Native proto3 serialization omits default strings, including ones assigned
  // unconditionally by the original producer. Dart setters retain presence.
  if (username.isNotEmpty) message.username = username;
  if (collectionSet.isNotEmpty) message.set = collectionSet;
  if (paginationToken.isNotEmpty) message.paginationToken = paginationToken;
  final origin = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
  return RequestEnvelope(method: 'POST', url: '$origin/collection/v2/paging',
    headers: {...inheritedHeaders, 'Accept': nativeCollectionMime, 'Content-Type': nativeCollectionMime},
    body: message.writeToBuffer(), responseType: 'bytes');
}

typedef NativeCollectionHttpSend = Future<http.Response> Function(RequestEnvelope request);

/// Session-scoped membership snapshot. Follow opaque server pagination tokens;
/// never interpret a truncated playlist or a short page as an unsaved track.
class NativeCollectionReadClient {
  NativeCollectionReadClient({required this.baseUrl, required this.username,
    required this.collectionSet, required this.inheritedHeaders, required this.send});
  final String baseUrl, username, collectionSet;
  final Map<String, String> inheritedHeaders;
  final NativeCollectionHttpSend send;
  SharedTask<Map<String, CollectionItem>>? _snapshot;

  void invalidate() { _snapshot?.token.cancel(); _snapshot = null; }

  Future<Map<String, CollectionItem>> _current(CancellationToken? cancellationToken) {
    cancellationToken?.throwIfCancelled();
    if (_snapshot?.token.isCancelled == true) _snapshot = null;
    late final SharedTask<Map<String, CollectionItem>> pending;
    final task = _snapshot ??= pending = SharedTask((token) => _read(token).onError((Object error, StackTrace stack) {
      if (identical(_snapshot, pending)) _snapshot = null;
      Error.throwWithStackTrace(error, stack);
    }));
    return task.wait(cancellationToken);
  }

  /// The complete native snapshot is shared with Contains. Querying Library
  /// filters does not perform another full membership synchronization.
  Future<List<CollectionItem>> items({CancellationToken? cancellationToken}) async =>
    List.unmodifiable((await _current(cancellationToken)).values);

  Future<Map<String, bool>> contains(List<String> uris, {CancellationToken? cancellationToken}) async {
    final membership = await _current(cancellationToken);
    return {for (final uri in uris) uri: membership.containsKey(uri)};
  }

  Future<Map<String, CollectionItem>> _read(CancellationToken cancellationToken) async {
    final membership = <String, CollectionItem>{}, tokens = <String>{};
    var token = '';
    while (true) {
      cancellationToken.throwIfCancelled();
      final response = await send(nativeCollectionPageRequest(baseUrl: baseUrl,
        username: username, collectionSet: collectionSet, inheritedHeaders: inheritedHeaders,
        paginationToken: token).withCancellation(cancellationToken));
      cancellationToken.throwIfCancelled();
      if (response.statusCode != 200) throw StateError('Spotify collection returned HTTP ${response.statusCode}');
      final page = PageResponse.fromBuffer(response.bodyBytes);
      for (final item in page.items) {
        if (item.isRemoved) { membership.remove(item.uri); }
        else { membership[item.uri] = item..freeze(); }
      }
      final next = page.nextPageToken;
      if (next.isEmpty) {
        if (page.syncToken.isEmpty) throw const FormatException('Spotify collection did not provide a complete sync token');
        return membership;
      }
      if (!tokens.add(next)) throw const FormatException('Spotify collection repeated a pagination token');
      token = next;
    }
  }

  Future<void> recordAcknowledgedChange(String uri, bool saved, {CancellationToken? cancellationToken}) async {
    final pending = _snapshot;
    if (pending == null) return;
    if (pending.token.isCancelled) return;
    final membership = await pending.wait(cancellationToken);
    if (saved) { membership.putIfAbsent(uri, () => CollectionItem(uri: uri)..freeze()); }
    else { membership.remove(uri); }
  }
}
