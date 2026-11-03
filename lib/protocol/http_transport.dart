import 'package:http/http.dart' as http;

import 'request_builder.dart';

/// Only loopback conformance traffic is currently admitted. Native transport
/// additions and authentication have not yet been proven against captures.
class DartHttpTransport {
  DartHttpTransport(this._client);
  final http.Client _client;

  Future<http.Response> send(RequestEnvelope envelope) async =>
    http.Response.fromStream(await sendStream(envelope));

  Future<http.StreamedResponse> sendStream(RequestEnvelope envelope) async {
    final uri = Uri.parse(envelope.url);
    if (uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw StateError(
        'Live Spotify transport is unverified. No request was sent.',
      );
    }
    if (uri.toString() != envelope.url) {
      throw StateError('URI normalization changed the captured request');
    }
    final request = http.Request(envelope.method, uri)
      ..followRedirects = false
      ..headers.addAll(envelope.headers)
      ..bodyBytes = envelope.body;
    return _client.send(request);
  }

  void close() => _client.close();
}
