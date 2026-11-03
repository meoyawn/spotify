import 'dart:async';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:http/http.dart' as http;

import '../async/cancellation.dart';
import '../protocol/generated/storage-resolve.pb.dart';
import '../protocol/native_login5_credentials.dart';
import '../protocol/native_login5_response.dart';
import '../protocol/native_legacy_auth_codec.dart';
import 'audio_source.dart';
import 'engine.dart';
import 'spotify_ap.dart';
import 'spotify_ap_session.dart';
import 'spotify_audio_decrypt.dart';
import 'spotify_audio_stager.dart';
import 'spotify_login_session.dart';
import 'spotify_media_client.dart';
import 'spotify_media_source.dart';
import 'spotify_metadata.dart';

/// Complete Dart playback acquisition path. Every peer/header/account/file
/// policy is explicit; construction sends nothing and grants no entitlement.
class SpotifyPlaybackSession {
  SpotifyPlaybackSession({required this.login, required this.createAp,
    required this.mediaClientFactory, required this.selectAudio, required this.selectCdn,
    required this.stager, required this.rangeBytes}) {
    if (rangeBytes <= 0) throw ArgumentError.value(rangeBytes, 'rangeBytes');
  }
  final SpotifyLoginSession login;
  /// Receives the original ordinary Login5-success projection: kind 1 with
  /// the returned username and stored bytes. The HTTP access token stays with
  /// its own owner and is never substituted into the AP stored credential.
  final Future<SpotifyApSession> Function(NativeLegacyCredential) createAp;
  final SpotifyMediaClient Function(NativeLogin5Success) mediaClientFactory;
  /// Must enforce actual metadata statuses, account and advert restrictions.
  /// The peer exposes verified Welcome, raw packets and parsed ProductInfo.
  final FutureOr<SpotifyAudioSelection> Function(SpotifyEntityMetadata, SpotifyApSession) selectAudio;
  final String Function(StorageResolveResponse) selectCdn;
  final SpotifyAudioStager stager;
  final int rangeBytes;
  final _keys = <SpotifyAudioKeyRequest>{};
  final _files = <PreparedAudioFile>{};
  final _bodies = <StreamIterator<List<int>>>{};
  SpotifyApSession? _ap, _connecting;
  PlaybackEngine? _engine;
  String? _username;
  int _generation = 0;
  bool _closed = false;
  Future<void> _teardown = Future<void>.value();
  Future<void>? _closing;
  CancellationToken _cancellation = CancellationToken();

  bool get ready => !_closed && _ap?.state == SpotifyApSessionState.ready;
  void bindEngine(PlaybackEngine engine) {
    if (_closed) throw StateError('Playback session is closed');
    if (_engine != null && !identical(_engine, engine) && _files.isNotEmpty) {
      throw StateError('Unload playback before replacing its output owner');
    }
    _engine = engine;
  }

  Future<NativeLogin5Success> authenticate(NativeLogin5Credential credential,
      {CancellationToken? cancellationToken}) async {
    if (_closed) throw StateError('Playback session is closed');
    final cleanup = _invalidate();
    final generation = _generation;
    final owner = _cancellation;
    final operation = cancellationToken == null ? owner : owner.merge(cancellationToken);
    await cleanup;
    operation.throwIfCancelled();
    _check(generation);
    SpotifyApSession? candidate;
    try {
      final token = await login.authenticate(credential, cancellationToken: operation);
      operation.throwIfCancelled();
      _check(generation);
      final apCredential = NativeLegacyCredential.login5Success(token);
      if (apCredential.authenticationType < 0) {
        throw const FormatException('Login5 did not supply a valid AP stored credential');
      }
      candidate = await createAp(apCredential);
      operation.throwIfCancelled();
      _check(generation);
      _connecting = candidate;
      final welcome = await candidate.start(cancellationToken: operation);
      operation.throwIfCancelled();
      _check(generation);
      if (welcome.canonicalUsername != token.username) throw StateError('AP account differs from the authenticated account');
      _connecting = null;
      _ap = candidate;
      _username = token.username;
      return token;
    } catch (_) {
      await candidate?.close();
      if (generation == _generation) {
        _connecting = null;
        login.signOut();
      }
      rethrow;
    }
  }

