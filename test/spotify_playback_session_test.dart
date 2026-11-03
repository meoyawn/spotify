import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/playback/generated/keyexchange.pb.dart' as ap;
import 'package:spotify_flutter/playback/dart_audio_engine.dart';
import 'package:spotify_flutter/playback/spotify_ap_session.dart';
import 'package:spotify_flutter/playback/spotify_audio_stager.dart';
import 'package:spotify_flutter/playback/spotify_login_session.dart';
import 'package:spotify_flutter/playback/spotify_media_client.dart';
import 'package:spotify_flutter/playback/spotify_playback_session.dart';
import 'package:spotify_flutter/playback/spotify_requests.dart';
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/login5.pb.dart' as login;
import 'package:spotify_flutter/protocol/native_http_defaults.dart';
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';
import 'package:spotify_flutter/protocol/native_login5_exchange.dart';
import 'package:spotify_flutter/protocol/native_login5_request.dart';

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Ownership transition did not arrive');
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('sign-out and close retire real late AP owners without starting a stale account transport', () async {
    final fixture = jsonDecode(File('reverse-engineering/fixtures/spotify-ap-handshake.json').readAsStringSync()) as Map;
    final directory = await Directory.systemTemp.createTemp('spotify-playback-owner-');
    addTearDown(() => directory.delete(recursive: true));
    final responses = <Completer<http.Response>>[];
    final exchange = NativeLogin5V3Exchange(
      planner: NativeLogin5RequestPlanner(counter: NativeLogin5RetryCounter(monotonicNowNanoseconds: () => 1000000000)),
      nowMicroseconds: () => 1000000, executeDelivery: scheduleMicrotask,
      executeChallenges: (_, _) => throw StateError('No challenge was supplied'),
      sendOwned: (_) {
        final response = Completer<http.Response>();
        responses.add(response);
        return NativeLogin5OwnedSend(response: response.future, cancel: () {});
      });
    final loginOwner = SpotifyLoginSession(exchange: exchange,
      credentials: const NativeLogin5Credentials(clientId: 'explicit-test-client', deviceId: 'explicit-test-device'),
      nowMicroseconds: () => 1000000);
    final factories = <Completer<SpotifyApSession>>[];
    var mediaFactories = 0, mediaSends = 0;
    final session = SpotifyPlaybackSession(login: loginOwner, createAp: (_) {
      final factory = Completer<SpotifyApSession>();
      factories.add(factory);
      return factory.future;
    }, mediaClientFactory: (_) {
      mediaFactories++;
      return SpotifyMediaClient(requests: SpotifyRequests(baseUrl: 'https://media.invalid', inheritedHeaders: const {},
        defaults: const NativeHttpDefaults(userAgent: 'explicit-test-UA')), send: (_) async {
          mediaSends++;
          throw StateError('No signed-in AP owner permits media');
        });
    }, selectAudio: (_, _) => throw StateError('No ready AP account permits file selection'),
      selectCdn: (_) => throw StateError('No authorized storage response'),
      rangeBytes: 4096, stager: SpotifyAudioStager(directory: directory));
    final engine = await DartAudioEngine.open();
    addTearDown(engine.close);
    session.bindEngine(engine);
    addTearDown(session.close);

    for (final mode in ['signOut', 'close']) {
      final index = responses.length;
      final authenticating = session.authenticate(NativeLogin5Password(id: 'user-$mode', password: 'synthetic'));
      final rejected = expectLater(authenticating, throwsA(isA<StateError>()
        .having((error) => error.message, 'reason', 'Playback session changed')));
      await _until(() => responses.length == index + 1);
      responses[index].complete(http.Response.bytes(login.LoginResponse(ok: login.LoginOk(
        username: 'canonical-$mode', accessToken: 'token-$mode', storedCredential: [1, 2],
        accessTokenExpiresIn: 3600)).writeToBuffer(), 200));
      await _until(() => factories.length == index + 1);
      if (mode == 'signOut') { await session.signOut(); }
      else { await session.close(); }
      var writes = 0, closes = 0;
      final incoming = StreamController<Uint8List>.broadcast();
      addTearDown(incoming.close);
      final latePeer = SpotifyApSession(
        clientHello: ap.ClientHello.fromBuffer(hex.decode(fixture['clientHelloProtoHex'] as String)),
        buildAuthentication: (_) => throw StateError('Stale AP owner requested credentials'),
        incoming: incoming.stream, admitAuthenticationPacket: (_) => false,
        sendBytes: (_) async {
          writes++;
          incoming.addError(StateError('Stale transport was started'));
        }, closeTransport: () async { closes++; });
      factories[index].complete(latePeer);
      await rejected;
      expect(latePeer.state, SpotifyApSessionState.closed);
      expect(writes, 0);
      expect(closes, 1);
      expect(session.ready, isFalse);
      await expectLater(session.resolve('spotify:track:0000000000000000000001'), throwsStateError);
      await expectLater(loginOwner.accessToken(), throwsStateError);
      expect(mediaFactories, 0);
      expect(mediaSends, 0);
    }
    await session.close();
  });
}
