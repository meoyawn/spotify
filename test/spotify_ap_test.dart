import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/playback/spotify_ap.dart';

void main() {
  final corpus = jsonDecode(File('reverse-engineering/fixtures/shannon.json').readAsStringSync()) as Map<String, dynamic>;
  final rows = {for (final row in (corpus['cases'] as List).cast<Map<String, dynamic>>()) row['name']: row};
  Uint8List bytes(String value) => Uint8List.fromList(hex.decode(value));
  Uint8List wire(Map<String, dynamic> row) => bytes('${row['ciphertextHex']}${row['macHex']}');
  SpotifyApPacket packet(Map<String, dynamic> row) {
    final value = row['packet'] as Map<String, dynamic>;
    return SpotifyApPacket(value['command'] as int, bytes(value['payloadHex'] as String));
  }
  final first = rows['ap_packet_0']!, second = rows['ap_packet_1']!;
  final receive = rows['ap_packet_receive']!, requestFive = rows['ap_audio_key_request_5']!;
  final sendKey = bytes(first['keyHex'] as String), receiveKey = bytes(receive['keyHex'] as String);
  SpotifyApCodec codec() => SpotifyApCodec(sendKey: sendKey, receiveKey: sendKey);
  TypeMatcher<SpotifyAudioKeyException> keyFailure(SpotifyAudioKeyFailure value) => isA<SpotifyAudioKeyException>()
    .having((error) => error.failure, 'failure', value);

  test('AP frames preserve reference nonces and authenticate fragmented packets before delivery', () {
    final client = codec();
    final firstWire = wire(first), secondWire = wire(second);
    expect(client.add(Uint8List.sublistView(firstWire, 0, firstWire.length - 1)), isEmpty);
    final delivered = <SpotifyApPacket>[];
    for (final byte in [...firstWire.sublist(firstWire.length - 1), ...secondWire]) {
      delivered.addAll(client.add(Uint8List.fromList([byte])));
    }
    expect(delivered.map((value) => value.command), [packet(first).command, packet(second).command]);
    expect(delivered.map((value) => hex.encode(value.payload)),
      [hex.encode(packet(first).payload), hex.encode(packet(second).payload)]);
    // Receiving two packets must not consume either sending nonce.
    expect(client.encode(packet(first)), firstWire);
    expect(client.encode(packet(second)), secondWire);
    client.finishInput();

    final damaged = Uint8List.fromList(firstWire)..[firstWire.length - 1] ^= 1;
    final poisoned = codec();
    expect(() => poisoned.add(damaged), throwsA(isA<SpotifyApProtocolException>()));
    expect(() => poisoned.add(firstWire), throwsStateError);
    expect(() => poisoned.encode(packet(first)), throwsStateError);
    for (final cut in [1, 2, 3, firstWire.length - 1]) {
      final truncated = codec();
      expect(truncated.add(Uint8List.sublistView(firstWire, 0, cut)), isEmpty);
      expect(truncated.finishInput, throwsA(isA<SpotifyApProtocolException>()));
      expect(() => truncated.add(firstWire), throwsStateError);
    }
    final maximum = SpotifyApPacket(255, Uint8List(65535));
    final boundary = codec();
    final roundTrip = boundary.add(boundary.encode(maximum)).single;
    expect(roundTrip.command, 255);
    expect(roundTrip.payload, maximum.payload);
    expect(() => SpotifyApPacket(0, Uint8List(65536)), throwsRangeError);
    boundary.finishInput();
  });

  test('Audio-key request bytes and out-of-order authenticated response match the independent AP reference', () async {
    final transport = SpotifyApCodec(sendKey: sendKey, receiveKey: receiveKey);
    final outgoing = <Uint8List>[];
    final manager = SpotifyAudioKeyManager(sendPacket: (value) { outgoing.add(transport.encode(value)); });
    final requests = <SpotifyAudioKeyRequest>[];
    final results = <Future<Object>>[];
    final completed = <int>[];
    for (var i = 0; i < 6; i++) {
      final request = manager.request(fileId: List.generate(20, (i) => i),
        trackGid: List.generate(16, (i) => 0x20 + i));
      requests.add(request);
      final index = i;
      results.add(request.key.then<Object>((value) { completed.add(index); return value; },
        onError: (Object error) => error));
    }
    expect(outgoing.last, wire(requestFive));
    for (final byte in wire(receive)) {
      for (final response in transport.add(Uint8List.fromList([byte]))) {
        expect(manager.dispatch(response), isTrue);
      }
    }
    expect(await requests.last.key, List.generate(16, (i) => i));
    expect(completed, [5]);
    requests.last.cancel();
    manager.close();
    manager.close();
    final outcomes = await Future.wait(results);
    for (final result in outcomes.take(5)) { expect(result, keyFailure(SpotifyAudioKeyFailure.closed)); }
    expect(outcomes.last, List.generate(16, (i) => i));
    expect(() => manager.request(fileId: Uint8List(20), trackGid: Uint8List(16)), throwsStateError);
    transport.finishInput();
  });

  test('Audio-key denial, cancellation, timeout and send failure retire their matching pending request', () async {
    final manager = SpotifyAudioKeyManager(sendPacket: (_) {});
    final denied = manager.request(fileId: Uint8List(20), trackGid: Uint8List(16));
    final denial = expectLater(denied.key, throwsA(keyFailure(SpotifyAudioKeyFailure.rejected)
      .having((error) => error.errorCode, 'server error', 0x1234)));
    expect(manager.dispatch(SpotifyApPacket(0x0e, [0, 0, 0, 0, 0x12, 0x34])), isTrue);
    await denial;
    final cancelled = manager.request(fileId: Uint8List(20), trackGid: Uint8List(16));
    final cancellation = expectLater(cancelled.key, throwsA(keyFailure(SpotifyAudioKeyFailure.cancelled)));
    cancelled.cancel(); cancelled.cancel();
    await cancellation;
    expect(() => manager.dispatch(SpotifyApPacket(0x0d, [0, 0, 0, 1, ...Uint8List(16)])),
      throwsA(keyFailure(SpotifyAudioKeyFailure.unknownSequence)));
    final malformed = manager.request(fileId: Uint8List(20), trackGid: Uint8List(16));
    final malformedResult = expectLater(malformed.key, throwsA(keyFailure(SpotifyAudioKeyFailure.malformed)));
    manager.dispatch(SpotifyApPacket(0x0d, [0, 0, 0, 2, 0]));
    await malformedResult;
    manager.close();

    final timeout = SpotifyAudioKeyManager(sendPacket: (_) {}, responseTimeout: Duration.zero);
    final timed = timeout.request(fileId: Uint8List(20), trackGid: Uint8List(16));
    await expectLater(timed.key, throwsA(keyFailure(SpotifyAudioKeyFailure.timeout)));
    expect(() => timeout.dispatch(SpotifyApPacket(0x0d, [0, 0, 0, 0, ...Uint8List(16)])),
      throwsA(keyFailure(SpotifyAudioKeyFailure.unknownSequence)));
    timeout.close();

    final send = Completer<void>(), failure = StateError('injected transport failed');
    final failedTransport = SpotifyAudioKeyManager(sendPacket: (_) => send.future);
    final failed = failedTransport.request(fileId: Uint8List(20), trackGid: Uint8List(16));
    final failedResult = expectLater(failed.key, throwsA(same(failure)));
    send.completeError(failure);
    await failedResult;
    expect(() => failedTransport.dispatch(SpotifyApPacket(0x0d, [0, 0, 0, 0, ...Uint8List(16)])),
      throwsA(keyFailure(SpotifyAudioKeyFailure.unknownSequence)));
    failedTransport.close();
  });
}
