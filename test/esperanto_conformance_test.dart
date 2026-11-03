import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/esperanto.dart';
import 'package:spotify_flutter/protocol/desktop_identity.dart';

void main() {
  test(
    'Dart desktop version service returns the original native response bytes',
    () async {
      final fixture = jsonDecode(
        File('reverse-engineering/fixtures/native-version.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final call = EsperantoCall.decode(
        (fixture['request'] as List).cast<int>(),
      );
      final dispatcher = EsperantoDispatcher();
      const DesktopVersionService(DesktopIdentity()).register(dispatcher);
      expect(await dispatcher.callSingle(call), fixture['response']);
    },
  );
  group('Original native Esperanto envelope', () {
    final fixture = jsonDecode(
      File('reverse-engineering/fixtures/esperanto-oracle.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final scenario
        in (fixture['scenarios'] as List).cast<Map<String, dynamic>>()) {
      test(scenario['name'] as String, () {
        final call = EsperantoCall(
          scenario['service'] as String,
          scenario['method'] as String,
          (scenario['payload'] as List).cast<int>(),
        );
        final expected = scenario['expected']['frameHex'] as String;
        final actual = call
            .encode()
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        expect(actual, expected);
        final originalBytes = [
          for (var i = 0; i < expected.length; i += 2)
            int.parse(expected.substring(i, i + 2), radix: 16),
        ];
        final decoded = EsperantoCall.decode(originalBytes);
        expect(decoded.service, scenario['service']);
        expect(decoded.method, scenario['method']);
        expect(decoded.payload, scenario['payload']);
      });
    }
    test('Malformed frames fail before service dispatch', () {
      for (final bytes in <List<int>>[
        [0, 0, 0],
        [255, 255, 255, 255],
        [0, 0, 0, 10, 65],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
      ]) {
        expect(() => EsperantoCall.decode(bytes), throwsFormatException);
      }
    });
  });

  test('Cancelling an in-process Esperanto stream cancels its service subscription', () async {
    final cancelled = Completer<void>();
    final controller = StreamController<List<int>>(
      onCancel: cancelled.complete,
    );
    final dispatcher = EsperantoDispatcher();
    dispatcher.register(
      'fixture.service',
      EsperantoService(streaming: {'Sub': (_) => controller.stream}),
    );
    final received = <Uint8List>[];
    final first = Completer<void>();
    final subscription = dispatcher
        .callStream(EsperantoCall('fixture.service', 'Sub', []))
        .listen((value) {
          received.add(value);
          first.complete();
        });
    controller.add([1, 2, 3]);
    await first.future;
    await subscription.cancel();
    await cancelled.future;
    controller.add([9]);
    await controller.close();
    expect(received, [
      [1, 2, 3],
    ]);
  });
}
