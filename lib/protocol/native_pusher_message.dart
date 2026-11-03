import 'dart:convert';
import 'dart:typed_data';

/// Native text-message branch101419854 and header/payload helpers101419480,
///1014195c0/101418ff0. Request commands have a separate acknowledgement owner;
/// parsing an incoming message never manufactures an acknowledgement.
class NativePusherMessage {
  NativePusherMessage._(this.uri, this.headers, this.payloads);
  final String uri;
  final Map<String, String> headers;
  final List<Uint8List> payloads;

  factory NativePusherMessage.fromText(String text) {
    final object = jsonDecode(text);
    if (object is! Map || object['type'] != 'message') {
      throw UnsupportedError('This native push frame is not a message');
    }
    final uri = object['uri'];
    if (uri is! String || uri.isEmpty) throw const FormatException('Native push message has no URI');
    final rawHeaders = object['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw const FormatException('Native push header is not text');
        }
        headers[entry.key as String] = entry.value as String;
      }
    }
    final type = (headers['content-type'] ?? headers['Content-Type'] ?? '').toLowerCase();
    final payloads = <Uint8List>[];
    final rawPayloads = object['payloads'];
    if (rawPayloads is List) {
      for (final value in rawPayloads) {
        if (type.startsWith('application/json')) {
          if (value is! Map) throw const FormatException('Native JSON push payload is not an object');
          payloads.add(Uint8List.fromList(utf8.encode(jsonEncode(value))));
        } else if (type.startsWith('text/')) {
          if (value is! String) throw const FormatException('Native text push payload is not text');
          payloads.add(Uint8List.fromList(utf8.encode(value)));
        } else {
          if (value is! String) throw const FormatException('Native binary push payload is not encoded text');
          payloads.add(base64.decode(value));
        }
      }
    }
    return NativePusherMessage._(uri, Map.unmodifiable(headers), List.unmodifiable(payloads));
  }
}
