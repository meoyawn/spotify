import '../protocol/native_login5_credentials.dart';
import '../protocol/native_login5_exchange.dart';
import '../protocol/native_login5_response.dart';
import 'package:cancellation_token/cancellation_token.dart';
import '../async/shared_task.dart';
/// On-demand Login5 token ownership over the existing native-compatible exchange.
/// The caller supplies identity, credentials, transport/challenges and the clock.
/// This owner reads no storage and creates no timers, retries or OAuth refreshes.
final class SpotifyLoginSession {
  SpotifyLoginSession({required this.exchange, required this.credentials,
    required this.nowMicroseconds});

  final NativeLogin5V3Exchange exchange;
  final NativeLogin5Credentials credentials;
  final int Function() nowMicroseconds;
  NativeLogin5Success? _cached;
  NativeLogin5StoredCredential? _stored;
  NativeLogin5V3Run? _run;
  SharedTask<NativeLogin5Success>? _active;
  CancellationToken _cancellation = CancellationToken();
  var _generation = 0;
  var _closed = false;

  /// Explicit authentication replaces the previous account, even if it fails.
  Future<NativeLogin5Success> authenticate(NativeLogin5Credential credential,
      {CancellationToken? cancellationToken}) {
    if (_closed) return Future.error(StateError('Spotify login session is closed'));
    _clear();
    return _start(credential).wait(cancellationToken);
  }

  Future<NativeLogin5Success> accessToken({CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (_closed) return Future.error(StateError('Spotify login session is closed'));
    final active = _active;
    if (active != null && !active.token.isCancelled) return active.wait(cancellationToken);
    final cached = _cached;
    if (cached != null && nowMicroseconds() < cached.expiresAtMicroseconds) {
      return Future.value(cached);
    }
    final stored = _stored;
    if (stored == null) return Future.error(StateError('Spotify login session is signed out'));
    _cached = null;
    return _start(stored).wait(cancellationToken);
  }

  void signOut() => _clear();

  void close() {
    if (_closed) return;
    _closed = true;
    _clear();
  }

  SharedTask<NativeLogin5Success> _start(NativeLogin5Credential credential) {
    final generation = _generation;
    return _active = SharedTask((token) {
      final run = exchange.start(credentials: credentials, credential: credential,
        cancellationToken: _cancellation.merge(token));
      if (_closed || generation != _generation) run.cancel();
      _run = run;
      return _complete(run, generation);
    });
  }

  Future<NativeLogin5Success> _complete(NativeLogin5V3Run run, int generation) async {
    try {
      final result = await run.result;
      if (_closed || generation != _generation) throw const NativeLogin5Failure(1);
      // Preserve failures/signup outcomes rather than relabeling them as tokens.
      if (result is! NativeLogin5Success) throw result;
      _cached = result;
      _stored = NativeLogin5StoredCredential(username: result.username,
        data: result.storedCredential);
      return result;
    } catch (_) {
      if (_closed || generation != _generation) throw const NativeLogin5Failure(1);
      rethrow;
    } finally {
      if (identical(_run, run) && generation == _generation) {
        _run = null;
        _active = null;
      }
    }
  }

  void _clear() {
    _cancellation.cancel();
    _cancellation = CancellationToken();
    _generation++;
    final previous = _run;
    _run = null;
    _active = null;
    _cached = null;
    _stored = null;
    previous?.cancel();
  }
}
