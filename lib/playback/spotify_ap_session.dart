// Protocol models: pinned upstream reference, not exact macOS descriptors.
// Native login-complete barrier: FUN_1018f4bd0, Spotify1.3.6.1921 arm64,
// REA ev_c4d70a50f82dbbe93d111034ccebead33df61ea096d393d6e03da8ef17390a76.
import 'dart:async';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';
import 'generated/authentication.pb.dart' as auth;
import 'generated/keyexchange.pb.dart' as exchange;
import 'native_ap_responses.dart';
import 'native_product_state.dart';
import 'spotify_ap.dart';
import 'spotify_ap_handshake.dart';

enum SpotifyApSessionState { idle, handshaking, authenticating, ready, closed }

/// Both authentication messages are supplied by the native challenge policy.
/// Copies prevent a caller from changing either message after validation.
final class SpotifyApAuthenticationFrames {
  SpotifyApAuthenticationFrames({required exchange.ClientResponsePlaintext plaintext,
    required auth.ClientResponseEncrypted encrypted})
    : plaintext = plaintext.deepCopy()..freeze(), encrypted = encrypted.deepCopy()..freeze();
  final exchange.ClientResponsePlaintext plaintext;
  final auth.ClientResponseEncrypted encrypted;
}

final class SpotifyApAuthenticationException implements Exception {
  SpotifyApAuthenticationException(this.response);
  final NativeApLoginFailure response;
  Uint8List get wireBytes => response.wireBytes;
  @override
  String toString() => 'Spotify AP authentication rejected';
}

/// Transport-independent AP ownership with no implicit identity or credentials.
///
/// Byte writes are serialized. The caller owns the connected transport and its
/// verified keepalive policy; Ping/PongAck remain raw events, with no timers or
/// default Pong. Authentication protobufs are upstream reference models. Their
/// original native field projection, account/ad policy and resolver are separate
/// boundaries. Welcome alone never grants key access: empty native0x69 completion
/// and the actual Login write must also complete. Welcome uses a numeric native
/// projection so foreign enum values do not lose required presence or get labels.
final class SpotifyApSession {
  factory SpotifyApSession({required exchange.ClientHello clientHello,
      required FutureOr<SpotifyApAuthenticationFrames> Function(SpotifyApHandshakeResult) buildAuthentication,
      required Stream<Uint8List> incoming,
      required Future<void> Function(Uint8List bytes) sendBytes,
      required Future<void> Function() closeTransport,
      required bool Function(SpotifyApPacket packet) admitAuthenticationPacket,
      bool Function(SpotifyApPacket packet)? admitReadyPacket,
      void Function()? onStarted, void Function()? onWelcome, void Function()? onLoginComplete,
      bool Function()? isAuthenticationReady, bool requestNativeInitialKey = false}) {
    return SpotifyApSession._(SpotifyApHandshake(clientHello: clientHello), buildAuthentication,
      incoming, sendBytes, closeTransport, admitAuthenticationPacket, admitReadyPacket,
      onStarted, onWelcome, onLoginComplete, isAuthenticationReady, requestNativeInitialKey);
  }
  SpotifyApSession._(this._handshake, this._buildAuthentication, this._incoming, this._sendBytes,
    this._closeTransport, this._admitAuthenticationPacket, this._admitReadyPacket,
    this._onStarted, this._onWelcome, this._onLoginComplete, this._isAuthenticationReady, this._requestNativeInitialKey);
  SpotifyApHandshake? _handshake;
  FutureOr<SpotifyApAuthenticationFrames> Function(SpotifyApHandshakeResult)? _buildAuthentication;
  final Stream<Uint8List> _incoming;
  final Future<void> Function(Uint8List) _sendBytes;
  final Future<void> Function() _closeTransport;
  // Original native login owner delegates unknown opcodes to a separate owner.
  // Its policy remains a required caller input, with no invented default.
  final bool Function(SpotifyApPacket) _admitAuthenticationPacket;
  final bool Function(SpotifyApPacket)? _admitReadyPacket;
  final void Function()? _onStarted, _onWelcome, _onLoginComplete;
  final bool Function()? _isAuthenticationReady;
  final bool _requestNativeInitialKey;
  bool _initialKeyRequested = false;
  final _packets = StreamController<SpotifyApPacket>.broadcast();
  final _done = Completer<void>();
  final _attributes = <int, Uint8List>{};
  final _productState = NativeProductState();
  StreamSubscription<Uint8List>? _subscription;
  SpotifyApCodec? _codec;
  SpotifyAudioKeyManager? _keys;
  Completer<NativeApWelcome>? _authenticated;
  NativeApWelcome? _candidate, _welcome;
  Future<void> _outgoing = Future<void>.value();
  Future<void>? _closing;
  var _state = SpotifyApSessionState.idle;
  var _loginWritten = false, _nativeComplete = false;
  Object? _failure;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  CancellationRegistration? _parentCancellation;

