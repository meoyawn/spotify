import 'dart:typed_data';

/// Original URI constructor101f4476c/parser101f44454 stores the16-byte
/// Track identifier at link+0x40. The original parser is independently executed
/// in reverse-engineering/fixtures/native-spotify-gid.json; alphabet/order also match the pinned
/// public librespot SpotifyId implementation. No metadata GID is invented.
Uint8List nativeSpotifyTrackGid(String uri) {
  final match = RegExp(r'^spotify:track:([0-9A-Za-z]{22})$').firstMatch(uri);
  if (match == null) throw FormatException('Expected a Spotify track URI', uri);
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var value = BigInt.zero;
  for (final code in match.group(1)!.codeUnits) {
    value = value * BigInt.from(62) + BigInt.from(alphabet.indexOf(String.fromCharCode(code)));
  }
  if (value.bitLength > 128) throw const FormatException('Spotify track identifier exceeds128 bits');
  final result = Uint8List(16);
  for (var i = 15; i >= 0; i--) { result[i] = (value & BigInt.from(255)).toInt(); value >>= 8; }
  return result;
}

/// Inverse of the verified original/public base62 codec. This encodes an
/// actual metadata GID; it never substitutes a canonical or guessed identity.
String nativeSpotifyTrackUri(List<int> gid) => nativeSpotifyEntityUri('track', gid);

/// Artist and album identities in metadata use the same public128-bit/base62
/// primitive. The type belongs to the metadata field, never to a name lookup.
String nativeSpotifyEntityUri(String type, List<int> gid) {
  if (!const {'track', 'artist', 'album'}.contains(type)) {
    throw ArgumentError.value(type, 'type', 'Unsupported metadata entity type');
  }
  if (gid.length != 16 || gid.any((byte) => byte < 0 || byte > 255)) {
    throw const FormatException('A Spotify metadata GID must contain16 octets');
  }
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var value = BigInt.zero;
  for (final byte in gid) { value = (value << 8) | BigInt.from(byte); }
  final output = List.filled(22, '0');
  for (var index = 21; index >= 0; index--) {
    output[index] = alphabet[(value % BigInt.from(62)).toInt()];
    value ~/= BigInt.from(62);
  }
  return 'spotify:$type:${output.join()}';
}
