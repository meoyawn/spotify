import 'dart:convert';
import 'dart:typed_data';

import 'native_cef_request.dart';

/// Observable public CefRequest fields after Spotify's CEF adapter, before
/// browser URL-request / network-service processing. No connection is created.
class NativeCefRequestObjectPlan {
  NativeCefRequestObjectPlan._({required this.method, required this.url,
    required this.headers, required this.body, required this.flags});

  factory NativeCefRequestObjectPlan.fromAdapter(NativeCefRequestPlan input) =>
    NativeCefRequestObjectPlan._(method: input.method,
      url: _canonicalHttpUrl(input.urlInput),
      headers: List.unmodifiable(input.headers.where(
        (entry) => _asciiLower(entry.key) != 'referer')),
      body: input.body, flags: input.flags);

  final String method, url;
  final List<MapEntry<String, String>> headers;
  final Uint8List? body;
  final int flags;
}

/// HTTP(S) DNS/decimal IPv4 URL projection used by the native request profiles.
/// Preserve existing escape spelling in paths, queries and fragments. Dart
/// Uri.parse(...).toString() changes signed %2f / %7E query inputs.
String _canonicalHttpUrl(String value) {
  if (value.isEmpty) return '';
  if (value.contains('\\')) throw UnsupportedError('Backslash URLs are outside the verified native request profiles');
  final match = RegExp(r'^(https?)://([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$',
    caseSensitive: false, dotAll: true).firstMatch(value);
  if (match == null) throw UnsupportedError('CEF request projection requires an absolute HTTP(S) URL');
  final scheme = _asciiLower(match[1]!);
  final authority = RegExp(r'^([a-zA-Z0-9._-]+)(?::([0-9]+))?$').firstMatch(match[2]!);
  if (authority == null) throw UnsupportedError('CEF request projection requires an ASCII DNS or decimal IPv4 authority');
  final host = _asciiLower(authority[1]!);
  if (RegExp(r'(^|\.)[0-9]+\.?$').hasMatch(host)) {
    final parts = host.split('.');
    if (parts.length != 4 || parts.any((part) => !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(part) ||
        int.tryParse(part) == null || int.parse(part) > 255)) {
      throw UnsupportedError('Noncanonical numeric hosts are outside the verified native request profiles');
    }
  }
  var port = '';
  if (authority[2] case final raw?) {
    final number = int.tryParse(raw);
    if (number == null || number > 65535) throw const FormatException('Invalid HTTP port');
    if (number != (scheme == 'https' ? 443 : 80)) port = ':$number';
  }
  final path = _path(match[3]!.isEmpty ? '/' : match[3]!);
  final query = match[4] == null ? '' : '?${_escape(match[4]!.substring(1), query: true)}';
  final fragment = match[5] == null ? '' : '#${_escape(match[5]!.substring(1), fragment: true)}';
  return '$scheme://$host$port$path$query$fragment';
}

String _path(String value) {
  final input = value.split('/'), output = <String>[];
  final encodedDot = RegExp('%2e', caseSensitive: false);
  for (var index = 0; index < input.length; index++) {
    final segment = input[index], dots = segment.replaceAll(encodedDot, '.');
    if (dots == '.' || dots == '..') {
      if (dots == '..' && output.length > 1) output.removeLast();
      if (index == input.length - 1) output.add('');
    } else {
      output.add(_escape(segment));
    }
  }
  return output.join('/');
}

String _escape(String value, {bool query = false, bool fragment = false}) {
  final result = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final escaped = byte <= 32 || byte >= 127 || byte == 34 || byte == 60 || byte == 62 ||
      (query ? byte == 39 : fragment ? byte == 96 : const [96, 123, 125, 124, 94].contains(byte));
    if (escaped) {
      result.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      result.writeCharCode(byte);
    }
  }
  return result.toString();
}

String _asciiLower(String value) => String.fromCharCodes(value.codeUnits.map(
  (code) => code >= 65 && code <= 90 ? code + 32 : code));
