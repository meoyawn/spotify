import 'dart:async';
import 'dart:convert';

import 'request_builder.dart';

/// The installed module 31120 serializes this envelope across the native bridge.
class CosmosRequest {
  CosmosRequest(
    this.method,
    this.uri, {
    Map<String, String> headers = const {},
    Object? body,
  }) : headers = {
         for (final entry in headers.entries)
           entry.key.toLowerCase(): entry.value,
       },
       body = body == null || body == false || body == 0
           ? ''
           : body is String
           ? body
           : jsJson(body);
  final String method, uri, body;
  final Map<String, String> headers;
  String stringify() =>
      jsJson({'headers': headers, 'body': body, 'method': method, 'uri': uri});
}

class CosmosResponse {
  const CosmosResponse(this.status, this.body, {this.headers = const {}});
  final int status;
  final Object? body;
  final Map<String, String> headers;
  bool get ok => status >= 200 && status <= 299;
  factory CosmosResponse.parse(String value) {
    final map = jsonDecode(value) as Map<String, dynamic>;
    final status = map['status'] as int;
    final body = status >= 200 && status <= 299 ? map['body'] as String? : null;
    return CosmosResponse(
      status,
      body == null || body.isEmpty ? <String, Object?>{} : jsonDecode(body),
      headers: (map['headers'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(k.toLowerCase(), '$v'),
      ),
    );
  }
}

/// Local service dispatch replaces the proprietary process bridge.
/// No URI is forwarded to a socket or to the original application.
class CosmosRouter {
  final _handlers =
      <String, FutureOr<CosmosResponse> Function(CosmosRequest)>{};
  final _messages = StreamController<({String uri, Object? body})>.broadcast(
    sync: true,
  );

  void register(
    String uri,
    FutureOr<CosmosResponse> Function(CosmosRequest) handler,
  ) {
    final scheme = Uri.parse(uri).scheme;
    if (scheme != 'sp' && scheme != 'hm') {
      throw ArgumentError('Internal service URI required');
    }
    if (_handlers.containsKey(uri)) {
      throw StateError('Service already registered');
    }
    _handlers[uri] = handler;
  }

  Future<CosmosResponse> resolve(CosmosRequest request) async {
    final handler = _handlers[request.uri];
    return handler == null
        ? const CosmosResponse(404, {'error': 'Service not implemented'})
        : await handler(request);
  }

  Stream<Object?> subscribe(String uri, {bool prefix = false}) => _messages
      .stream
      .where((m) => prefix ? m.uri.startsWith(uri) : m.uri == uri)
      .map((m) => m.body);
  void publish(String uri, Object? body) =>
      _messages.add((uri: uri, body: body));
  Future<void> close() => _messages.close();
}
