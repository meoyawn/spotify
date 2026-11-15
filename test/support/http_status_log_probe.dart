import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:spotify_flutter/diagnostics/http_status_log.dart';

Future<void> main(List<String> arguments) async {
  await HttpStatusLog.initialize(directory: Directory(arguments.single), mode: 'debug');
  final response = await HttpStatusLog.observe(method: 'GET', transport: 'h2-renderer',
    url: 'https://spclient.wg.spotify.com/inspiredby-mix/v2/seed_to_playlist/'
      'spotify:track:4uLU6hMCjMI75M1A2tKUQC?response-format=json',
    send: () async => http.StreamedResponse(const Stream.empty(), 200));
  await response.stream.drain<void>();
}
