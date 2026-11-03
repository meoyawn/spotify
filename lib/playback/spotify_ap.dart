// Adapted from librespot's core connection/codec.rs and audio_key.rs.
// Copyright (c) 2015 Paul Lietar
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';
import '../protocol/shannon.dart';

final class SpotifyApPacket {
  SpotifyApPacket(this.command, List<int> payload) : payload = _copyBytes(payload) {
    RangeError.checkValueInInterval(command, 0, 255, 'command');
    RangeError.checkValueInInterval(payload.length, 0, 65535, 'payload length');
  }
  final int command;
  final Uint8List payload;
}

final class SpotifyApProtocolException implements Exception {
  const SpotifyApProtocolException(this.message);
  final String message;
  @override
  String toString() => 'Spotify AP protocol: $message';
}

/// Stateful AP framing over an already established encrypted byte transport.
/// No connection or session is created here. Only MAC-verified packets escape.
final class SpotifyApCodec {
  SpotifyApCodec({required List<int> sendKey, required List<int> receiveKey})
    : _send = ShannonCipher(sendKey), _receive = ShannonCipher(receiveKey);
  final ShannonCipher _send, _receive;
  final _pending = ListQueue<int>();
  int _sendNonce = 0, _receiveNonce = 0;
  int? _payloadLength;
  int _command = 0;
  bool _open = true;

  Uint8List encode(SpotifyApPacket packet) {
    _requireOpen();
    if (_sendNonce > 0xffffffff) _fail('Send nonce exhausted');
    final frame = Uint8List(3 + packet.payload.length + 4);
    frame[0] = packet.command;
    ByteData.sublistView(frame).setUint16(1, packet.payload.length, Endian.big);
    frame.setRange(3, 3 + packet.payload.length, packet.payload);
    _send.nonce(_sendNonce++);
    _send.encrypt(Uint8List.sublistView(frame, 0, frame.length - 4));
    frame.setRange(frame.length - 4, frame.length, _send.finish());
    return frame;
  }

  /// Accepts arbitrary transport fragmentation and multiple frames per chunk.
  List<SpotifyApPacket> add(Uint8List bytes) {
    _requireOpen();
    _pending.addAll(bytes);
    final packets = <SpotifyApPacket>[];
    while (true) {
      if (_payloadLength == null) {
        if (_pending.length < 3) break;
        if (_receiveNonce > 0xffffffff) _fail('Receive nonce exhausted');
        final header = _take(3);
        _receive.nonce(_receiveNonce++);
        _receive.decrypt(header);
        _command = header[0];
        _payloadLength = ByteData.sublistView(header).getUint16(1, Endian.big);
      }
      final length = _payloadLength!;
      if (_pending.length < length + 4) break;
      final payload = _take(length);
      final receivedMac = _take(4);
      _receive.decrypt(payload);
      final expectedMac = _receive.finish();
      var difference = 0;
      for (var i = 0; i < 4; i++) { difference |= receivedMac[i] ^ expectedMac[i]; }
      if (difference != 0) _fail('Packet MAC mismatch');
      packets.add(SpotifyApPacket(_command, payload));
      _payloadLength = null;
    }
    return packets;
  }

  /// Call on transport EOF. An incomplete header, payload or MAC is fatal.
  void finishInput() {
    _requireOpen();
    if (_payloadLength != null || _pending.isNotEmpty) _fail('Truncated packet');
    close();
  }

  void close() {
    _open = false;
    _pending.clear();
    _payloadLength = null;
  }

  Uint8List _take(int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) { bytes[i] = _pending.removeFirst(); }
    return bytes;
  }
  void _requireOpen() {
    if (!_open) throw StateError('Spotify AP codec is closed');
  }
  Never _fail(String message) {
    close();
    throw SpotifyApProtocolException(message);
  }
}

enum SpotifyAudioKeyFailure { rejected, cancelled, timeout, closed, malformed, unknownSequence }

final class SpotifyAudioKeyException implements Exception {
  const SpotifyAudioKeyException(this.failure, {this.sequence, this.errorCode});
  final SpotifyAudioKeyFailure failure;
  final int? sequence, errorCode;
  @override
  String toString() => 'Spotify audio key: ${failure.name} (sequence $sequence, error $errorCode)';
}

/// Cancellation retires the local request, without claiming a remote abort.
final class SpotifyAudioKeyRequest {
  SpotifyAudioKeyRequest._(this.key, this._cancel);
  final Future<Uint8List> key;
  final void Function() _cancel;
  void cancel() => _cancel();
}

typedef SpotifyApPacketSender = FutureOr<void> Function(SpotifyApPacket packet);

