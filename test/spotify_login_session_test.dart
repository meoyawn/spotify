import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/playback/spotify_login_session.dart';
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/login5.pb.dart' as proto;
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';
import 'package:spotify_flutter/protocol/native_login5_exchange.dart';
import 'package:spotify_flutter/protocol/native_login5_request.dart';
import 'package:spotify_flutter/protocol/native_login5_response.dart';

Future<void> _callbacks() => Future<void>.delayed(Duration.zero);
final _aborted = isA<NativeLogin5Failure>().having((error) => error.code, 'code', 1);

void main() {
  test('Real Login5 exchange supplies one expiry refresh with rotated credentials and never restores a replaced or signed-out account', () async {
    final h = _Harness();
    final session = h.session;
    addTearDown(() { session.close(); h.deliver(); });
    await expectLater(session.accessToken(), throwsStateError);
    expect(h.sends, isEmpty);

    final initial = session.authenticate(const NativeLogin5Password(id: 'user-a', password: 'synthetic'));
    final initialJoin = session.accessToken();
    expect(h.sends.length, 1);
    final first = h.sends.single;
    expect(first.request.whichLoginMethod(), proto.LoginRequest_LoginMethod.password);
    expect(first.request.password.id, 'user-a');
    expect(first.request.clientInfo.clientId, 'fixture-client');
    expect(first.request.clientInfo.deviceId, 'fixture-device');
    h.succeed(first, 'canonical-a', 'token-a', [1, 255], 2);
    await _callbacks(); h.deliver();
    expect((await initial).expiresAtMicroseconds, 3000000);
    expect((await initialJoin).accessToken, 'token-a');
    h.now = 2999999;
    expect((await session.accessToken()).accessToken, 'token-a');
    expect(h.sends.length, 1);

    h.now = 3000000;
    final refresh = session.accessToken(), refreshJoin = session.accessToken();
    expect(h.sends.length, 2);
    final second = h.sends.last;
    _expectStored(second, 'canonical-a', [1, 255]);
    h.succeed(second, 'canonical-a', 'token-a-rotated', [2, 0], 1);
    await _callbacks(); h.deliver();
    expect((await refresh).accessToken, 'token-a-rotated');
    expect((await refreshJoin).expiresAtMicroseconds, 4000000);

    h.now = 4000000;
    final failedRefresh = session.accessToken();
    final failed = expectLater(failedRefresh,
      throwsA(isA<NativeLogin5Failure>().having((error) => error.code, 'code', 102)));
    _expectStored(h.sends.last, 'canonical-a', [2, 0]);
    h.reply(h.sends.last, proto.LoginResponse(error: proto.LoginError.INVALID_CREDENTIALS));
    await _callbacks(); h.deliver(); await failed; await _callbacks();
    expect(h.sends.length, 3, reason: 'Failure creates no background retry');

    final previousRefresh = session.accessToken();
    final previousAborted = expectLater(previousRefresh, throwsA(_aborted));
    final previousSend = h.sends.last;
    _expectStored(previousSend, 'canonical-a', [2, 0]);
    final accountB = session.authenticate(const NativeLogin5OneTimeToken(token: 'explicit-b'));
    final accountBJoin = session.accessToken();
    expect(previousSend.cancelled, isTrue);
    expect(h.sends.length, 5);
    expect(h.sends.last.request.whichLoginMethod(), proto.LoginRequest_LoginMethod.oneTimeToken);
    expect(h.sends.last.request.oneTimeToken.token, 'explicit-b');
    h.succeed(previousSend, 'canonical-a', 'late-old-token', [9], 100);
    h.succeed(h.sends.last, 'canonical-b', 'token-b', [3], 10);
    await _callbacks(); h.deliver(); await previousAborted;
    expect((await accountB).username, 'canonical-b');
    expect((await accountBJoin).accessToken, 'token-b');
    expect((await session.accessToken()).accessToken, 'token-b');

    // Replacing a still-valid account must not hand out its cached token while
    // the explicit new authentication is pending.
    final accountC = session.authenticate(const NativeLogin5Password(id: 'user-c', password: 'synthetic'));
    final accountCAborted = expectLater(accountC, throwsA(_aborted));
    final accountCJoin = session.accessToken();
    final accountCJoinAborted = expectLater(accountCJoin, throwsA(_aborted));
    var joinedDelivered = false;
    unawaited(accountCJoin.then<void>((_) { joinedDelivered = true; },
      onError: (Object _) { joinedDelivered = true; }));
    expect(h.sends.length, 6);
    final queuedSend = h.sends.last;
    expect(queuedSend.request.password.id, 'user-c');
    await _callbacks();
    expect(joinedDelivered, isFalse);
    h.succeed(queuedSend, 'canonical-c', 'token-c', [4], 100);
    await _callbacks();
    // Commit the real exchange result, then sign out before this session's
    // Future continuation runs. Exchange cancellation alone cannot undo it.
    expect(h.deliveries.length, 1);
    h.deliveries.removeAt(0)();
    session.signOut();
    await accountCAborted; await accountCJoinAborted;
    await expectLater(session.accessToken(), throwsStateError);
    expect(queuedSend.cancelled, isTrue);
    expect(h.sends.length, 6);

    final closing = session.authenticate(NativeLogin5StoredCredential(username: 'explicit-d', data: [5]));
    final closed = expectLater(closing, throwsA(_aborted));
    final closingSend = h.sends.last;
    _expectStored(closingSend, 'explicit-d', [5]);
    session.close();
    expect(closingSend.cancelled, isTrue);
    h.succeed(closingSend, 'late-d', 'late-closed-token', [6], 100);
    await _callbacks(); h.deliver(); await closed;
    await expectLater(session.accessToken(), throwsStateError);
    await expectLater(session.authenticate(const NativeLogin5OneTimeToken(token: 'after-close')), throwsStateError);
    session.close(); session.signOut();
    expect(h.sends.length, 7);
  });
}

