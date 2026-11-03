import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fixnum/fixnum.dart';

import '../protocol/generated/playlist_api.pb.dart';

typedef NativePlaylistRowEntropy = List<int> Function(int byteCount);

/// Original single-operation, non-force ListChanges body. The owner supplies
/// actual native-list revision/row attributes and maintains the per-list nonce.
/// HTTP template, permission/lens state and acknowledgement remain separate.
class NativePlaylistChangesBody {
  NativePlaylistChangesBody._(ListChanges changes, this.nextNonce)
    : body = Uint8List.fromList(changes.writeToBuffer()).asUnmodifiableView();

  final Uint8List body;
  final int nextNonce;

  /// Original fresh local Add branches 0x101b0a9dc. Algorithm 1 uses the
  /// first 10 SHA1 bytes of the canonical URI (0x101bcbdf4/0x101b15238).
  /// The ordinary constructor 0x101b1504c/0x101b17c50 requests 8 entropy bytes.
  /// The algorithm must come from the actual server list's attributes.
  static ItemAttributes freshRowAttributes({required String username,
    required int clockMicroseconds, required String uri,
    required ItemIdAlgorithm itemIdAlgorithm, NativePlaylistRowEntropy? entropy}) {
    _track(uri);
    final List<int> bytes;
    if (itemIdAlgorithm == ItemIdAlgorithm.ALGORITHM_TRUNCATED_SHA1) {
      bytes = crypto.sha1.convert(utf8.encode(uri)).bytes.sublist(0, 10);
    } else {
      bytes = (entropy ?? _secureBytes)(8);
      if (bytes.length != 8 || bytes.any((byte) => byte < 0 || byte > 255)) {
        throw ArgumentError('The native ordinary playlist row requires exactly 8 entropy octets');
      }
    }
    return ItemAttributes(addedBy: username, timestamp: Int64(clockMicroseconds ~/ 1000), itemId: bytes);
  }

  /// Original Add 0x101ad2c20/0x101ad2a5c: default insertion is the front
  /// for Liked Songs, except an empty list uses the add_last representation.
  /// rowAttributes must come from the actual original-backed row constructor.
  static NativePlaylistChangesBody add({required List<int> currentRevision,
    required int priorNonce, required String username, required int clockMicroseconds,
    required String uri, required int previousLength, required ItemAttributes rowAttributes}) {
    _track(uri);
    if (previousLength < 0) throw RangeError.value(previousLength, 'previousLength');
    final attributes = ItemAttributes.fromBuffer(rowAttributes.writeToBuffer());
    if (attributes.hasAddedBy() && attributes.addedBy == username) attributes.clearAddedBy();
    final add = Add(items: [Item(uri: uri, attributes: attributes)]);
    if (previousLength == 0) { add.addLast = true; }
    else { add.addFirst = true; }
    return _finish(Op(kind: Op_Kind.ADD, add: add), currentRevision: currentRevision,
      priorNonce: priorNonce, username: username, clockMicroseconds: clockMicroseconds);
  }

  /// Original single-row Remove 0x101ad2f88. A real row identifier selects
  /// keyed removal; otherwise the original retains its actual index and length.
  static NativePlaylistChangesBody remove({required List<int> currentRevision,
    required int priorNonce, required String username, required int clockMicroseconds,
    required String uri, required int index, required List<int> itemId}) {
    _track(uri);
    if (index < 0 || index > 0x7fffffff) throw RangeError.value(index, 'index');
    final item = Item(uri: uri);
    final rem = Rem(items: [item]);
    if (itemId.isEmpty) { rem.fromIndex = index; rem.length = 1; }
    else { item.attributes = ItemAttributes(itemId: itemId); rem.itemsAsKey = true; }
    return _finish(Op(kind: Op_Kind.REM, rem: rem), currentRevision: currentRevision,
      priorNonce: priorNonce, username: username, clockMicroseconds: clockMicroseconds);
  }

  static NativePlaylistChangesBody _finish(Op operation, {required List<int> currentRevision,
    required int priorNonce, required String username, required int clockMicroseconds}) {
    if (priorNonce < 0 || priorNonce > 0xffffffff) throw RangeError.value(priorNonce, 'priorNonce');
    if (username.isEmpty) throw ArgumentError.value(username, 'username');
    final next = (priorNonce + 1) & 0xffffffff;
    // Original system_clock::to_time_t truncates microseconds to seconds.
    final timestamp = (clockMicroseconds ~/ 1000000) * 1000;
    final changes = ListChanges(baseRevision: currentRevision,
      deltas: [Delta(ops: [operation], info: ChangeInfo(user: username, timestamp: Int64(timestamp)))],
      wantResultingRevisions: true, wantSyncResult: true, nonces: [Int64(next)]);
    return NativePlaylistChangesBody._(changes, next);
  }
}

void _track(String uri) {
  if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)) {
    throw ArgumentError.value(uri, 'uri', 'An actual canonical Spotify track URI is required');
  }
}

List<int> _secureBytes(int count) {
  final random = Random.secure();
  return List.generate(count, (_) => random.nextInt(256));
}
