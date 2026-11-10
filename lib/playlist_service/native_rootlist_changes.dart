import 'package:fixnum/fixnum.dart';

import '../protocol/generated/playlist_api.pb.dart';

/// Original rootlist Add/Remove captures: insertion index zero, positional
/// removal, whole-second timestamps and no synthetic row ID or added_by.
ListChanges nativeRootlistChanges({required List<int> revision, required String username,
  required String uri, required bool saved, required int index,
  required int nonce, required int clockMicroseconds}) {
  if (!RegExp(r'^spotify:playlist:[0-9A-Za-z]{22}$').hasMatch(uri) || username.isEmpty || revision.isEmpty) {
    throw ArgumentError('A playlist, rootlist owner and server revision are required');
  }
  if (index < 0 || index > 0x7fffffff || nonce < 0 || nonce > 0xffffffff) {
    throw RangeError('Invalid rootlist row or operation nonce');
  }
  final timestamp = Int64(clockMicroseconds ~/ 1000000 * 1000);
  return ListChanges(baseRevision: revision, deltas: [Delta(ops: [saved
    ? Op(kind: Op_Kind.ADD, add: Add(fromIndex: 0,
        items: [Item(uri: uri, attributes: ItemAttributes(timestamp: timestamp))]))
    : Op(kind: Op_Kind.REM, rem: Rem(fromIndex: index, length: 1, items: [Item(uri: uri)]))],
    info: ChangeInfo(user: username, timestamp: timestamp))],
    wantResultingRevisions: true, wantSyncResult: true, nonces: [Int64(nonce)]);
}
