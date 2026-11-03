import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:http/http.dart' as http;

import 'generated/spotify/client_token/v0/client_token_http.pb.dart' as proto;
import 'hashcash.dart';
import 'native_protobuf.dart';

typedef ClientTokenSend = Future<http.Response> Function(Uint8List body);

class ClientTokenLease {
  ClientTokenLease({required this.token, required this.expiresAt,
    required this.refreshAt, required List<String> domains})
    : domains = List.unmodifiable(domains);
  final String token;
  final DateTime expiresAt;
  final DateTime refreshAt;
  final List<String> domains;
}

enum ClientTokenFailureReason {
  forbidden, httpStatus, emptyResponse, invalidProtobuf, unexpectedResponse,
  unsupportedChallenge, invalidPrefix,
}

class ClientTokenFailure implements Exception {
  const ClientTokenFailure(this.code, this.reason, {this.httpStatus});
  final int code;
  final ClientTokenFailureReason reason;
  final int? httpStatus;
  @override
  String toString() => 'Client token acquisition failed: ${reason.name} ($code)';
}

/// Native acquisition state from 0x1017c35a4, 0x1017c4c50, 0x1017c4e5c,
/// 0x1017c50e8, and 0x1017c52fc. HTTP identity is supplied by the transport.
class ClientTokenService {
  ClientTokenService(this.send, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final ClientTokenSend send;
  final DateTime Function() _now;

  Future<ClientTokenLease> acquire(proto.ClientDataRequest clientData) async {
    var request = proto.ClientTokenRequest(
      requestType: proto.ClientTokenRequestType.REQUEST_CLIENT_DATA_REQUEST,
      clientData: proto.ClientDataRequest.fromBuffer(clientData.writeToBuffer()),
    );
    while (true) {
      final response = await send(nativeProto3Bytes(request));
      if (response.statusCode != 200) {
        throw ClientTokenFailure(response.statusCode == 403 ? 104 : 101,
          response.statusCode == 403 ? ClientTokenFailureReason.forbidden : ClientTokenFailureReason.httpStatus,
          httpStatus: response.statusCode);
      }
      if (response.bodyBytes.isEmpty) {
        throw const ClientTokenFailure(101, ClientTokenFailureReason.emptyResponse);
      }
      final proto.ClientTokenResponse decoded;
      try {
        validateNativeProto3Strings(response.bodyBytes, proto.ClientTokenResponse());
        decoded = proto.ClientTokenResponse.fromBuffer(response.bodyBytes);
      } catch (_) {
        throw const ClientTokenFailure(101, ClientTokenFailureReason.invalidProtobuf);
      }
      // The original dispatches on the populated oneof, not response_type.
      switch (decoded.whichResponse()) {
        case proto.ClientTokenResponse_Response.grantedToken:
          final grant = decoded.grantedToken;
          final now = _now().toUtc();
          return ClientTokenLease(token: grant.token,
            expiresAt: now.add(Duration(seconds: grant.expiresAfterSeconds)),
            refreshAt: now.add(Duration(seconds: grant.refreshAfterSeconds)),
            domains: grant.domains.map((d) => d.domain).toList());
        case proto.ClientTokenResponse_Response.challenges:
          final challenge = decoded.challenges;
          final answers = <proto.ChallengeAnswer>[];
          for (final item in challenge.challenges) {
            if (item.whichParameters() != proto.Challenge_Parameters.evaluateHashcashParameters) {
              throw const ClientTokenFailure(101, ClientTokenFailureReason.unsupportedChallenge);
            }
            final parameters = item.evaluateHashcashParameters;
            final List<int> prefix;
            try {
              prefix = hex.decode(parameters.prefix);
            } on FormatException {
              throw const ClientTokenFailure(101, ClientTokenFailureReason.invalidPrefix);
            }
            final solved = await solveHashcash(prefix: prefix, difficulty: parameters.length);
            answers.add(proto.ChallengeAnswer(
              challengeType: proto.ChallengeType.CHALLENGE_HASH_CASH,
              hashCash: proto.HashCashAnswer(suffix: solved.suffixHex),
            ));
          }
          request = proto.ClientTokenRequest(
            requestType: proto.ClientTokenRequestType.REQUEST_CHALLENGE_ANSWERS_REQUEST,
            challengeAnswers: proto.ChallengeAnswersRequest(state: challenge.state, answers: answers),
          );
        case proto.ClientTokenResponse_Response.notSet:
          throw const ClientTokenFailure(101, ClientTokenFailureReason.unexpectedResponse);
      }
    }
  }
}
