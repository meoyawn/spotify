import 'dart:convert';

/// A preserved JSON value cannot yet be written with the original formatter.
/// Callers must propagate this rather than overwrite unknown preference data.
final class NativeLegacyAuthJsonUnsupported extends UnsupportedError {
  NativeLegacyAuthJsonUnsupported(super.message);
}

final class NativeLegacySavedEntry {
  const NativeLegacySavedEntry({required this.username, required this.blob});
  final String username;
  final String blob;
}

/// Pure legacy preference JSON policy from 0x1018edd7c/1018ee058/1018ee2a8/
/// 1018eeae8. Writes admit string-array maps; other preserved value shapes
/// remain explicitly unsupported until their formatter is reproduced.
abstract final class NativeLegacyAuthJson {
  static String? update(String saved, {required String canonicalUsername,
    required String username, required String blob}) {
    if (canonicalUsername.isEmpty) return null;
    final root = _root(saved) ?? <String, Object?>{};
    root[_cstr(canonicalUsername)] = [username, blob];
    return _write(root);
  }

  static String? remove(String saved, String canonicalUsername) {
    if (canonicalUsername.isEmpty) return null;
    final root = _root(saved);
    if (root == null) return null;
    // The native remover compares the full supplied string against C-string
    // source keys. Unlike lookup/update, it does not truncate its argument.
    root.remove(canonicalUsername);
    return _write(root);
  }

  static NativeLegacySavedEntry? lookup(String saved, String canonicalUsername) {
    final root = _root(saved);
    final value = root?[_cstr(canonicalUsername)];
    if (value is! List || value.length < 2) return null;
    return NativeLegacySavedEntry(username: value[0] is String ? _cstr(value[0] as String) : '',
      blob: value[1] is String ? _cstr(value[1] as String) : '');
  }

  static List<String> canonicalUsernames(String saved) {
    final root = _root(saved);
    if (root == null) return const [];
    return root.keys.where((key) => root[key] is List && (root[key] as List).isNotEmpty).toList()
      ..sort(_compareUtf8);
  }
}

Map<String, Object?>? _root(String saved) {
  final Object? parsed;
  try { parsed = jsonDecode(saved); } on FormatException { return null; }
  if (parsed is! Map<String, dynamic>) return null;
  if (parsed.keys.any((key) => key.contains('\u0000'))) {
    throw NativeLegacyAuthJsonUnsupported('NUL-containing source keys need the original collision policy');
  }
  void check(Object? value) {
    if (value is double && !value.isFinite) {
      throw NativeLegacyAuthJsonUnsupported('Non-finite legacy JSON numbers are outside the recovered input boundary');
    }
    if (value is List) { for (final child in value) { check(child); } }
    if (value is Map) { for (final child in value.values) { check(child); } }
  }
  check(parsed);
  return parsed.cast<String, Object?>();
}

String _write(Map<String, Object?> root) {
  for (final value in root.values) {
    if (value is! List || value.any((element) => element is! String)) {
      throw NativeLegacyAuthJsonUnsupported('Preserved legacy JSON writes currently require arrays of strings');
    }
  }
  final keys = root.keys.toList()..sort(_compareUtf8);
  return '{${keys.map((key) => '${_quote(key)}:[${(root[key] as List).map((value) => _quote(value as String)).join(',')}]').join(',')}}';
}

String _cstr(String value) {
  final end = value.indexOf('\u0000');
  return end < 0 ? value : value.substring(0, end);
}

int _compareUtf8(String a, String b) {
  final left = utf8.encode(a), right = utf8.encode(b);
  final count = left.length < right.length ? left.length : right.length;
  for (var i = 0; i < count; i++) { if (left[i] != right[i]) return left[i] - right[i]; }
  return left.length - right.length;
}

String _quote(String value) {
  // Standard JSON supplies quoting. Normalize only the separately observed
  // native C-string/control/U+2028/U+2029 serialization boundary.
  final encoded = jsonEncode(_cstr(value));
  final out = StringBuffer();
  for (var i = 0; i < encoded.length; i++) {
    final character = encoded[i];
    if (character != '\\') { out.write(character); continue; }
    final escape = encoded[++i];
    const controls = {'b': r'\u0008', 'f': r'\u000c', 'n': r'\u000a', 'r': r'\u000d', 't': r'\u0009'};
    if (controls.containsKey(escape)) { out.write(controls[escape]); continue; }
    if (escape == 'u') {
      final digits = encoded.substring(i + 1, i + 5).toLowerCase();
      if (digits == '2028' || digits == '2029') {
        out.writeCharCode(int.parse(digits, radix: 16));
      } else {
        out.write('\\u$digits');
      }
      i += 4;
      continue;
    }
    out.write('\\$escape');
  }
  return out.toString();
}
