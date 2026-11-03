import 'dart:math';
import 'dart:typed_data';

import 'generated/pending_event_entity.pb.dart';
import 'native_storage_framing.dart';

/// The successful output of native 0x1018b0e60. Empty usernames become absent;
/// the event name and decrypted payload bytes are retained without trimming.
final class NativeDecodedPendingEvent {
  NativeDecodedPendingEvent({required this.eventName, required List<int> payload,
    this.username}) : payload = Uint8List.fromList(payload).asUnmodifiableView();
  final String eventName;
  final Uint8List payload;
  final String? username;
}

/// Native 0x1018af004/0x1018b0e60 transform event payloads into/from the exact
/// PendingEventEntity. This owns no event queue, file or HTTP transport.
/// Use nativeProto3Bytes when serializing its message.
class NativePendingEventCodec {
  NativePendingEventCodec({Random? random}) : _framing = NativeStorageFraming(random: random);
  final NativeStorageFraming _framing;

  PendingEventEntity encrypt({required String eventName, required List<int> payload,
    String? username}) => PendingEventEntity(eventName: eventName,
      payload: _framing.encrypt(_pendingEventStorageKey, payload), username: username);

  NativeDecodedPendingEvent? decrypt(PendingEventEntity message) {
    final plaintext = _framing.decrypt(_pendingEventStorageKey, message.payload);
    if (plaintext == null) return null;
    return NativeDecodedPendingEvent(eventName: message.eventName, payload: plaintext,
      username: message.username.isEmpty ? null : message.username);
  }
}

// Immutable application-wide image constant used by 0x1018ac0b0/0x1018ac0e0;
// not an account credential. Source 0x1022a7b47, length 16, SHA-256
// 7b8240bef8c98963a08f4b3e01b291ab3ac6cba780f5deb949dfbd2822ff651f.
const List<int> _pendingEventStorageKey = [0x49, 0x77, 0xf8, 0x1f, 0x2e, 0x72, 0x4c, 0xb3, 0xde, 0xcd, 0x90, 0x6d, 0x0b, 0x35, 0x0d, 0xdf];
