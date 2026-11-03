import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../transport/quiche/client.dart' show Http3ConnectionException;

/// App-owned diagnostics only. Request fields and response streams pass through
/// unchanged; disk IO is serialized in a bounded background queue.
final class HttpStatusLog {
  HttpStatusLog._(this.directory, this.mode);
  final Directory directory;
  final String mode;
  static const maxFileBytes = 1024 * 1024;
  static const retainedFiles = 4;
  static const _maxPending = 256, _maxRecordBytes = 2048;
  static HttpStatusLog? _active;
  final _pending = Queue<List<int>>();
  RandomAccessFile? _output;
  Future<void>? _writing;
  int _length = 0, _sequence = 0, _dropped = 0;
  bool _warned = false;
  File get _file => File('${directory.path}/http.jsonl');

  static Future<void> initialize({required Directory directory, required String mode}) async {
    if (_active != null) return;
    final log = HttpStatusLog._(directory, mode);
    try {
      await directory.create(recursive: true);
      await log._open();
      _active = log;
      log._add({'event': 'logger_started', 'max_file_bytes': maxFileBytes,
        'retained_files': retainedFiles});
    } catch (error) {
      try { await log._output?.close(); } catch (_) { /* Logging stays optional. */ }
      log._warn(error);
    }
  }

  static Future<http.StreamedResponse> observe({required String method,
    required String url, required String transport,
    required Future<http.StreamedResponse> Function() send}) async {
    final log = _active;
    if (log == null) return send();
    final id = ++log._sequence;
    final timer = Stopwatch()..start();
    final request = {'request_id': id, 'method': method,
      'transport': transport, ..._endpoint(url)};
    log._add({'event': 'request', ...request});
    try {
      final response = await send();
      final retryAfter = response.headers['retry-after'];
      log._add({'event': 'response', ...request, 'status': response.statusCode,
        'headers_ms': timer.elapsedMilliseconds,
        if (retryAfter != null) 'retry_after': _clip(retryAfter, 128)});
      return response;
    } catch (error) {
      final osError = error is SocketException ? error.osError?.errorCode :
        error is Http3ConnectionException ? error.osErrorCode : null;
      log._add({'event': 'transport_error', ...request,
        'error_type': _clip('${error.runtimeType}', 80), 'elapsed_ms': timer.elapsedMilliseconds,
        if (osError != null) 'os_error': osError});
      rethrow;
    }
  }

  // No headers, bodies, userinfo, query, fragment, account names or opaque IDs.
  // In particular, CDN signatures and music-license file IDs never reach disk.
  static Map<String, Object> _endpoint(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      final parts = uri.pathSegments;
      final safe = <String>[];
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final identifier = i > 0 && const {'user', 'users', 'devices', 'image'}.contains(parts[i - 1]) ||
          RegExp(r'^[A-Za-z0-9_-]{22,}(?:\.[A-Za-z0-9]+)?$').hasMatch(part) ||
          RegExp(r'[0-9a-fA-F]{16,}').hasMatch(part);
        safe.add(identifier ? ':id' : part);
      }
      return {'host': _clip(uri.host, 253), 'path': _clip('/${safe.join('/')}', 384)};
    } on FormatException { return {'path': '<invalid-url>'}; }
  }

  static String _clip(String value, int limit) => value.length <= limit ? value : value.substring(0, limit);

  void _add(Map<String, Object?> fields) {
    if (_pending.length >= _maxPending) { _dropped++; return; }
    final bytes = utf8.encode('${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(),
      'mode': mode, 'pid': pid, ...fields, if (_dropped > 0) 'dropped_records': _dropped})}\n');
    if (bytes.length > _maxRecordBytes) { _dropped++; return; }
    _dropped = 0;
    _pending.add(bytes);
    _writing ??= _drain();
  }

  Future<void> _open() async {
    _output = await _file.open(mode: FileMode.append);
    _length = await _output!.length();
  }

  Future<void> _rotate() async {
    await _output?.close(); _output = null;
    final oldest = File('${_file.path}.${retainedFiles - 1}');
    if (await oldest.exists()) await oldest.delete();
    for (var index = retainedFiles - 2; index >= 0; index--) {
      final source = index == 0 ? _file : File('${_file.path}.$index');
      if (await source.exists()) await source.rename('${_file.path}.${index + 1}');
    }
    await _open();
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        final bytes = _pending.removeFirst();
        if (_output == null) await _open();
        if (_length + bytes.length > maxFileBytes) await _rotate();
        await _output!.writeFrom(bytes);
        _length += bytes.length;
      }
    } catch (error) {
      _dropped += _pending.length + 1;
      _pending.clear();
      try { await _output?.close(); } catch (_) { /* Preserve the logging failure. */ }
      _output = null;
      _warn(error);
    } finally { _writing = null; }
  }

  void _warn(Object error) {
    if (_warned) return;
    _warned = true;
    stderr.writeln('HTTP diagnostic log is unavailable (${error.runtimeType}).');
  }
}
