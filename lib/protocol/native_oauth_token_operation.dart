import 'package:cancellation_token/cancellation_token.dart';

import 'native_oauth_refresh.dart';
import 'native_token_provider.dart';

/// Connects the established refresh response/state rules to the native token
/// owner's start/observation/stop interface. Each send requires real abort.
class NativeOAuthTokenOperation implements NativeTokenRefreshOperation {
  NativeOAuthTokenOperation({required this.refresh, required this.sendOwned,
    required this.onError});
  final NativeOAuthRefresh refresh;
  final NativeOAuthRefreshSendOwner sendOwned;
  /// Parser or other unclassified failures retain their Dart identity. The
  /// native numeric exception translation has not been established. An owner
  /// using NativeTokenProvider must supervise/close it on this path, since its
  /// result interface accepts only the established native result variants.
  final void Function(Object error, StackTrace stackTrace) onError;
  NativeOAuthRefreshRun? _run;
  _Observation? _observation;
  bool _stopped = false;

  @override
  NativeTokenCancel start(void Function(NativeTokenRefreshResult result) callback) {
    if (_stopped) return () {};
    if (_run != null) throw StateError('Native OAuth token refresh is already running');
    final observation = _Observation(callback);
    _observation = observation;
    final run = refresh.startOwned(sendOwned: sendOwned);
    _run = run;
    // A sender/proof factory can synchronously stop its operation while the
    // run is being created. Attach the returned owner before honoring that stop.
    if (_stopped) run.cancel();
    run.result.then<void>((token) {
      _completed(run);
      if (_stopped || observation.detached) return;
      observation.detach();
      observation.callback(NativeTokenRefreshSuccess(NativeAccessToken(
        accessToken: token.accessToken, tokenType: token.tokenType,
        expiresAtMicroseconds: token.expiresAtMicroseconds)));
    }, onError: (Object error, StackTrace stackTrace) {
      _completed(run);
      if (_stopped || observation.detached) return;
      observation.detach();
      if (error is NativeOAuthRefreshFailure) {
        observation.callback(NativeTokenRefreshFailure(error.code));
      } else {
        onError(error, stackTrace);
      }
    });
    return observation.detach;
  }

  void _completed(NativeOAuthRefreshRun run) {
    if (identical(_run, run)) {
      _run = null;
      _observation = null;
    }
  }

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _observation?.detach();
    _observation = null;
    _run?.cancel();
    _run = null;
  }
}

class _Observation {
  _Observation(this.callback);
  final void Function(NativeTokenRefreshResult result) callback;
  final cancellationToken = CancellationToken();
  bool get detached => cancellationToken.isCancelled;
  void detach() { cancellationToken.cancel(); }
}
