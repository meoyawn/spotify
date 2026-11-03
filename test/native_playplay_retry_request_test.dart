import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http2/transport.dart' as h2;
import 'package:spotify_flutter/playback/native_playplay_license.dart';
import 'package:spotify_flutter/protocol/request_builder.dart';

void _expectOutgoing(RequestEnvelope request, Map original) {
  expect(request.method, original['method']);
  expect(request.url, original['rawUrl']);
  expect(request.headers, original['headers']);
  expect(hex.encode(request.body!), original['bodyHex']);
}

void main() {
  test('outgoing retry requests retain every original field and native scheduled delay', () async {
    final fixture = jsonDecode(File('reverse-engineering/evidence/native-playplay-retry-policy.json').readAsStringSync()) as Map;
    for (final value in [...fixture['cases'] as List, ...fixture['transportCases'] as List]) {
      final item = value as Map, original = item['initialRequest'] as Map;
      final target = item['attemptCountAtFailure'] as int;
      final raw = item['rawNativeInteractivity'] as int;
      final initial = RequestEnvelope(method: 'GET', url: original['url'] as String,
        headers: (original['headers'] as Map).cast<String, String>(), body: const [],
        authorize: false, includeCredentials: false, responseType: 'bytes');
      var sends = 0, clockReads = 0;
      final exchange = NativePlayPlayMusicKeyExchange(template: initial, cacheId: const [],
        timestampSeconds: () => 1700000000 + clockReads++, send: (request) async {
          sends++;
          if (sends > 1 && item['retryRequest'] == null) {
            fail('The original aborted job must not send another request');
          }
          final expected = (sends == 1 ? original : item['retryRequest']) as Map;
          _expectOutgoing(request, expected);
          if (sends <= target) {
            if (item['errorCode'] == 10 && item['errorCategory'] == 'http') {
              throw http.RequestAbortedException();
            }
            if (item['errorCode'] == 7) throw TimeoutException('Original native HTTP timeout input');
            if (item['errorCode'] != null) throw h2.TransportException('Non-abort transport failure');
            return http.Response('', item['httpStatus'] as int);
          }
          return http.Response.bytes([10, 16, ...List.filled(16, 0)], 200);
        });
      final fileId = (original['relativePath'] as String).split('/').last;
      final work = exchange.request(hex.decode(fileId), nativeInteractivity: raw,
        waitForRetry: (delay) async {
          if (item['timer'] == null) fail('The original abort schedules no retry');
          if (sends == target) {
            expect(delay.inMilliseconds, (item['timer'] as Map)['delayMilliseconds']);
          }
        });
      if (item['retryRequest'] == null) {
        await expectLater(work, throwsA(isA<http.RequestAbortedException>()));
        expect(sends, 1);
      } else {
        await work;
        expect(sends, target + 1);
      }
      expect(clockReads, 1, reason: 'The original retries the same serialized job');
    }
  });

  test('original terminal reply admission controls subsequent outgoing music-key requests', () async {
    final fixture = jsonDecode(File('reverse-engineering/evidence/native-playplay-terminal-policy.json').readAsStringSync()) as Map;
    for (final item in (fixture['cases'] as List).cast<Map>()) {
      final original = item['initialRequest'] as Map;
      var sends = 0, clockReads = 0;
      final client = NativePlayPlayMusicKeyClientState();
      NativePlayPlayMusicKeyExchange exchange() => NativePlayPlayMusicKeyExchange(cacheId: const [],
        clientState: client,
        template: RequestEnvelope(method: 'GET', url: original['url'] as String,
          headers: (original['headers'] as Map).cast<String, String>(),
          authorize: false, includeCredentials: false, responseType: 'bytes'),
        timestampSeconds: () { clockReads++; return 1700000000; }, send: (request) async {
          sends++;
          _expectOutgoing(request, original);
          return sends == 1 ? http.Response.bytes(hex.decode(item['bodyHex'] as String), item['status'] as int)
            : http.Response.bytes([10, 16, ...List.filled(16, 0)], 200);
        });
      final fileId = hex.decode((original['relativePath'] as String).split('/').last);
      await expectLater(exchange().request(fileId, nativeInteractivity: 0),
        throwsA(isA<NativePlayPlayLicenseException>()));
      if (item['ownerCallback'] case final Map callback) {
        // Dispatch the original captured delay0 owner callback before checking
        // the subsequent admission. This is not a retry or a network wait.
        await Future<void>.delayed(Duration(milliseconds: callback['delayMilliseconds'] as int));
      }
      final admitted = (item['nextPostAdmission'] as Map)['bodyConstructionReached'] as bool;
      Object? nextFailure;
      try { await exchange().request(fileId, nativeInteractivity: 0); }
      catch (error) { nextFailure = error; }
      expect(sends, admitted ? 2 : 1,
        reason: 'Original ${item['status']} body ${item['bodyHex']} admission must govern HTTP production');
      expect(clockReads, admitted ? 2 : 1,
        reason: 'The original disabled client does not produce another timestamp/body');
      expect(nextFailure, admitted ? isNull : isA<NativePlayPlayLicenseException>());
    }
  });

  test('the original disabling reply withdraws pending HTTP only within its own key client', () async {
    final fixture = jsonDecode(File('reverse-engineering/evidence/native-playplay-terminal-policy.json').readAsStringSync()) as Map;
    final item = (fixture['cases'] as List).cast<Map>().singleWhere((row) =>
      row['status'] == 403 && row['bodyHex'] == '0803');
    final original = item['initialRequest'] as Map;
    final client = NativePlayPlayMusicKeyClientState(), independent = NativePlayPlayMusicKeyClientState();
    final rejectedResponse = Completer<http.Response>();
    late CancellableCompleter<http.Response> pendingResponse;
    var sends = 0, aborted = 0, independentSends = 0;
    http.Response success() => http.Response.bytes([10, 16, ...List.filled(16, 0)], 200);
    NativePlayPlayMusicKeyExchange exchange(NativePlayPlayMusicKeyClientState state) =>
      NativePlayPlayMusicKeyExchange(cacheId: const [], clientState: state,
        template: RequestEnvelope(method: 'GET', url: original['url'] as String,
          headers: (original['headers'] as Map).cast<String, String>(),
          authorize: false, includeCredentials: false, responseType: 'bytes'),
        timestampSeconds: () => 1700000000, send: (request) async {
          _expectOutgoing(request, original);
          if (identical(state, independent)) { independentSends++; return success(); }
          sends++;
          if (sends == 1) return rejectedResponse.future;
          if (sends == 2) {
            pendingResponse = CancellableCompleter(request.cancellationToken, onCancel: () => aborted++);
            return pendingResponse.future;
          }
          return success();
        });
    final fileId = hex.decode((original['relativePath'] as String).split('/').last);
    final rejected = exchange(client).request(fileId, nativeInteractivity: 0)
      .then<Object?>((_) => null, onError: (Object error) => error);
    final pending = exchange(client).request(fileId, nativeInteractivity: 0)
      .then<Object?>((_) => null, onError: (Object error) => error);
    rejectedResponse.complete(http.Response.bytes(hex.decode(item['bodyHex'] as String), item['status'] as int));
    expect(await rejected, isA<NativePlayPlayLicenseException>());
    await Future<void>.delayed(Duration(milliseconds: (item['ownerCallback'] as Map)['delayMilliseconds'] as int));
    // A regression must fail rather than leave a synthetic peer pending.
    if (!pendingResponse.isCompleted) pendingResponse.complete(success());
    expect(await pending, isA<NativePlayPlayLicenseException>());
    expect(aborted, (item['keyErrors'] as List).cast<Map>().where((row) => row['job'] == 'pendingPost').length);
    await expectLater(exchange(client).request(fileId, nativeInteractivity: 0),
      throwsA(isA<NativePlayPlayLicenseException>()));
    await exchange(independent).request(fileId, nativeInteractivity: 0);
    expect(sends, 2, reason: 'The disabled client must not produce another HTTP request');
    expect(independentSends, 1, reason: 'A separate original client has its own admission state');
  });
}
