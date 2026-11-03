import 'dart:convert';
import 'dart:io';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotify_flutter/protocol/client_token.dart';
import 'package:spotify_flutter/protocol/generated/connectivity.pb.dart' as data;
import 'package:spotify_flutter/protocol/generated/spotify/client_token/v0/client_token_http.pb.dart' as proto;

void main() {
  final wire = jsonDecode(File('reverse-engineering/fixtures/native-client-token-wire.json').readAsStringSync()) as Map<String, dynamic>;

  test('Client-token exchange preserves challenge state and the original native suffix', () async {
    final oracle = jsonDecode(File('reverse-engineering/fixtures/native-hashcash.json').readAsStringSync()) as Map<String, dynamic>;
    final vector = (oracle['cases'] as List).cast<Map<String, dynamic>>().firstWhere((v) => v['name'] == 'client token challenge');
    final sent = <proto.ClientTokenRequest>[];
    final service = ClientTokenService((bytes) async {
      sent.add(proto.ClientTokenRequest.fromBuffer(bytes));
      if (sent.length == 1) {
        return http.Response.bytes(proto.ClientTokenResponse(challenges: proto.ChallengesResponse(
          state: 'opaque+state/雪=', challenges: [proto.Challenge(
            // Native code selects the populated oneof, independent of this enum.
            type: proto.ChallengeType.CHALLENGE_UNKNOWN,
            evaluateHashcashParameters: proto.HashCashParameters(
              length: vector['difficulty'] as int, prefix: vector['prefixHex'] as String)),
          ],
        )).writeToBuffer(), 200);
      }
      return http.Response.bytes(proto.ClientTokenResponse(grantedToken: proto.GrantedTokenResponse(
        token: 'fixture-token', expiresAfterSeconds: 3600, refreshAfterSeconds: 1800,
        domains: [proto.TokenDomain(domain: 'fixture.invalid'), proto.TokenDomain(domain: 'second.invalid')],
      )).writeToBuffer(), 200);
    }, now: () => DateTime.utc(2026, 10, 27));
    final lease = await service.acquire(proto.ClientDataRequest(clientVersion: 'fixture-version', clientId: 'fixture-id'));
    expect(sent, hasLength(2));
    expect(sent.first.requestType, proto.ClientTokenRequestType.REQUEST_CLIENT_DATA_REQUEST);
    expect(sent.first.clientData.clientVersion, 'fixture-version');
    final followup = sent.last;
    expect(followup.requestType, proto.ClientTokenRequestType.REQUEST_CHALLENGE_ANSWERS_REQUEST);
    expect(followup.challengeAnswers.state, 'opaque+state/雪=');
    expect(followup.challengeAnswers.answers.single.challengeType, proto.ChallengeType.CHALLENGE_HASH_CASH);
    expect(followup.challengeAnswers.answers.single.hashCash.suffix, vector['suffixHex']);
    expect(lease.token, 'fixture-token');
    expect(lease.expiresAt, DateTime.utc(2026, 10, 27, 1));
    expect(lease.refreshAt, DateTime.utc(2026, 10, 27, 0, 30));
    expect(lease.domains, ['fixture.invalid', 'second.invalid']);
  });

  final clientDataCases = [
    (name: 'empty defaults', request: 'initialRequestHex', input: proto.ClientDataRequest(
      clientVersion: '', clientId: '', currentToken: '', clientDataDerivedValueVersion: 0)),
    (name: 'present optional defaults', request: 'optionalPresentRequestHex', input: proto.ClientDataRequest(
      clientVersion: '', clientId: '', currentToken: '', clientDataDerivedValueVersion: 0,
      connectivitySdkData: data.ConnectivitySdkData(developerApiKey: '',
        platformSpecificData: data.PlatformSpecificData(android: data.NativeAndroidData(desktopFormFactor: false))))),
    (name: 'absent optional defaults', request: 'optionalAbsentRequestHex', input: proto.ClientDataRequest(
      connectivitySdkData: data.ConnectivitySdkData(
        platformSpecificData: data.PlatformSpecificData(android: data.NativeAndroidData())))),
  ];
  for (final input in clientDataCases) {
  test('Client-token native wire ${input.name} through an empty-state challenge', () async {
    final exchange = wire['emptyStateExchange'] as Map<String, dynamic>;
    final requests = [input.request == 'initialRequestHex' ? exchange[input.request] : wire[input.request],
      exchange['answerRequestHex']];
    final responses = [exchange['challengeResponseHex'], exchange['grantedResponseHex']];
    var calls = 0;
    final service = ClientTokenService((bytes) async {
      expect(calls, lessThan(requests.length));
      expect(hex.encode(bytes), requests[calls]);
      return http.Response.bytes(hex.decode(responses[calls++] as String), 200);
    });
    final originalBytes = input.input.writeToBuffer();
    final lease = await service.acquire(input.input);
    expect(calls, 2);
    expect(lease.token, 'wire-fixture-token');
    expect(input.input.writeToBuffer(), originalBytes);
  });
  }

  group('Native client-token failure responses', () {
    final cases = [
      (name: 'forbidden', status: 403, body: <int>[], code: 104, reason: ClientTokenFailureReason.forbidden),
      (name: 'empty', status: 200, body: <int>[], code: 101, reason: ClientTokenFailureReason.emptyResponse),
      (name: 'invalid protobuf', status: 200, body: <int>[255], code: 101, reason: ClientTokenFailureReason.invalidProtobuf),
      (name: 'response enum without a populated result', status: 200, body: <int>[8, 1], code: 101, reason: ClientTokenFailureReason.unexpectedResponse),
      for (final row in (wire['rejectedResponses'] as List).cast<Map<String, dynamic>>())
        (name: row['name'] as String, status: 200, body: hex.decode(row['hex'] as String),
          code: 101, reason: ClientTokenFailureReason.invalidProtobuf),
    ];
    for (final input in cases) {
      test(input.name, () async {
        var calls = 0;
        final service = ClientTokenService((_) async {
          calls++;
          if (calls > 1) return http.Response.bytes([], 403);
          return http.Response.bytes(input.body, input.status);
        });
        await expectLater(service.acquire(proto.ClientDataRequest()),
          throwsA(isA<ClientTokenFailure>().having((e) => e.code, 'native code', input.code)
            .having((e) => e.reason, 'reason', input.reason)));
        expect(calls, 1);
      });
    }
  });
}
