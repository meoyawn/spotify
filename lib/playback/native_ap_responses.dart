import 'dart:typed_data';

import 'package:protobuf/protobuf.dart' show CodedBufferReader, CodedBufferWriter,
  GeneratedMessage, ProtobufEnum, UnknownFieldSet;

import 'generated/authentication.pb.dart' as auth;
import 'generated/keyexchange.pb.dart' as exchange;

/// Native AP enums are numeric fields, including values absent from the public
/// reference declarations. The generated model stays private: its typed enum
/// getters cannot cast a foreign ProtobufEnum. No account policy is inferred.
final class NativeApWelcome {
  NativeApWelcome._(this._message, List<int> bytes) : wireBytes = _bytes(bytes);
  factory NativeApWelcome.decode(List<int> bytes) {
    final message = _enums(bytes, auth.APWelcome.fromBuffer, {
      20: auth.AccountType.valueOf, 25: auth.AccountType.valueOf,
      30: auth.AuthenticationType.valueOf,
    });
    if (!message.isInitialized()) throw const FormatException('Missing AP Welcome fields');
    if (message.hasLfsSecret() && message.lfsSecret.length != 20) {
      throw const FormatException('AP Welcome lfs_secret must contain 20 bytes');
    }
    message.freeze();
    return NativeApWelcome._(message, bytes);
  }
  final auth.APWelcome _message;
  final Uint8List wireBytes;
  String get canonicalUsername => _message.canonicalUsername;
  int get accountTypeLoggedIn => (_message.getField(20) as ProtobufEnum).value;
  int get credentialsTypeLoggedIn => (_message.getField(25) as ProtobufEnum).value;
  int get reusableAuthCredentialsType => (_message.getField(30) as ProtobufEnum).value;
  Uint8List get reusableAuthCredentials => _bytes(_message.reusableAuthCredentials);
  Uint8List? get lfsSecret => _message.hasLfsSecret() ? _bytes(_message.lfsSecret) : null;
  auth.AccountInfo? get accountInfo => _message.hasAccountInfo() ? _message.accountInfo : null;
  auth.AccountInfoFacebook? get facebook => _message.hasFb() ? _message.fb : null;
}

final class NativeApLoginFailure {
  NativeApLoginFailure._(this._message, List<int> bytes) : wireBytes = _bytes(bytes);
  factory NativeApLoginFailure.decode(List<int> bytes) {
    final message = _enums(bytes, exchange.APLoginFailed.fromBuffer, {10: exchange.ErrorCode.valueOf});
    if (!message.isInitialized()) throw const FormatException('Missing AP failure fields');
    message.freeze();
    return NativeApLoginFailure._(message, bytes);
  }
  final exchange.APLoginFailed _message;
  final Uint8List wireBytes;
  int get errorCode => (_message.getField(10) as ProtobufEnum).value;
  int? get retryDelay => _message.hasRetryDelay() ? _message.retryDelay : null;
  int? get expiry => _message.hasExpiry() ? _message.expiry : null;
  String? get errorDescription => _message.hasErrorDescription() ? _message.errorDescription : null;
}

/// Challenge/upgrade fields keep the standard generated representation. The
/// only nested enum adaptation is APLoginFailed. Original outer bytes remain
/// intact; repeated ordinary login_failed payloads merge by concatenation.
final class NativeApResponse {
  NativeApResponse._(this.message, this.loginFailure, List<int> bytes) : wireBytes = _bytes(bytes);
  factory NativeApResponse.decode(List<int> bytes) {
    final reader = CodedBufferReader(bytes), fields = UnknownFieldSet(), wrongWire = UnknownFieldSet();
    final failure = BytesBuilder();
    var hasFailure = false;
    while (!reader.isAtEnd()) {
      final tag = reader.readTag();
      if (tag == 242) { failure.add(reader.readBytes()); hasFailure = true; }
      else { _unknown(tag >> 3 == 30 ? wrongWire : fields, tag, reader); }
    }
    final writer = CodedBufferWriter();
    fields.writeToCodedBufferWriter(writer);
    final message = exchange.APResponseMessage.fromBuffer(writer.toBuffer());
    final parsedFailure = hasFailure ? NativeApLoginFailure.decode(failure.takeBytes()) : null;
    if (parsedFailure != null) message.loginFailed = parsedFailure._message;
    message.unknownFields.mergeFromUnknownFieldSet(wrongWire);
    if (!message.isInitialized()) throw const FormatException('Missing AP response fields');
    if (message.hasChallenge()) {
      final challenge = message.challenge;
      if (challenge.serverNonce.length != 16) throw const FormatException('AP server nonce must contain 16 bytes');
      if (challenge.loginCryptoChallenge.hasDiffieHellman()) {
        final dh = challenge.loginCryptoChallenge.diffieHellman;
        if (dh.gs.length != 96 || dh.gsSignature.length != 256) {
          throw const FormatException('AP DH key/signature must contain 96/256 bytes');
        }
      }
    }
    message.freeze();
    return NativeApResponse._(message, parsedFailure, bytes);
  }
  /// Frozen. Use loginFailure for numeric error values, not its typed enum.
  final exchange.APResponseMessage message;
  final NativeApLoginFailure? loginFailure;
  final Uint8List wireBytes;
}

T _enums<T extends GeneratedMessage>(List<int> bytes, T Function(List<int>) parse,
    Map<int, ProtobufEnum? Function(int)> enumTypes) {
  final reader = CodedBufferReader(bytes), fields = UnknownFieldSet(), wrongWire = UnknownFieldSet();
  final numbers = <int, int>{};
  while (!reader.isAtEnd()) {
    final tag = reader.readTag(), number = tag >> 3;
    if (enumTypes.containsKey(number)) {
      if ((tag & 7) == 0) { numbers[number] = reader.readUint32(); }
      else { _unknown(wrongWire, tag, reader); }
    } else { _unknown(fields, tag, reader); }
  }
  final writer = CodedBufferWriter();
  fields.writeToCodedBufferWriter(writer);
  final message = parse(writer.toBuffer());
  for (final entry in numbers.entries) {
    message.setField(entry.key, enumTypes[entry.key]!(entry.value) ?? ProtobufEnum(entry.value, ''));
  }
  message.unknownFields.mergeFromUnknownFieldSet(wrongWire);
  return message;
}
void _unknown(UnknownFieldSet fields, int tag, CodedBufferReader reader) {
  if (!fields.mergeFieldFromBuffer(tag, reader)) throw const FormatException('Unexpected AP end-group');
}
Uint8List _bytes(List<int> value) => Uint8List.fromList(value).asUnmodifiableView();
