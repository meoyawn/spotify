import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/native_ap_hashcash.dart';

void main() {
  test('AP challenge suffixes match the unchanged original native loop', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-ap-hashcash.json').readAsStringSync()) as Map<String, dynamic>;
    for (final input in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final solution = await solveNativeApHashcash(
        clientHello: hex.decode(input['helloHex'] as String),
        serverResponse: hex.decode(input['responseHex'] as String),
        prefix: hex.decode(input['prefixHex'] as String),
        difficulty: input['difficulty'] as int, target: input['target'] as int);
      expect(hex.encode(solution), input['suffixHex'], reason: input['name'] as String);
    }
  });
}