void _expectStored(_Send send, String username, List<int> data) {
  expect(send.request.whichLoginMethod(), proto.LoginRequest_LoginMethod.storedCredential);
  expect(send.request.storedCredential.username, username);
  expect(send.request.storedCredential.data, data);
}

class _Send {
  _Send(this.request);
  final proto.LoginRequest request;
  final response = Completer<http.Response>();
  var cancelled = false;
}

class _Harness {
  _Harness() {
    final exchange = NativeLogin5V3Exchange(
      planner: NativeLogin5RequestPlanner(counter: NativeLogin5RetryCounter(
        monotonicNowNanoseconds: () => now * 1000)),
      nowMicroseconds: () => now,
      executeDelivery: deliveries.add,
      executeChallenges: (_, _) => throw StateError('This session fixture has no challenges'),
      sendOwned: (plan) {
        final send = _Send(proto.LoginRequest.fromBuffer(plan.request.body));
        sends.add(send);
        return NativeLogin5OwnedSend(response: send.response.future,
          cancel: () { send.cancelled = true; });
      });
    session = SpotifyLoginSession(exchange: exchange,
      credentials: const NativeLogin5Credentials(clientId: 'fixture-client', deviceId: 'fixture-device'),
      nowMicroseconds: () => now);
  }
  var now = 1000000;
  late final SpotifyLoginSession session;
  final sends = <_Send>[];
  final deliveries = <void Function()>[];

  void reply(_Send send, proto.LoginResponse response) {
    send.response.complete(http.Response.bytes(response.writeToBuffer(), 200));
  }

  void succeed(_Send send, String username, String token, List<int> stored, int seconds) =>
    reply(send, proto.LoginResponse(ok: proto.LoginOk(username: username, accessToken: token,
      storedCredential: stored, accessTokenExpiresIn: seconds)));

  void deliver() { while (deliveries.isNotEmpty) { deliveries.removeAt(0)(); } }
}
