import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:spotify_flutter/transport/quiche/client.dart';

/// Developer entry point for exercising the bundled dependency in Flutter.
/// The peer is local; no Spotify session or credentials are used.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final result = checkLocalPeer();
  runApp(_SmokeApp(result));
}

Future<String> checkLocalPeer() async {
    const certificate = String.fromEnvironment('QUICHE_PEER_CERTIFICATE');
    const port = int.fromEnvironment('QUICHE_PEER_PORT');
    if (certificate.isEmpty || port == 0) {
      return 'Start test/support/http3_loopback_server.py and supply the local peer settings.';
    }
    final temporary = await Directory.systemTemp.createTemp('quiche-smoke-');
    final trusted = File('${temporary.path}/peer.pem');
    await trusted.writeAsBytes(base64Decode(certificate));
    final client = QuicheHttp3Client.bundled(trustedCertificatesPath: trusted.path);
    try {
      final response = await client.get(Uri.parse('https://localhost:$port/flutter'));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200 || body['protocol'] != 'h3') {
        throw StateError('Unexpected local peer response');
      }
      final result = 'quiche ${client.version}\nHTTP/3: ${response.statusCode}\n'
        'Loaded inside Flutter process $pid';
      debugPrint(result);
      return result;
    } finally {
      client.close();
      await temporary.delete(recursive: true);
    }
}

class _SmokeApp extends StatelessWidget {
  const _SmokeApp(this.result);
  final Future<String> result;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HTTP/3 transport check',
    theme: ThemeData.dark(),
    home: Scaffold(body: Center(child: FutureBuilder<String>(
      future: result,
      builder: (context, snapshot) => Padding(padding: const EdgeInsets.all(32),
        child: SelectableText(snapshot.hasError ? '${snapshot.error}' :
          snapshot.data ?? 'Connecting to the local HTTP/3 peer…',
          textAlign: TextAlign.center)),
    ))),
  );
}
