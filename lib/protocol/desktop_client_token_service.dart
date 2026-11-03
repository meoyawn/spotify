import 'dart:async';

import 'package:fixnum/fixnum.dart' show Int64;
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart' show Empty;

import 'esperanto.dart';
import 'generated/es_client_token.pb.dart' as proto;
import 'native_client_token_provider.dart';

/// Native service 0x1019398c8 and generated dispatcher 0x10193a93c.
/// Plain token acquisition is single-call; encrypted token changes are a stream.
class DesktopClientTokenService {
  const DesktopClientTokenService(this.provider);
  static const id = 'spotify.connectivity.auth.client_token.esperanto.proto.ClientTokenProvider';
  final NativeClientTokenProvider provider;

  void register(EsperantoDispatcher dispatcher) {
    dispatcher.register(id, EsperantoService(single: {'getToken': (request) {
      Empty.fromBuffer(request);
      final response = Completer<List<int>>();
      // The current local single-call dispatcher exposes a Future, without a
      // cancellation handle. The provider's callback API remains cancelable.
      provider.acquire((result) => response.complete(_response(result).writeToBuffer()));
      return response.future;
    }}, streaming: {'getEncryptedToken': (request) {
      Empty.fromBuffer(request);
      late StreamController<List<int>> stream;
      NativeClientTokenCancel? cancel;
      stream = StreamController<List<int>>(onListen: () {
        cancel = provider.observeEncryptedTokens((encoded) {
          stream.add(proto.EncryptedClientToken(encryptedToken: encoded).writeToBuffer());
        });
      }, onCancel: () { cancel?.call(); });
      return stream.stream;
    }}));
  }

  proto.AcquireResult _response(NativeClientTokenResult result) {
    if (result is NativeClientTokenFailure) {
      return proto.AcquireResult(failure: proto.AcquireFailure(code: result.code.toSigned(32),
        message: result.message));
    }
    final token = (result as NativeClientTokenSuccess).token;
    return proto.AcquireResult(token: proto.ClientToken(token: token.token,
      expiresAtTimestamp: Int64(token.expiresAtMicroseconds ~/ 1000),
      refreshAtTimestamp: Int64(token.refreshAtMicroseconds ~/ 1000),
      clientDataHash: token.clientDataHash, domains: token.domains));
  }
}
