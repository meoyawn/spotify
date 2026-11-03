import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/native_image_request.dart' show nativeImagePublicUrlAllowed;

/// App-owned public artwork only, populated by this app's verified HTTP loader
/// with the response's actual cache policy. Credentials and cookies are absent.
class ArtworkDiskCache {
  ArtworkDiskCache._(this.directory, this._entries);
  final Directory directory;
  final Map<String, Map<String, Object?>> _entries;
  Future<void> _writes = Future<void>.value();

  static Future<ArtworkDiskCache> open(Directory directory) async {
    await directory.create(recursive: true);
    var entries = <String, Map<String, Object?>>{};
    final index = File('${directory.path}/index.json');
    try {
      if (await index.exists()) {
        final data = jsonDecode(await index.readAsString()) as Map;
        if (data['version'] == 1) {
          entries = {for (final entry in (data['entries'] as Map).entries)
            if (_publicUrl('${entry.key}') && entry.value is Map)
              '${entry.key}': (entry.value as Map).cast<String, Object?>()};
        }
      }
    } on FileSystemException { /* A missing/broken cache never blocks streaming. */ }
    on FormatException { /* Leave an incomplete index out of the active cache. */ }
    on TypeError { /* An invalid index is cache data, not application state. */ }
    return ArtworkDiskCache._(directory, entries);
  }

  Future<Uint8List?> read(String url) async {
    if (!_publicUrl(url)) return null;
    final entry = _entries[url];
    if (entry == null) return null;
    final expires = DateTime.tryParse('${entry['expiresUtc']}');
    final name = entry['file'], expected = entry['sha256'];
    if (expires == null || !expires.isAfter(DateTime.now().toUtc()) ||
        name is! String || !RegExp(r'^[0-9a-f]{64}\.image$').hasMatch(name) ||
        expected is! String) return null;
    try {
      final bytes = await File('${directory.path}/$name').readAsBytes();
      if (sha256.convert(bytes).toString() != expected) return null;
      return bytes;
    } on FileSystemException { return null; }
  }

  Future<void> storeResponse(String url, Uint8List bytes, Map<String, String> headers) async {
    if (!_publicUrl(url) || bytes.isEmpty) return;
    final control = (headers['cache-control'] ?? '').toLowerCase();
    final directives = control.split(',').map((value) => value.trim()).toList();
    if (directives.any((value) => const {'no-cache', 'no-store', 'must-revalidate'}.contains(value)) ||
        (headers['vary'] ?? '').isNotEmpty || headers.containsKey('set-cookie')) return;
    final age = RegExp(r'(?:^|,)\s*max-age\s*=\s*"?([0-9]+)').firstMatch(control)?.group(1);
    final seconds = int.tryParse(age ?? '');
    if (seconds == null || seconds <= 0) return;
    DateTime origin;
    try { origin = HttpDate.parse(headers['date'] ?? ''); }
    on HttpException { return; }
    final expires = origin.add(Duration(seconds: seconds));
    if (!expires.isAfter(DateTime.now().toUtc())) return;
    await _store(url, bytes, expires);
    await flush();
  }

  Future<void> _store(String url, Uint8List bytes, DateTime expires) async {
    final digest = sha256.convert(bytes).toString(), name = '${sha256.convert(utf8.encode(url))}.image';
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    _entries[url] = {'file': name, 'sha256': digest, 'expiresUtc': expires.toUtc().toIso8601String()};
  }

  Future<void> flush() => _writes = _writes.catchError((Object _) {}).then((_) async {
    final temporary = File('${directory.path}/index.json.tmp');
    await temporary.writeAsString(jsonEncode({'version': 1, 'entries': _entries}), flush: true);
    await temporary.rename('${directory.path}/index.json');
  });
}

bool _publicUrl(String value) => nativeImagePublicUrlAllowed(value);