/// AP key lookup only. The owner supplies authenticated packets and transport;
/// server denial remains a denial, regardless of account tier.
final class SpotifyAudioKeyManager {
  SpotifyAudioKeyManager({required this.sendPacket,
    this.responseTimeout = const Duration(milliseconds: 1500)}) {
    if (responseTimeout.isNegative) throw ArgumentError.value(responseTimeout, 'responseTimeout');
  }
  static const requestCommand = 0x0c, keyCommand = 0x0d, errorCommand = 0x0e;
  final SpotifyApPacketSender sendPacket;
  final Duration responseTimeout;
  final _pending = <int, _PendingKey>{};
  int _sequence = 0;
  bool _closed = false;

  SpotifyAudioKeyRequest request({required List<int> fileId, required List<int> trackGid,
      CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    _requireOpen();
    if (fileId.length != 20) throw ArgumentError.value(fileId.length, 'fileId length', 'Expected 20');
    if (trackGid.length != 16) throw ArgumentError.value(trackGid.length, 'trackGid length', 'Expected 16');
    final file = _copyBytes(fileId), track = _copyBytes(trackGid);
    final first = _sequence;
    while (_pending.containsKey(_sequence)) {
      _sequence = (_sequence + 1) & 0xffffffff;
      if (_sequence == first) throw StateError('Audio key sequence space exhausted');
    }
    final sequence = _sequence;
    _sequence = (_sequence + 1) & 0xffffffff;
    final pending = _PendingKey();
    _pending[sequence] = pending;
    final token = MergedCancellationToken([pending.cancellation, ?cancellationToken]);
    pending.cleanup = CancellationRegistration(token, onCancel: (error) => _fail(sequence, error));
    pending.timer = Timer(responseTimeout, () => _fail(sequence,
      SpotifyAudioKeyException(SpotifyAudioKeyFailure.timeout, sequence: sequence)));
    final payload = Uint8List(42)..setRange(0, 20, file)..setRange(20, 36, track);
    ByteData.sublistView(payload).setUint32(36, sequence, Endian.big);
    try {
      final sent = sendPacket(SpotifyApPacket(requestCommand, payload));
      if (sent is Future<void>) {
        sent.then<void>((_) {}, onError: (Object error, StackTrace stack) => _fail(sequence, error, stack));
      }
    } catch (error, stack) { _fail(sequence, error, stack); }
    return SpotifyAudioKeyRequest._(pending.result.future, () => pending.cancellation.cancel(
      SpotifyAudioKeyException(SpotifyAudioKeyFailure.cancelled, sequence: sequence)));
  }

  /// Returns false for unrelated AP commands. Late/unknown key sequences are
  /// reported separately from a matched server rejection or malformed reply.
  bool dispatch(SpotifyApPacket packet) {
    _requireOpen();
    if (packet.command != keyCommand && packet.command != errorCommand) return false;
    if (packet.payload.length < 4) throw const SpotifyApProtocolException('Audio key sequence missing');
    final data = ByteData.sublistView(packet.payload);
    final sequence = data.getUint32(0, Endian.big);
    final pending = _pending.remove(sequence);
    if (pending == null) throw SpotifyAudioKeyException(SpotifyAudioKeyFailure.unknownSequence, sequence: sequence);
    pending.timer?.cancel();
    pending.cleanup?.dispose();
    if (packet.command == keyCommand && packet.payload.length == 20) {
      pending.result.complete(_copyBytes(packet.payload.sublist(4)));
    } else if (packet.command == errorCommand && packet.payload.length >= 6) {
      pending.result.completeError(SpotifyAudioKeyException(SpotifyAudioKeyFailure.rejected,
        sequence: sequence, errorCode: data.getUint16(4, Endian.big)));
    } else {
      pending.result.completeError(SpotifyAudioKeyException(SpotifyAudioKeyFailure.malformed, sequence: sequence));
    }
    return true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final sequence in _pending.keys.toList()) {
      _fail(sequence, SpotifyAudioKeyException(SpotifyAudioKeyFailure.closed, sequence: sequence));
    }
  }
  void _fail(int sequence, Object error, [StackTrace? stack]) {
    final pending = _pending.remove(sequence);
    if (pending == null) return;
    pending.timer?.cancel();
    pending.cleanup?.dispose();
    pending.result.completeError(error, stack);
  }
  void _requireOpen() {
    if (_closed) throw StateError('Spotify audio key manager is closed');
  }
}

final class _PendingKey {
  final cancellation = CancellationToken();
  CancellationRegistration? cleanup;
  final result = Completer<Uint8List>();
  Timer? timer;
}

Uint8List _copyBytes(List<int> bytes) {
  for (final byte in bytes) { RangeError.checkValueInInterval(byte, 0, 255, 'byte'); }
  return Uint8List.fromList(bytes).asUnmodifiableView();
}
