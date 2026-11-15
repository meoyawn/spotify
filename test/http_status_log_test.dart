import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Persisted radio HTTP diagnostics redact the seed song URI', () async {
    final directory = await Directory.systemTemp.createTemp('song-radio-log-');
    try {
      final process = await Process.run('dart', ['run', 'test/support/http_status_log_probe.dart', directory.path]);
      expect(process.exitCode, 0, reason: process.stderr as String);
      final text = await File('${directory.path}/http.jsonl').readAsString();
      final records = const LineSplitter().convert(text).map((line) => jsonDecode(line) as Map).toList();
      final requests = records.where((row) => row['event'] == 'request' || row['event'] == 'response').toList();
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request['path'], '/inspiredby-mix/v2/seed_to_playlist/:id');
        expect(request['host'], 'spclient.wg.spotify.com');
      }
      expect(text, isNot(contains('4uLU6hMCjMI75M1A2tKUQC')));
      expect(text, isNot(contains('response-format')));
    } finally { await directory.delete(recursive: true); }
  });
}
