import 'dart:typed_data';

import 'package:fixnum/fixnum.dart' show Int64;
import 'package:protobuf/protobuf.dart' show CodedBufferReader, CodedBufferWriter, GeneratedMessage, GeneratedMessageGenericExtensions, InvalidProtocolBufferException, PbFieldType, UnknownFieldSet;
import 'package:protobuf/well_known_types/google/protobuf/duration.pb.dart' as duration;

import 'generated/spotify/login5/v3/login5.pb.dart' as proto;
import 'generated/spotify/login5/v3/user_info.pb.dart' as user;
import 'generated/spotify/login5/v3/challenges/hashcash.pb.dart' as hashcash;
import 'native_login5_credentials.dart';
import 'native_protobuf.dart';

enum NativeLogin5V3ResponseKind { notSet, ok, error, challenges }

/// Parsed wire state. Selected response fields are separate from generated
/// metadata because protobuf.dart loses unknown numeric enum oneof presence.
class NativeLogin5V3Response {
  NativeLogin5V3Response._(this.kind, this.backendError, this.ok, this.challenges, this._metadata, this.userInfoGender, List<int> bytes)
    : wireBytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final NativeLogin5V3ResponseKind kind;
  final int? backendError;
  final proto.LoginOk? ok;
  final proto.Challenges? challenges;
  final proto.LoginResponse _metadata;
  final int userInfoGender;
  final Uint8List wireBytes;
  String get identifierToken => _metadata.identifierToken;
  Uint8List get loginContext => Uint8List.fromList(_metadata.loginContext).asUnmodifiableView();
  NativeLogin5UserInfo? get userInfo => _metadata.hasUserInfo() ? NativeLogin5UserInfo._(_metadata.userInfo, userInfoGender) : null;

  /// Standard generated parsing owns wire validation and metadata. A narrow
  /// standard-reader pass owns selected-oneof numeric enum compatibility.
  static NativeLogin5V3Response decode(List<int> bytes) {
    // Native HTTP-200 completion rejects empty/rejected bodies with error 2.
    if (bytes.isEmpty) throw const NativeLogin5Failure(2);
    try {
      return _decodeWire(bytes);
    } on InvalidProtocolBufferException {
      throw const NativeLogin5Failure(2);
    } on FormatException {
      throw const NativeLogin5Failure(2);
    } on ArgumentError {
      throw const NativeLogin5Failure(2);
    }
  }

  static NativeLogin5V3Response _decodeWire(List<int> bytes) {
    validateNativeProto3Strings(bytes, proto.LoginResponse());
    final reader = CodedBufferReader(bytes);
    final metadataFields = UnknownFieldSet(), oneofUnknownFields = UnknownFieldSet();
    var kind = NativeLogin5V3ResponseKind.notSet, gender = 0;
    int? error;
    proto.LoginOk? ok;
    proto.Challenges? challenges;
    while (true) {
      final tag = reader.readTag();
      if (tag == 0) break;
      if (tag == 10) {
        if (kind != NativeLogin5V3ResponseKind.ok) ok = proto.LoginOk();
        ok!.mergeFromBuffer(reader.readBytes());
        kind = NativeLogin5V3ResponseKind.ok;
        error = null;
        challenges = null;
      } else if (tag == 16) {
        error = reader.readEnum();
        kind = NativeLogin5V3ResponseKind.error;
        ok = null;
        challenges = null;
      } else if (tag == 26) {
        if (kind != NativeLogin5V3ResponseKind.challenges) challenges = proto.Challenges();
        challenges!.mergeFromBuffer(_forGeneratedParser(reader.readBytes(), proto.Challenges()));
        kind = NativeLogin5V3ResponseKind.challenges;
        error = null;
        ok = null;
      } else if (tag == 58) {
        // Ordinary UserInfo messages merge across occurrences. Preserve the
        // last raw gender enum even if Dart's generated enum getter cannot.
        final payload = reader.readBytes();
        metadataFields.mergeLengthDelimitedField(7, payload);
        final nested = CodedBufferReader(payload);
        while (!nested.isAtEnd()) {
          final innerTag = nested.readTag();
          if (innerTag == 40) { gender = nested.readEnum(); }
          else if (!nested.skipField(innerTag)) { break; }
        }
      } else {
        // Dart also accepts length-delimited wire type for a singular enum,
        // then misreads the length as its value. Keep wrong-wire oneof fields
        // in the standard unknown-field container instead of generated parse.
        final fields = tag >> 3 <= 3 ? oneofUnknownFields : metadataFields;
        if (!fields.mergeFieldFromBuffer(tag, reader)) throw const FormatException('Unexpected end group');
      }
    }
    final metadataWriter = CodedBufferWriter();
    metadataFields.writeToCodedBufferWriter(metadataWriter);
    final metadata = proto.LoginResponse.fromBuffer(_forGeneratedParser(metadataWriter.toBuffer(), proto.LoginResponse()));
    metadata.unknownFields.mergeFromUnknownFieldSet(oneofUnknownFields);
    metadata.clearResponse();
    metadata.freeze();
    ok?.freeze();
    challenges?.freeze();
    return NativeLogin5V3Response._(kind, error, ok, challenges, metadata, gender, bytes);
  }
}

