import 'dart:io';

// Retained expected bytes come from original execution/captures. Peers capture
// Dart's actual outgoing traffic locally and do not contact Spotify.
Future<void> main() async {
  const checks = [
    ('test/native_http_credentials_test.dart',
      'HTTP credential headers match original outgoing request captures'),
    ('test/native_http_credentials_test.dart',
      'Native response chain matches original next outgoing credential fields'),
    ('test/native_cef_http2_transport_test.dart',
      'Dart H2 sends original CEF and native app fields target and body'),
    ('test/quiche_transport_test.dart',
      'Native metadata playlist key and storage original fields and body reach the H3 peer'),
    ('test/native_renderer_http2_transport_test.dart',
      'Renderer Pathfinder sends original decoded fields and original Search Home album and artist body bytes'),
    ('test/native_renderer_http3_transport_test.dart',
      'Renderer production H3 sender preserves original Search Home album and artist requests'),
    ('test/native_renderer_http3_transport_test.dart',
      'Original renderer connection race dispatches each original body once'),
    ('test/native_renderer_cors_test.dart',
      'Renderer preflight fields permissions and cache gate original outgoing POST bytes'),
  ];
  for (final (path, name) in checks) {
    final process = await Process.start('flutter',
      ['test', '--no-pub', '--reporter', 'expanded', path, '--plain-name', name],
      mode: ProcessStartMode.inheritStdio);
    final result = await process.exitCode;
    if (result != 0) {
      exitCode = result;
      return;
    }
  }
  stdout.writeln('Original-backed outgoing HTTP checks passed.');
}