  SpotifyApSessionState get state => _state;
  NativeApWelcome? get welcome => _welcome;
  Object? get failure => _failure;
  Future<void> get done => _done.future;
  /// Every decoded AP packet is MAC-verified before publication. Subscribe
  /// before start to observe all frames, including denial and completion.
  Stream<SpotifyApPacket> get packets => _packets.stream;
  /// Raw latest admitted CountryCode/ProductInfo/LicenseVersion/opaque state.
  /// These bytes do not imply an entitlement or credential interpretation.
  Map<int, Uint8List> get serverAttributes => Map.unmodifiable(_attributes);
  /// Latest successfully parsed original ProductInfo projection. These actual
  /// server attributes feed quality/restriction policy without a tier-name guess.
  Map<String, String> get productState => _productState.attributes;

  Future<NativeApWelcome> start({CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (_state == SpotifyApSessionState.closed) return Future.error(StateError('AP session is closed'));
    final active = _authenticated;
    if (active != null) return active.future.asCancellable(cancellationToken);
    final result = _authenticated = Completer<NativeApWelcome>();
    _parentCancellation = CancellationRegistration(cancellationToken,
      onCancel: (error) { unawaited(_terminate(error)); });
    _state = SpotifyApSessionState.handshaking;
    try {
      _onStarted?.call();
      final subscription = _incoming.listen(_receive, onError: (Object error, StackTrace stack) {
        unawaited(_terminate(error, stack));
      }, onDone: _eof);
      _subscription = subscription;
      if (_state == SpotifyApSessionState.closed) { unawaited(subscription.cancel()); }
      else { _write(_handshake!.clientHelloFrame); }
    } catch (error, stack) { unawaited(_terminate(error, stack)); }
    return result.future;
  }

  Future<void> sendPacket(SpotifyApPacket packet) {
    // The native connection can send its Pong after transport login completes,
    // while the separate initial-key rendezvous still holds account readiness.
    if (!(packet.command == 0x49 && _state == SpotifyApSessionState.authenticating &&
        _loginWritten && _nativeComplete)) {
      _requireReady();
    }
    if (packet.command == 0xab) throw StateError('AP Login is owned by this session');
    return _write(_codec!.encode(packet));
  }

  SpotifyAudioKeyRequest requestAudioKey({required List<int> fileId, required List<int> trackGid,
      CancellationToken? cancellationToken}) {
    _requireReady();
    return _keys!.request(fileId: fileId, trackGid: trackGid,
      cancellationToken: MergedCancellationToken([_token, ?cancellationToken]));
  }

  /// Original Welcome callback1018fa62c invokes1018f8d6c with a zero16-byte
  /// identifier and zero4-byte sequence. The independently executed original
  /// packet is opcode0x0f and20 zero bytes. The reply0x10 releases the native
  /// session barrier; it is separate from track audio-key requests0x0c/0x0d.
  Future<void> requestInitialSessionKey() {
    if (_candidate == null || _codec == null ||
        _state != SpotifyApSessionState.authenticating && _state != SpotifyApSessionState.ready) {
      throw StateError('AP Welcome is required before the initial key request');
    }
    if (_initialKeyRequested) return Future<void>.value();
    _initialKeyRequested = true;
    return _write(_codec!.encode(SpotifyApPacket(0x0f, Uint8List(20))));
  }

  void _receive(Uint8List bytes) {
    if (_state == SpotifyApSessionState.closed) return;
    try {
      final handshake = _handshake;
      if (handshake != null) {
        final result = handshake.addResponse(bytes);
        if (result == null) return;
        _handshake = null;
        _codec = SpotifyApCodec(sendKey: result.keys.sendKey, receiveKey: result.keys.receiveKey);
        _state = SpotifyApSessionState.authenticating;
        unawaited(_authenticate(result));
        if (_state != SpotifyApSessionState.closed) _decode(result.trailingBytes);
      } else {
        _decode(bytes);
      }
    } catch (error, stack) { unawaited(_terminate(error, stack)); }
  }

  Future<void> _authenticate(SpotifyApHandshakeResult result) async {
    if (_state == SpotifyApSessionState.closed) return;
    final build = _buildAuthentication!;
    _buildAuthentication = null;
    try {
      // The caller can derive native fingerprint fields from its nonce state
      // and this verified challenge; no static or default credentials are used.
      _token.throwIfCancelled();
      final frames = await Future.sync(() => build(result)).asCancellable(_token);
      _token.throwIfCancelled();
      if (_state == SpotifyApSessionState.closed) return;
      _validateAuthentication(frames, result);
      final body = frames.plaintext.writeToBuffer();
      if (body.length + 4 > SpotifyApHandshake.maxPacketSize) throw const SpotifyApProtocolException('AP plaintext response exceeds 64 KiB');
      final plaintext = Uint8List(body.length + 4)..setRange(4, body.length + 4, body);
      ByteData.sublistView(plaintext).setUint32(0, plaintext.length, Endian.big);
      final login = _codec!.encode(SpotifyApPacket(0xab, frames.encrypted.writeToBuffer()));
      await _write(plaintext);
      if (_state == SpotifyApSessionState.closed) return;
      await _write(login);
      if (_state == SpotifyApSessionState.closed) return;
      _loginWritten = true;
      _publishWelcome();
    } catch (error, stack) { await _terminate(error, stack); }
  }

  void _validateAuthentication(SpotifyApAuthenticationFrames frames, SpotifyApHandshakeResult result) {
    final plain = frames.plaintext, encrypted = frames.encrypted;
    if (!plain.isInitialized() || !encrypted.isInitialized() || !plain.loginCryptoResponse.hasDiffieHellman()) {
      throw const SpotifyApProtocolException('AP authentication messages are not initialized');
    }
    final actual = plain.loginCryptoResponse.diffieHellman.hmac, expected = result.keys.challenge;
    var mismatch = actual.length ^ expected.length;
    if (actual.length == expected.length) {
      for (var i = 0; i < expected.length; i++) { mismatch |= actual[i] ^ expected[i]; }
    }
    if (mismatch != 0) throw const SpotifyApProtocolException('AP DH HMAC does not match the verified transcript');
    if (!plain.cryptoResponse.hasShannon() || plain.cryptoResponse.hasRc4Sha1Hmac()) {
      throw const SpotifyApProtocolException('AP response must select Shannon');
    }
    final challenge = result.serverResponse.challenge;
    if (challenge.powChallenge.hasHashCash() &&
        (!plain.powResponse.hasHashCash() || plain.powResponse.hashCash.hashSuffix.isEmpty)) {
      throw const SpotifyApProtocolException('Active AP HashCash challenge has no response');
    }
    if (challenge.fingerprintChallenge.hasGrain() &&
        (!encrypted.fingerprintResponse.hasGrain() || encrypted.fingerprintResponse.grain.encryptedKey.isEmpty)) {
      throw const SpotifyApProtocolException('Active AP Grain challenge has no response');
    }
    if (challenge.fingerprintChallenge.hasHmacRipemd() &&
        (!encrypted.fingerprintResponse.hasHmacRipemd() || encrypted.fingerprintResponse.hmacRipemd.hmac.isEmpty)) {
      throw const SpotifyApProtocolException('Active AP HMAC-RIPEMD challenge has no response');
    }
  }

  void _decode(Uint8List bytes) {
    for (final packet in _codec!.add(bytes)) {
      if (_state == SpotifyApSessionState.closed) return;
      _packets.add(packet);
      if (packet.command == 0xad) {
        throw SpotifyApAuthenticationException(NativeApLoginFailure.decode(packet.payload));
      }
      if (packet.command == 0xac) {
        if (_candidate != null) throw const SpotifyApProtocolException('Duplicate AP Welcome');
        _candidate = NativeApWelcome.decode(packet.payload);
        _onWelcome?.call();
        if (_requestNativeInitialKey) {
          unawaited(requestInitialSessionKey().catchError((Object error, StackTrace stack) async {
            await _terminate(error, stack);
          }));
        }
        _publishWelcome();
      } else if (packet.command == 0x69) {
        if (packet.payload.isNotEmpty) throw const SpotifyApProtocolException('Nonempty AP login completion');
        _nativeComplete = true;
        _onLoginComplete?.call();
        _publishWelcome();
      } else if (_state != SpotifyApSessionState.ready) {
        if (!_admitAuthenticationPacket(packet)) {
          throw SpotifyApProtocolException('Unhandled AP authentication packet ${packet.command}');
        }
      } else {
        if (_admitReadyPacket?.call(packet) == false) {
          throw SpotifyApProtocolException('Unhandled AP packet ${packet.command}');
        }
        if (packet.command == 0x0d || packet.command == 0x0e) {
          try { _keys!.dispatch(packet); }
          on SpotifyAudioKeyException catch (error) {
            // A late response after cancellation/timeout is retained raw.
            if (error.failure != SpotifyAudioKeyFailure.unknownSequence) rethrow;
          }
        }
      }
      if (const {0x1b, 0x50, 0x76, 0xa4}.contains(packet.command)) {
        _attributes[packet.command] = packet.payload;
        if (packet.command == 0x50) _productState.applyPayload(packet.payload);
      }
      _publishWelcome();
    }
  }

  void _publishWelcome() {
    if (_state != SpotifyApSessionState.authenticating || !_loginWritten || !_nativeComplete || _candidate == null) return;
    if (_isAuthenticationReady?.call() == false) return;
    _welcome = _candidate;
    _state = SpotifyApSessionState.ready;
    _keys = SpotifyAudioKeyManager(sendPacket: sendPacket);
    if (_state == SpotifyApSessionState.ready && !_authenticated!.isCompleted) _authenticated!.complete(_welcome);
  }

  Future<void> _write(Uint8List bytes) {
    _token.throwIfCancelled();
    final owned = Uint8List.fromList(bytes).asUnmodifiableView();
    final result = _outgoing.then<void>((_) async {
      _token.throwIfCancelled();
      if (_state == SpotifyApSessionState.closed) throw StateError('AP session is closed');
      await _sendBytes(owned).asCancellable(_token);
    });
    _outgoing = result.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      unawaited(_terminate(error, stack));
    });
    return result;
  }

  void _eof() {
    if (_state == SpotifyApSessionState.closed) return;
    try {
      if (_handshake != null) { _handshake!.finishInput(); }
      else { _codec!.finishInput(); }
      throw const SpotifyApProtocolException('AP transport ended');
    } catch (error, stack) { unawaited(_terminate(error, stack)); }
  }

  Future<void> close([Object? cause]) => _terminate(cause);
  Future<void> _terminate([Object? error, StackTrace? stack]) => _closing ??= _shutdown(error, stack);
  Future<void> _shutdown(Object? error, StackTrace? stack) async {
    _parentCancellation?.dispose(); _parentCancellation = null;
    _token.cancel();
    _state = SpotifyApSessionState.closed;
    _failure = error;
    _keys?.close();
    _codec?.close();
    _handshake?.close();
    _handshake = null;
    _buildAuthentication = null;
    _candidate = null;
    final result = _authenticated;
    if (result != null && !result.isCompleted) result.completeError(error ?? StateError('AP session closed before authentication'), stack);
    Future<void>? cancelled;
    try {
      cancelled = _subscription?.cancel().catchError((Object cancelError) { _failure ??= cancelError; });
    }
    catch (cancelError) { _failure ??= cancelError; }
    try { await _closeTransport(); }
    catch (closeError) { _failure ??= closeError; }
    await cancelled;
    if (error != null) _packets.addError(error, stack);
    unawaited(_packets.close());
    _done.complete();
  }
  void _requireReady() {
    if (_state != SpotifyApSessionState.ready) throw StateError('AP session is not authenticated and complete');
  }
}
