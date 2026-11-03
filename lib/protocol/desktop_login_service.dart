import 'package:protobuf/protobuf.dart';

import 'esperanto.dart';
import 'generated/es_desktop_login.pb.dart' as proto;
import 'native_protobuf.dart';

class DesktopStoredAccount {
  const DesktopStoredAccount({required this.username, required this.canonicalUsername});
  final String username;
  final String canonicalUsername;
}

/// The owning Dart session/storage component supplies these local operations.
/// Their persistence and authentication lifecycle are outside this projection.
abstract interface class DesktopLoginAccess {
  String currentUsername();
  List<DesktopStoredAccount> storedAccounts();
  bool saveCurrentCredentials();
  void clearAllStoredCredentials();
  void removeStoredAccount(String canonicalUsername);
  void setSwitchTarget(String canonicalUsername);
  String switchTarget();
  void clearSwitchTarget();
}

/// Native local state, credential and switch handlers. Authentication methods
/// remain unregistered until their session/task owners are implemented.
class DesktopLoginService {
  const DesktopLoginService(this.access);
  static const id = 'spotify.desktop.login_esperanto.proto.DesktopLogin';
  final DesktopLoginAccess access;

  void register(EsperantoDispatcher dispatcher) {
    dispatcher.register(id, EsperantoService(single: {
      'GetSessionState': (bytes) {
        _read(bytes, proto.GetSessionStateRequest());
        final username = access.currentUsername();
        return nativeProto3Bytes(proto.GetSessionStateResponse(
          hasActiveSession: username.isNotEmpty, username: username));
      },
      'GetStoredAccounts': (bytes) {
        _read(bytes, proto.GetStoredAccountsRequest());
        final accounts = access.storedAccounts();
        return nativeProto3Bytes(proto.GetStoredAccountsResponse(accounts: accounts.map(
          (account) => proto.StoredAccountInfo(username: account.username,
            canonicalUsername: account.canonicalUsername))));
      },
      'SaveCurrentCredentials': (bytes) {
        _read(bytes, proto.SaveCurrentCredentialsRequest());
        return nativeProto3Bytes(proto.SaveCurrentCredentialsResponse(success: access.saveCurrentCredentials()));
      },
      'ClearAllStoredCredentials': (bytes) {
        _read(bytes, proto.ClearAllStoredCredentialsRequest());
        access.clearAllStoredCredentials();
        return proto.ClearAllStoredCredentialsResponse().writeToBuffer();
      },
      'RemoveStoredAccount': (bytes) {
        final request = _read(bytes, proto.RemoveStoredAccountRequest());
        access.removeStoredAccount(request.canonicalUsername);
        return proto.RemoveStoredAccountResponse().writeToBuffer();
      },
      'SetSwitchTarget': (bytes) {
        final request = _read(bytes, proto.SetSwitchTargetRequest());
        access.setSwitchTarget(request.canonicalUsername);
        return proto.SetSwitchTargetResponse().writeToBuffer();
      },
      'GetSwitchTarget': (bytes) {
        _read(bytes, proto.GetSwitchTargetRequest());
        return nativeProto3Bytes(proto.GetSwitchTargetResponse(canonicalUsername: access.switchTarget()));
      },
      'ClearSwitchTarget': (bytes) {
        _read(bytes, proto.ClearSwitchTargetRequest());
        access.clearSwitchTarget();
        return proto.ClearSwitchTargetResponse().writeToBuffer();
      },
    }));
  }
}

T _read<T extends GeneratedMessage>(List<int> bytes, T message) {
  validateNativeProto3Strings(bytes, message);
  message.mergeFromBuffer(bytes);
  return message;
}
