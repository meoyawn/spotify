import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/protobuf.dart';
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/login5.pb.dart' as proto;
import 'package:spotify_flutter/protocol/generated/spotify/login5/v3/user_info.pb.dart' as user;
import 'package:spotify_flutter/protocol/native_login5_credentials.dart';
import 'package:spotify_flutter/protocol/native_login5_response.dart';

void main() {
  final fixture = jsonDecode(File('reverse-engineering/fixtures/native-login5-response.json').readAsStringSync()) as Map<String, dynamic>;
  final classifier = NativeLogin5V3Classifier(credentials: const NativeLogin5Credentials(clientId: 'synthetic-client', deviceId: 'synthetic-device'),
    credential: NativeLogin5StoredCredential(username: 'synthetic-user', data: [0]),
    nowMicroseconds: () => fixture['nativeClockMicroseconds'] as int);

  test('V3 classification matches original dispatch, success projection, signup presence and native messages', () {
    for (final item in fixture['dispatchCases'] as List<dynamic>) {
      final row = item as Map<String, dynamic>, expected = row['nativeResult'] as Map<String, dynamic>;
      final decoded = NativeLogin5V3Response.decode(_input(row['fields'] as Map<String, dynamic>));
      final owner = row['phone'] == true ? NativeLogin5V3Classifier(
        credentials: classifier.credentials, credential: const NativeLogin5PhoneNumber(number: '', isoCountryCode: '', countryCallingCode: ''),
        nowMicroseconds: () => fixture['nativeClockMicroseconds'] as int) : classifier;
      final saved = row.containsKey('savedFields') ? NativeLogin5V3Response.decode(_input(row['savedFields'] as Map<String, dynamic>)) : null;
      var result = owner.classify(decoded, savedResponse: saved);
      if (result is NativeLogin5SavedResponseFallback) {
        expect(result.attemptIncrement, expected['savedResponseAttemptIncrement']);
        result = owner.classify(result.response);
      } else if (expected.containsKey('savedResponseAttemptIncrement')) {
        expect(expected['savedResponseAttemptIncrement'], 0);
      }
      switch (expected['kind']) {
        case 'failure':
          expect(result, isA<NativeLogin5Failure>(), reason: row['name'] as String);
          expect((result as NativeLogin5Failure).code, expected['code'], reason: row['name'] as String);
        case 'ok':
          final ok = result as NativeLogin5Success;
          expect({'kind': 'ok', 'username': ok.username, 'accessToken': ok.accessToken,
            'storedCredentialHex': hex.encode(ok.storedCredential), 'tokenType': ok.tokenType,
            'expiresAtMicroseconds': ok.expiresAtMicroseconds}, expected, reason: row['name'] as String);
        case 'signup':
          final signup = result as NativeLogin5SignupRequired, info = signup.userInfo;
          expect({'kind': 'signup', 'identifierToken': signup.identifierToken, 'userInfo': {
            'name': info.name, 'email': info.email, 'emailVerified': info.emailVerified, 'birthdate': info.birthdate,
            'gender': info.gender, 'phoneNumber': info.phoneNumber, 'phoneNumberVerified': info.phoneNumberVerified,
            'emailAlreadyRegistered': info.emailAlreadyRegistered}}, expected, reason: row['name'] as String);
        case 'challenges': expect(result, isA<NativeLogin5ChallengeContinuation>(), reason: row['name'] as String);
      }
    }
    for (final entry in (fixture['errorMessages'] as Map<String, dynamic>).entries) {
      final failure = NativeLogin5Failure(int.parse(entry.key));
      expect(failure.category, fixture['category']);
      expect(failure.message, entry.value);
    }
  });

  test('C++ wire corpus preserves numeric oneof replacement/merge and native body rejection boundaries', () {
    for (final item in fixture['wireCases'] as List<dynamic>) {
      final row = item as Map<String, dynamic>, expected = row['cppResult'] as Map<String, dynamic>;
      final bytes = hex.decode(row['hex'] as String);
      // Empty wire is a valid protobuf default message, but original HTTP200
      // completion rejects an empty body before dispatch.
      if (expected['accepted'] == false || bytes.isEmpty) {
        expect(() => NativeLogin5V3Response.decode(bytes), throwsA(isA<NativeLogin5Failure>().having((e) => e.code, 'code', 2)), reason: row['name'] as String);
        continue;
      }
      final NativeLogin5V3Response result;
      try { result = NativeLogin5V3Response.decode(bytes); }
      catch (error) { fail('${row['name']}: $error'); }
      expect(result.kind.name, expected['kind'], reason: row['name'] as String);
      if (result.kind == NativeLogin5V3ResponseKind.error) expect(result.backendError, expected['error']);
      if (expected.containsKey('userInfoGender')) expect(result.userInfoGender, expected['userInfoGender']);
      if (result.kind == NativeLogin5V3ResponseKind.ok) {
        expect(result.ok!.username, expected['username'], reason: row['name'] as String);
        expect(result.ok!.accessToken, expected['access_token'], reason: row['name'] as String);
      }
    }
  });

  test('Final empty-challenge continuation copies native context and retains rebuilt credential bytes', () {
    for (final item in fixture['emptyChallengeContinuationCases'] as List<dynamic>) {
      final row = item as Map<String, dynamic>;
      final decoded = NativeLogin5V3Response.decode(proto.LoginResponse(challenges: proto.Challenges(),
        loginContext: hex.decode(row['loginContextHex'] as String)).writeToBuffer());
      final continuation = classifier.classify(decoded) as NativeLogin5ChallengeContinuation;
      final request = continuation.withSolutions(proto.ChallengeSolutions());
      expect(hex.encode(request.writeToBuffer()), (row['result'] as Map<String, dynamic>)['hex']);
    }
  });

  test('Injected hashcash answers retain original suffix and nanosecond Duration mapping including signed remainder', () {
    for (final item in fixture['durationCases'] as List<dynamic>) {
      final row = item as Map<String, dynamic>;
      final answer = nativeLogin5HashcashAnswer(suffix: hex.decode(row['suffixHex'] as String),
        elapsedNanoseconds: row['elapsedNanoseconds'] as int);
      expect(hex.encode(answer.writeToBuffer()), (row['solution'] as Map<String, dynamic>)['hex'], reason: '${row['elapsedNanoseconds']}ns');
    }
  });
}

