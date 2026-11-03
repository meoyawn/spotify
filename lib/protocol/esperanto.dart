import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:protobuf/protobuf.dart';
import 'package:cancellation_token/cancellation_token.dart';

/// The native call envelope from original embedded module 76148.
class EsperantoCall {
  EsperantoCall(this.service, this.method, List<int> payload)
    : _payload = Uint8List.fromList(payload);

  final String service;
  final String method;
  final Uint8List _payload;
  Uint8List get payload => Uint8List.fromList(_payload);

  Uint8List encode() {
    final fields = [utf8.encode(service), utf8.encode(method), _payload];
    final output = Uint8List(fields.fold(12, (n, field) => n + field.length));
    final view = ByteData.sublistView(output);
    var offset = 0;
    for (final field in fields) {
      view.setInt32(offset, field.length, Endian.big);
      output.setRange(offset + 4, offset + 4 + field.length, field);
      offset += field.length + 4;
    }
    return output;
  }

  factory EsperantoCall.decode(List<int> input) {
    final bytes = Uint8List.fromList(input);
    final view = ByteData.sublistView(bytes);
    var offset = 0;
    Uint8List read() {
      if (offset + 4 > bytes.length) {
        throw const FormatException('Truncated Esperanto field length');
      }
      final length = view.getInt32(offset, Endian.big);
      offset += 4;
      if (length < 0 || length > bytes.length - offset) {
        throw const FormatException('Invalid Esperanto field length');
      }
      final value = Uint8List.sublistView(bytes, offset, offset + length);
      offset += length;
      return value;
    }

    final service = utf8.decode(read());
    final method = utf8.decode(read());
    final payload = read();
    if (offset != bytes.length) {
      throw const FormatException('Trailing Esperanto frame bytes');
    }
    return EsperantoCall(service, method, payload);
  }
}

typedef SingleHandler = FutureOr<List<int>> Function(Uint8List request);
typedef CancellableSingleHandler = FutureOr<List<int>> Function(Uint8List request, CancellationToken cancellationToken);
typedef StreamingHandler = Stream<List<int>> Function(Uint8List request);

class EsperantoService {
  EsperantoService({
    Map<String, SingleHandler> single = const {},
    Map<String, CancellableSingleHandler> cancellableSingle = const {},
    Map<String, StreamingHandler> streaming = const {},
  }) : single = Map.unmodifiable(single),
       cancellableSingle = Map.unmodifiable(cancellableSingle),
       streaming = Map.unmodifiable(streaming);
  final Map<String, SingleHandler> single;
  final Map<String, CancellableSingleHandler> cancellableSingle;
  final Map<String, StreamingHandler> streaming;
}

/// In-process named dispatch replaces executeEsperantoCall/cancelEsperantoCall.
/// Service implementations are registered explicitly; unknown methods fail.
class EsperantoDispatcher {
  final _services = <String, EsperantoService>{};
  void register(String id, EsperantoService service) {
    if (_services.containsKey(id)) {
      throw StateError('Service already registered: $id');
    }
    _services[id] = service;
  }

  Future<Uint8List> callSingle(EsperantoCall call, {CancellationToken? cancellationToken}) async {
    final token = cancellationToken ?? CancellationToken();
    token.throwIfCancelled();
    final handler = _services[call.service]?.single[call.method];
    final cancellable = _services[call.service]?.cancellableSingle[call.method];
    if (handler == null && cancellable == null) {
      throw UnsupportedError(
        'Unimplemented Esperanto method: ${call.service}.${call.method}',
      );
    }
    final result = await Future.sync(() => cancellable != null ? cancellable(call.payload, token) : handler!(call.payload))
      .asCancellable(token);
    token.throwIfCancelled();
    return Uint8List.fromList(result);
  }

  Stream<Uint8List> callStream(EsperantoCall call) {
    final handler = _services[call.service]?.streaming[call.method];
    if (handler == null) {
      return Stream.error(
        UnsupportedError(
          'Unimplemented Esperanto stream: ${call.service}.${call.method}',
        ),
      );
    }
    return handler(call.payload).map(Uint8List.fromList);
  }
}

/// Typed clients use the generated original protobuf models and this local bus.
class EsperantoClient {
  const EsperantoClient(this.service, this.dispatcher);
  final String service;
  final EsperantoDispatcher dispatcher;
  Future<T> single<T extends GeneratedMessage>(
    String method,
    GeneratedMessage request,
    T Function(List<int>) decode,
  ) async {
    final response = await dispatcher.callSingle(
      EsperantoCall(service, method, request.writeToBuffer()),
    );
    return decode(response);
  }

  Stream<T> streaming<T extends GeneratedMessage>(
    String method,
    GeneratedMessage request,
    T Function(List<int>) decode,
  ) => dispatcher
      .callStream(EsperantoCall(service, method, request.writeToBuffer()))
      .map(decode);
}
