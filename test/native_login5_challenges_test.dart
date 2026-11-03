import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/login5.pb.dart' as proto;
import 'package:spotify_flutter/protocol/hashcash.dart';
import 'package:spotify_flutter/protocol/native_login5_challenges.dart';
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';
import 'package:spotify_flutter/protocol/native_login5_exchange.dart';
import 'package:spotify_flutter/protocol/native_login5_response.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-login5-challenges.json').readAsStringSync()) as Map<String, dynamic>;
  final classifier = NativeLogin5V3Classifier(
    credentials: const NativeLogin5Credentials(clientId: 'synthetic-client', deviceId: 'synthetic-device'),
    credential: NativeLogin5StoredCredential(username: 'synthetic-user', data: [0]), nowMicroseconds: () => 0);

  for (final row in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
    test('Original challenge task: ${row['name']}', () async {
      final expected = row['nativeResult'] as Map<String, dynamic>;
      final pendingClocks = (row['clocks'] as List).cast<int>().toList();
      final clockReads = <int>[];
      int clock() { final value = pendingClocks.removeAt(0); clockReads.add(value); return value; }
      final events = <Map<String, dynamic>>[];
      final prompts = <NativeLogin5SmsChallenge>[];
      final deferred = Completer<HashcashSolution>();
      HashcashSolution Function()? finishDeferred;
      final executor = NativeLogin5V3ChallengeExecutor(nowNanoseconds: clock,
        observeSms: (prompt) {
          prompts.add(prompt);
          events.add({'kind': 'sms', 'method': prompt.method, 'codeLength': prompt.codeLength,
            'phoneNumber': prompt.phoneNumber, 'expiresInSeconds': prompt.expiresInSeconds,
            'expiresAtMicroseconds': prompt.expiresAtMicroseconds,
            'savedResponseAttempts': prompt.savedResponseAttempts});
        },
        solveHashcash: ({required context, required prefix, required difficulty, cancellationToken}) {
          events.add({'kind': 'hashcash', 'prefixHex': hex.encode(prefix), 'difficulty': difficulty});
          HashcashSolution solve() => solveHashcashSync(context: context, prefix: prefix,
            difficulty: difficulty, nowNanoseconds: clock);
          if (row['releaseAtHashcash'] == true) {
            finishDeferred = solve;
            return deferred.future;
          }
          return solve();
        });
      final decoded = NativeLogin5V3Response.decode(hex.decode(row['responseHex'] as String));
      final continuation = classifier.classify(decoded) as NativeLogin5ChallengeContinuation;
      final owner = executor(continuation, NativeLogin5ChallengeContext(
        responseAtMicroseconds: row['responseAtMicroseconds'] as int,
        savedResponseAttempts: row['savedResponseAttempts'] as int));
      var kind = 'pending';
      proto.ChallengeSolutions? solutions;
      Object? failure;
      owner.solutions.then<void>((value) { solutions = value; kind = 'complete'; },
        onError: (Object error, StackTrace stack) { failure = error; kind = 'failure'; });
      if (row['releaseAtHashcash'] == true) {
        events.add({'kind': 'ownerReleased'});
        owner.release();
        deferred.complete(finishDeferred!());
      }
      for (final rawAction in row['actions'] as List) {
        final action = rawAction as Map<String, dynamic>;
        switch (action['kind']) {
          case 'release': events.add({'kind': 'ownerReleased'}); owner.release();
          case 'submit': prompts[action['smsIndex'] as int? ?? 0].submit(action['code'] as String);
          case 'skip': prompts[action['smsIndex'] as int? ?? 0].skip();
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, row['nativeEvents']);
      expect(clockReads, row['nativeClockReads']);
      expect(kind, expected['kind']);
      if (kind == 'complete') {
        final request = continuation.withSolutions(solutions!);
        expect(hex.encode(request.writeToBuffer()), (expected['request'] as Map)['hex']);
      } else if (kind == 'failure') {
        expect(failure, isA<NativeLogin5Failure>().having((value) => value.code, 'code', expected['code']));
      }
      owner.release();
      owner.release();
    });
  }
}
