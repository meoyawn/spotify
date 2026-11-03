import 'package:flutter/services.dart';
import 'package:cancellation_token/cancellation_token.dart';

/// Only standard macOS preferences and external-browser primitives cross this
/// boundary. Accounts, HTTP, session and playback decisions stay in Dart.
class DesktopHost {
  const DesktopHost();
  static const _channel = MethodChannel('spotify_flutter/desktop_host');

  Future<List<String>> appleLanguages({CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final languages = await _channel.invokeListMethod<String>('appleLanguages');
    cancellationToken?.throwIfCancelled();
    return List.unmodifiable(languages ?? const <String>[]);
  }

  Future<void> openExternalUrl(String url, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final opened = await _channel.invokeMethod<bool>('openExternalUrl', url);
    cancellationToken?.throwIfCancelled();
    if (opened != true) throw StateError('The browser could not open the sign-in page');
  }

  Future<void> showWindow({CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    await _channel.invokeMethod<void>('showWindow');
    cancellationToken?.throwIfCancelled();
  }

  Future<void> closeWindow() => _channel.invokeMethod<void>('closeWindow');
}