// Public protobuf readers/writers own wire encoding and validation. This
// adapter removes only wrong-wire singular enum fields from the generated
// view, recursively, because Dart incorrectly treats them as packed enums.
// The complete original bytes remain available on the decoded response.
Uint8List _forGeneratedParser(List<int> bytes, GeneratedMessage schema) {
  final reader = CodedBufferReader(bytes), writer = CodedBufferWriter();
  while (true) {
    final tag = reader.readTag();
    if (tag == 0) break;
    final field = schema.info_.fieldInfo[tag >> 3];
    final unknown = UnknownFieldSet();
    if (field != null && field.isEnum && !field.isRepeated && (tag & 7) != 0) {
      if (!unknown.mergeFieldFromBuffer(tag, reader)) throw const FormatException('Unexpected end group');
    } else if ((tag & 7) == 2 && field?.subBuilder != null) {
      writer.writeField(tag >> 3, PbFieldType.OPTIONAL_BYTES, _forGeneratedParser(reader.readBytes(), field!.subBuilder!()));
    } else {
      if (!unknown.mergeFieldFromBuffer(tag, reader)) throw const FormatException('Unexpected end group');
      unknown.writeToCodedBufferWriter(writer);
    }
  }
  return writer.toBuffer();
}

class NativeLogin5UserInfo {
  NativeLogin5UserInfo._(user.UserInfo value, this.gender)
    : name = value.name, email = value.email, emailVerified = value.emailVerified,
      birthdate = value.birthdate, phoneNumber = value.phoneNumber,
      phoneNumberVerified = value.phoneNumberVerified, emailAlreadyRegistered = value.emailAlreadyRegistered;
  final String name, email, birthdate, phoneNumber;
  final bool emailVerified, phoneNumberVerified, emailAlreadyRegistered;
  final int gender;
}

sealed class NativeLogin5V3Result {
  const NativeLogin5V3Result();
}

class NativeLogin5Failure extends NativeLogin5V3Result implements Exception {
  const NativeLogin5Failure(this.code);
  final int code;
  String get category => 'login5';
  String get message => switch (code) {
    0 => 'success', 1 => 'login5_aborted', 2 => 'login5_unsupported_response',
    3 => 'login5_non_successful_response', 4 => 'login5_http_transport_error',
    5 => 'login5_unsupported_authentication_method', 6 => 'login5_invalid_arguments',
    7 => 'login5_hash_mishmatch', 101 => 'login5_unknown_backend_error',
    102 => 'login5_invalid_credentials', 103 => 'login5_bad_request',
    104 => 'login5_unsupported_login_protocol', 105 => 'login5_timeout',
    106 => 'login5_unknown_identifier', 107 => 'login5_too_many_attempts',
    108 => 'login5_invalid_phone_number', 109 => 'login5_try_again_later', 110 => 'login5_not_allowed',
    _ => 'invalid_login5_error_${code.toSigned(32)}',
  };
  @override
  String toString() => '$category/$code: $message';
}

class NativeLogin5Success extends NativeLogin5V3Result {
  NativeLogin5Success({required this.username, required this.accessToken, required List<int> storedCredential,
    required this.expiresAtMicroseconds}) : storedCredential = Uint8List.fromList(storedCredential).asUnmodifiableView();
  final String username, accessToken;
  final Uint8List storedCredential;
  final int expiresAtMicroseconds;
  String get tokenType => 'Bearer';
}

