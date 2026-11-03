import 'dart:convert';
import 'dart:io';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/hashcash.dart';

void main() {
  group('Original arm64 HashCash loop conformance', () {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/native-hashcash.json').readAsStringSync()) as Map<String, dynamic>;
    for (final input in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      test(input['name'] as String, () {
        final solution = solveHashcashSync(prefix: hex.decode(input['prefixHex'] as String),
          context: hex.decode(input['contextHex'] as String), difficulty: input['difficulty'] as int);
        expect(solution.suffixHex, input['suffixHex']);
        expect(solution.trials, input['trials']);
      });
    }
  });
}