  Future<PreparedAudioFile> resolve(String uri, {CancellationToken? cancellationToken}) async {
    final operation = CancellationToken();
    final token = MergedCancellationToken([_cancellation, operation,
      if (cancellationToken != null) cancellationToken]);
    token.throwIfCancelled();
    if (!RegExp(r'^spotify:(track|episode):[A-Za-z0-9]{22}$').hasMatch(uri)) {
      throw ArgumentError.value(uri, 'uri', 'Expected a Spotify track or episode URI');
    }
    final generation = _generation, ap = _ap;
    _check(generation, ap: ap, requirePeer: true);
    final access = await login.accessToken(cancellationToken: token);
    token.throwIfCancelled();
    _check(generation, ap: ap, requirePeer: true);
    if (access.username != _username) throw StateError('Refreshed token belongs to a different account');
    final owned = mediaClientFactory(access);
    final client = SpotifyMediaClient(requests: owned.requests, send: (request) async {
      _check(generation, ap: ap, requirePeer: true);
      token.throwIfCancelled();
      final response = await owned.send(request.withCancellation(token));
      try { token.throwIfCancelled(); _check(generation, ap: ap, requirePeer: true); }
      catch (_) { await response.stream.listen(null).cancel(); rethrow; }
      return http.StreamedResponse(_body(response.stream, generation, ap!, token), response.statusCode,
        contentLength: response.contentLength, headers: response.headers, reasonPhrase: response.reasonPhrase,
        request: response.request, isRedirect: response.isRedirect, persistentConnection: response.persistentConnection);
    });
    final entity = (await SpotifyMetadataRepository(client).fetch([uri], cancellationToken: token)).forUri(uri);
    token.throwIfCancelled();
    _check(generation, ap: ap, requirePeer: true);
    if (entity.problem != null) throw FormatException('Metadata ${entity.problem!.name} for $uri');
    final selection = await Future.sync(() => selectAudio(entity, ap!)).asCancellable(token);
    _check(generation, ap: ap, requirePeer: true);
    final source = SpotifyMediaSource(client: client, stager: stager, rangeBytes: rangeBytes,
      selectCdn: selectCdn, selectAudio: (requested, {cancellationToken}) async {
        _check(generation, ap: ap, requirePeer: true);
        token.throwIfCancelled();
        if (requested != uri) throw StateError('Audio selection changed entity');
        return selection;
      }, obtainDecryption: (selected, {cancellationToken}) async {
        _check(generation, ap: ap, requirePeer: true);
        token.throwIfCancelled();
        final keyCancellation = MergedCancellationToken([token, ?cancellationToken]);
        keyCancellation.throwIfCancelled();
        final request = ap!.requestAudioKey(fileId: selected.fileId, trackGid: selected.trackGid,
          cancellationToken: keyCancellation);
        _keys.add(request);
        try {
          final key = await request.key.asCancellable(keyCancellation);
          _check(generation, ap: ap, requirePeer: true);
          return SpotifyAudioDecryptor.encrypted(key);
        } finally { _keys.remove(request); }
      });
    final file = await source.resolve(uri, cancellationToken: token);
    try { token.throwIfCancelled(); _check(generation, ap: ap, requirePeer: true); }
    catch (_) { await file.close(); rethrow; }
    late final PreparedAudioFile lease;
    lease = PreparedAudioFile(path: file.path, metadata: file.metadata,
      encoding: file.encoding, progress: file.progress, release: () async {
      operation.cancel();
      _files.remove(lease);
      await file.close();
    });
    _files.add(lease);
    return lease;
  }

  Stream<List<int>> _body(Stream<List<int>> input, int generation, SpotifyApSession ap,
      CancellationToken token) async* {
    final iterator = StreamIterator(input);
    _bodies.add(iterator);
    final cleanup = CancellationRegistration(token, onCancel: (_) { unawaited(iterator.cancel()); });
    try {
      _check(generation, ap: ap, requirePeer: true);
      token.throwIfCancelled();
      while (await iterator.moveNext().asCancellable(token)) {
        _check(generation, ap: ap, requirePeer: true);
        token.throwIfCancelled();
        yield iterator.current;
      }
      _check(generation, ap: ap, requirePeer: true);
    } finally {
      cleanup.dispose();
      _bodies.remove(iterator);
      await iterator.cancel();
    }
  }

  void _check(int generation, {SpotifyApSession? ap, bool requirePeer = false}) {
    if (_closed || generation != _generation) throw StateError('Playback session changed');
    if (requirePeer && (ap == null || !identical(ap, _ap) || ap.state != SpotifyApSessionState.ready)) {
      throw StateError('Sign in before playing Spotify audio');
    }
  }

  Future<void> signOut() => _closed ? (_closing ?? Future<void>.value()) : _invalidate();
  Future<void> _invalidate() {
    _cancellation.cancel();
    _cancellation = CancellationToken();
    _generation++;
    login.signOut();
    final peers = {_ap, _connecting}.whereType<SpotifyApSession>().toList();
    _ap = _connecting = null;
    _username = null;
    for (final request in _keys.toList()) { request.cancel(); }
    final bodies = _bodies.toList(), files = _files.toList();
    Future<void> release() async {
      try { await Future.wait([_unload(), ...bodies.map((body) => body.cancel())]); }
      finally { await Future.wait(peers.map((peer) => peer.close())); }
      await Future.wait(files.map((file) => file.close()));
    }
    return _teardown = _teardown.then((_) => release(), onError: (Object _, StackTrace _) => release());
  }

  Future<void> _unload() async {
    final engine = _engine;
    if (engine == null) return;
    final result = Completer<void>(), early = <PlayerJson>[];
    int? id;
    void receive(PlayerJson event) {
      if (event['type'] != 'command_completed' || event['command'] != 'unload') return;
      if (id == null) { early.add(event); return; }
      if (event['request_id'] != id || result.isCompleted) return;
      if (event['ok'] == true) { result.complete(); }
      else { result.completeError(StateError(event['error']?.toString() ?? 'Audio output could not unload')); }
    }
    final subscription = engine.events.listen(receive, onError: (Object error) {
      if (!result.isCompleted) result.completeError(error);
    }, onDone: () {
      if (!result.isCompleted) result.completeError(StateError('Audio output closed before unloading'));
    });
    try {
      final receipt = await engine.command('unload');
      id = receipt['request_id'] as int?;
      if (id == null) throw StateError('Unload receipt has no request identity');
      for (final event in early) { receive(event); }
      await result.future;
    } finally { await subscription.cancel(); }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    final cleanup = _invalidate();
    login.close();
    await cleanup;
  }
}