class NativeLogin5SignupRequired extends NativeLogin5V3Result {
  const NativeLogin5SignupRequired({required this.identifierToken, required this.userInfo});
  final String identifierToken;
  final NativeLogin5UserInfo userInfo;
  int get gender => userInfo.gender;
}

/// The owner must redispatch the supplied saved response and add one to its
/// saved-response attempt counter; this is not an HTTP resend instruction.
class NativeLogin5SavedResponseFallback extends NativeLogin5V3Result {
  const NativeLogin5SavedResponseFallback(this.response);
  final NativeLogin5V3Response response;
  int get attemptIncrement => 1;
}

/// A challenge task directive, not a solver or UI callback implementation.
/// The initial request is rebuilt by the verified credential constructor.
class NativeLogin5ChallengeContinuation extends NativeLogin5V3Result {
  NativeLogin5ChallengeContinuation._(this.response, proto.LoginRequest request) : initialRequest = request..freeze();
  final NativeLogin5V3Response response;
  final proto.LoginRequest initialRequest;

  /// Maps the final native continuation's context copy after the owner has
  /// supplied its verified ordered appended solutions. SMS skip continues
  /// without appending, so solution count may be smaller than challenge count.
  proto.LoginRequest withSolutions(proto.ChallengeSolutions solutions) {
    final request = initialRequest.deepCopy();
    if (solutions.solutions.isNotEmpty) request.challengeSolutions = solutions.deepCopy();
    final context = response.loginContext;
    if (context.isNotEmpty) request.loginContext = context;
    return request;
  }
}

/// Worker answer mapping and native 0x1018ccf1c duration conversion. The solver
/// supplies exact elapsed nanoseconds; no microsecond clock is substituted.
proto.ChallengeSolution nativeLogin5HashcashAnswer({required List<int> suffix, required int elapsedNanoseconds}) {
  if (suffix.length != 16) throw ArgumentError('Native Login5 hashcash suffix is 16 bytes');
  final seconds = elapsedNanoseconds ~/ 1000000000;
  final nanos = elapsedNanoseconds.remainder(1000000000);
  return proto.ChallengeSolution(hashcash: hashcash.HashcashSolution(suffix: List<int>.of(suffix),
    duration: duration.Duration(seconds: seconds == 0 ? null : Int64(seconds), nanos: nanos == 0 ? null : nanos)));
}

/// Result projection from 0x1018bd248; parsing and HTTP completion ownership
/// stay separate so retry reset can occur before backend result dispatch.
class NativeLogin5V3Classifier {
  NativeLogin5V3Classifier({required this.credentials, required this.credential,
    required int Function() nowMicroseconds}) : _now = nowMicroseconds;
  final NativeLogin5Credentials credentials;
  final NativeLogin5Credential credential;
  final int Function() _now;

  NativeLogin5V3Result classify(NativeLogin5V3Response response, {NativeLogin5V3Response? savedResponse}) {
    switch (response.kind) {
      case NativeLogin5V3ResponseKind.ok:
        final ok = response.ok!;
        return NativeLogin5Success(username: ok.username, accessToken: ok.accessToken,
          storedCredential: ok.storedCredential, expiresAtMicroseconds: _now() + ok.accessTokenExpiresIn * 1000000);
      case NativeLogin5V3ResponseKind.challenges:
        return NativeLogin5ChallengeContinuation._(response, credentials.build(credential));
      case NativeLogin5V3ResponseKind.error:
        final error = response.backendError!;
        if (error == 5 && (response.identifierToken.isNotEmpty || response.userInfo != null)) {
          return NativeLogin5SignupRequired(identifierToken: response.identifierToken,
            userInfo: response.userInfo ?? NativeLogin5UserInfo._(user.UserInfo(), 0));
        }
        if (error == 1 && savedResponse != null && credential is NativeLogin5PhoneNumber) {
          return NativeLogin5SavedResponseFallback(savedResponse);
        }
        return NativeLogin5Failure(error >= 1 && error <= 9 ? error + 101 : 101);
      case NativeLogin5V3ResponseKind.notSet:
        return const NativeLogin5Failure(101);
    }
  }
}
