import 'dart:convert';
import 'dart:typed_data';

// Native Base64Decode(...,0) requires complete unpadded quartets. A first '='
// after 2/3 alphabet bytes in the final quartet ends decoding and ignores the remaining input. Keep
// that boundary, then canonicalize for the standard Dart decoder; URL-safe and
// percent/whitespace normalization would accept inputs rejected by the native.
Uint8List? decodeNativeBase64(String value) {
  final padding = value.indexOf('=');
  final end = padding < 0 ? value.length : padding;
  var prefix = value.substring(0, end);
  if (prefix.contains(RegExp(r'[^A-Za-z0-9+/]'))) return null;
  final remainder = end % 4;
  if (padding < 0) {
    if (remainder != 0) return null;
  } else {
    if (remainder != 2 && remainder != 3) return null;
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final last = alphabet.indexOf(prefix[prefix.length - 1]);
    prefix = '${prefix.substring(0, prefix.length - 1)}${alphabet[last & (remainder == 2 ? 0x30 : 0x3c)]}';
    prefix += '=' * (4 - remainder);
  }
  return base64.decode(prefix);
}