List<int> _input(Map<String, dynamic> fields) {
  final response = proto.LoginResponse();
  if (fields['1'] case final Map value) {
    response.ok = proto.LoginOk(username: value['1'] as String?, accessToken: value['2'] as String?,
      storedCredential: value['3'] == null ? null : hex.decode((value['3'] as Map)['hex'] as String), accessTokenExpiresIn: value['4'] as int?);
  }
  if (fields.containsKey('3')) response.challenges = proto.Challenges();
  if (fields['6'] case final String token) response.identifierToken = token;
  final writer = CodedBufferWriter()..writeRawBytes(response.writeToBuffer());
  if (fields['7'] case final Map values) {
    final info = user.UserInfo(name: values['1'] as String?, email: values['2'] as String?, emailVerified: values['3'] == 1,
      birthdate: values['4'] as String?, phoneNumber: values['6'] as String?, phoneNumberVerified: values['7'] == 1,
      emailAlreadyRegistered: values['8'] == 1);
    final nested = CodedBufferWriter()..writeRawBytes(info.writeToBuffer());
    if (values['5'] case final int gender) nested.writeField(5, PbFieldType.O3, gender);
    writer.writeField(7, PbFieldType.OPTIONAL_BYTES, nested.toBuffer());
  }
  if (fields['2'] case final int error) writer.writeField(2, PbFieldType.O3, error);
  if (fields.isEmpty) writer.writeField(9, PbFieldType.O3, 0);
  return writer.toBuffer();
}
