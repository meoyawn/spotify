import 'dart:async';
import 'dart:math';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:fixnum/fixnum.dart';

import '../protocol/generated/collection2v2.pb.dart';
import '../protocol/request_builder.dart';
import 'native_collection_read_client.dart';

/// Artist membership uses the original artist bucket, independently of tracks.
class NativeFollowedArtists {
  NativeFollowedArtists({required this.membership, required this.send, required this.onChanged});
  final NativeCollectionReadClient membership;
  final NativeCollectionHttpSend send;
  final void Function() onChanged;
  Future<void> _writes = Future.value();
  int _queued = 0;

  Future<bool> contains(String uri, {CancellationToken? cancellationToken}) async =>
    (await membership.contains([uri], cancellationToken: cancellationToken))[uri]!;

  Future<void> setFollowing(String uri, bool following, {CancellationToken? cancellationToken}) async {
    if (!RegExp(r'^spotify:artist:[0-9A-Za-z]{22}$').hasMatch(uri)) {
      throw ArgumentError.value(uri, 'uri', 'Expected a Spotify artist');
    }
    if (_queued >= 16) throw StateError('An artist change is still in progress');
    _queued++;
    final token = cancellationToken ?? CancellationToken();
    final write = _writes = _writes.catchError((Object _) {}).then((_) async {
      token.throwIfCancelled();
      if (await contains(uri, cancellationToken: token) == following) return;
      final item = CollectionItem(uri: uri, addedAt: Int64(DateTime.now().millisecondsSinceEpoch ~/ 1000));
      if (!following) item.isRemoved = true;
      final message = WriteRequest(username: membership.username, set: 'artist',
        items: [item], clientUpdateId: _updateId());
      final origin = membership.baseUrl.replaceFirst(RegExp(r'/$'), '');
      try {
        final response = await send(RequestEnvelope(method: 'POST', url: '$origin/collection/v2/write',
          headers: {...membership.inheritedHeaders, 'Accept': nativeCollectionMime, 'Content-Type': nativeCollectionMime},
          body: message.writeToBuffer(), responseType: 'bytes', cancellationToken: token));
        if (response.statusCode != 200) throw StateError('Spotify could not update followed artists (HTTP ${response.statusCode})');
        await membership.recordAcknowledgedChange(uri, following, addedAt: item.addedAt);
      } catch (_) {
        membership.invalidate();
        rethrow;
      } finally { onChanged(); }
    }).whenComplete(() => _queued--);
    unawaited(write.catchError((Object _) {}));
    await write.asCancellable(token);
  }
}

String _updateId() {
  final random = Random.secure();
  return List.generate(2, (_) => random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0')).join();
}
