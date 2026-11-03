import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:quic_lib/quic.dart';

/// Checks the advertised high-level connection path against a local UDP peer.
Future<void> main() async {
  final peer = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  var datagrams = 0;
  final subscription = peer.listen((event) {
    if (event == RawSocketEvent.read) {
      while (peer.receive() != null) { datagrams++; }
    }
  });
  final endpoint = await QuicEndpoint.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final connection = await endpoint.connect(InternetAddress.loopbackIPv4, peer.port);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final result = {'package': 'quic_lib 1.13.0', 'scope': 'Public QuicEndpoint.connect path against a local UDP peer',
      'outboundDatagrams': datagrams, 'established': connection.isEstablished,
      'serverNameOrTrustConfigurationOnConnect': false};
    stdout.writeln(jsonEncode(result));
  } finally {
    endpoint.close(); await subscription.cancel(); peer.close();
  }
}
