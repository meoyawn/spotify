import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cancellation_token/cancellation_token.dart';
import 'package:http/http.dart' as http;

import 'client_token.dart';
import 'native_client_data.dart';

typedef NativeClientTokenCancel = void Function();
typedef NativeClientTokenExecutor = void Function(void Function() callback);
typedef NativeClientTokenSendOwner = NativeClientTokenOwnedSend Function(Uint8List body);
typedef NativeClientTokenEncoder = String Function(NativeClientToken token);

class NativeClientToken {
  NativeClientToken({required this.token, required this.expiresAtMicroseconds,
    required this.refreshAtMicroseconds, required this.clientDataHash, required List<String> domains})
    : domains = List.unmodifiable(domains);
  final String token, clientDataHash;
  final int expiresAtMicroseconds, refreshAtMicroseconds;
  final List<String> domains;
}

sealed class NativeClientTokenResult {
  const NativeClientTokenResult();
}

class NativeClientTokenSuccess extends NativeClientTokenResult {
  const NativeClientTokenSuccess(this.token);
  final NativeClientToken token;
}

class NativeClientTokenFailure extends NativeClientTokenResult implements Exception {
  const NativeClientTokenFailure(this.code, {this.detail = '', this.transportError});
  final int code;
  final String detail;
  final NativeClientTokenTransportError? transportError;
  String get message {
    final base = switch (code.toSigned(32)) {
      1 => 'client_token_aborted', 2 => 'client_token_invalid_arguments',
      3 => 'client_token_disabled', 101 => 'client_token_unknown_backend_error',
      102 => 'client_token_invalid_token_backend_error',
      103 => 'client_token_missing_client_backend_error',
      104 => 'client_token_invalid_client_backend_error',
      final other => 'invalid_client_token_error_$other',
    };
    return detail.isEmpty ? base : '$base [$detail]';
  }
}

/// A failure delivered through the original HTTP error-code callback, rather
/// than an arbitrary Dart exception. 0x1017c57b4 wraps it in client-token 101
/// and retains the nested category/value tuple.
class NativeClientTokenTransportError implements Exception {
  const NativeClientTokenTransportError({required this.category, required this.code, required this.message});
  final String category, message;
  final int code;
}

/// The body-only send boundary inherited from ClientTokenService. Its owner
/// supplies the separately established endpoint, HTTP template and real abort.
class NativeClientTokenOwnedSend {
  NativeClientTokenOwnedSend({required this.response, required void Function() abort})
    : _abortOwnedWork = abort;
  final Future<http.Response> response;
  final void Function() _abortOwnedWork;
  CancellationToken? _cancellation;
  void abort() {
    final token = _cancellation ??= CancellationToken();
    if (token.isCancelled) return;
    token.cancel(const NativeClientTokenFailure(1));
    _abortOwnedWork();
  }
}

/// Native owner 0x1017c8d0c: disabled initially, acquisition on demand, one
/// shared acquisition, native refresh-time/hash admission and sticky error 104.
/// No credential store, HTTP transport, background schedule or codec is guessed.
class NativeClientTokenProvider {
  NativeClientTokenProvider({required this.clientData, required this.sendOwned,
    required this.nowMicroseconds, required this.encodeToken, required this.onError,
    NativeClientToken? initialToken, NativeClientTokenExecutor? execute})
    : _cached = initialToken, _execute = execute ?? scheduleMicrotask,
      clientDataHash = nativeClientDataHash(clientData);
  final NativeClientDataFactory clientData;
  final NativeClientTokenSendOwner sendOwned;
  final int Function() nowMicroseconds;
  /// The established storage codec must be supplied. It must be synchronous
  /// and must not throw; this owner neither substitutes a plaintext token nor
  /// delegates encoding to the original application.
  final NativeClientTokenEncoder encodeToken;
  /// Unclassified acquisition exceptions are not assigned invented native
  /// codes. A production supervisor must close/recover this owner on this path.
  final void Function(Object error, StackTrace stackTrace) onError;
  final NativeClientTokenExecutor _execute;
  /// Native SHA-1 hex string includes its copied trailing NUL (41 bytes).
  final String clientDataHash;
  NativeClientToken? _cached;
  NativeClientTokenFailure? _failure;
  bool _enabled = false;
  bool _closed = false;
  _Acquisition? _active;
  final _waiting = <_Waiter>[];
  final _tokenObservers = <_Observer<NativeClientToken?>>[];
  final _encryptedObservers = <_Observer<String>>[];

  bool get isEnabled => _enabled;
  NativeClientTokenFailure? get failure => _failure;
  void enable() { _enabled = true; }
  void disable() { _enabled = false; }
  void setFailure(NativeClientTokenFailure value) { _failure = value; }

  NativeClientToken? peek() => _closed || !_enabled || _needsRefresh() ? null : _cached;

  NativeClientTokenCancel acquire(void Function(NativeClientTokenResult result) callback) {
    if (_closed) return () {};
    final waiter = _Waiter(callback);
    if (!_enabled) {
      _defer(waiter, const NativeClientTokenFailure(3));
    } else if (_failure case final failure?) {
      _defer(waiter, failure);
    } else if (!_needsRefresh()) {
      _defer(waiter, NativeClientTokenSuccess(_cached!));
    } else {
      _waiting.add(waiter);
      if (_active == null) {
        final acquisition = _Acquisition(sendOwned);
        _active = acquisition;
        final service = ClientTokenService(acquisition.send,
          now: () => DateTime.fromMicrosecondsSinceEpoch(nowMicroseconds(), isUtc: true));
        acquisition.wait(service.acquire(clientData.create(currentToken: _cached?.token)))
          .then<void>((lease) {
            if (_closed || !identical(_active, acquisition)) return;
            _complete(NativeClientTokenSuccess(NativeClientToken(token: lease.token,
              expiresAtMicroseconds: lease.expiresAt.microsecondsSinceEpoch,
              refreshAtMicroseconds: lease.refreshAt.microsecondsSinceEpoch,
              clientDataHash: clientDataHash, domains: lease.domains)));
          }, onError: (Object error, StackTrace stack) {
            if (_closed || !identical(_active, acquisition)) return;
            if (error is ClientTokenFailure) {
              _complete(NativeClientTokenFailure(error.code));
            } else if (error is NativeClientTokenTransportError) {
              _complete(NativeClientTokenFailure(101, transportError: error));
            } else {
              onError(error, stack);
            }
          });
      }
    }
    return waiter.cancel;
  }

  bool _needsRefresh() {
    final token = _cached;
    return token == null || token.clientDataHash != clientDataHash ||
      nowMicroseconds() > token.refreshAtMicroseconds;
  }

  /// Invalidating publishes removal but does not initiate an acquisition or
  /// clear a sticky failure. Enabling/disabling also leaves cached state alone.
  void invalidate() {
    _cached = null;
    _publish();
  }

  NativeClientTokenCancel observeTokens(void Function(NativeClientToken?) observer) {
    final entry = _Observer(observer);
    _tokenObservers.add(entry);
    return () { entry.callback = null; _tokenObservers.remove(entry); };
  }

  /// Native subscriptions append to a callback list, without initial replay.
  NativeClientTokenCancel observeEncryptedTokens(void Function(String) observer) {
    final entry = _Observer(observer);
    _encryptedObservers.add(entry);
    return () { entry.callback = null; _encryptedObservers.remove(entry); };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final acquisition = _active;
    _active = null;
    acquisition?.abort();
    _complete(const NativeClientTokenFailure(1));
  }

  void _complete(NativeClientTokenResult result) {
    if (result is NativeClientTokenSuccess) {
      _cached = result.token;
      _publish();
    } else if (result is NativeClientTokenFailure && result.code == 104) {
      _failure = result;
      invalidate();
    }
    _active = null;
    final pending = List<_Waiter>.of(_waiting);
    _waiting.clear();
    // Native completion drains its weak subscriber list after releasing the
    // owner mutex. Close also takes this path; it does not schedule a timer.
    for (final waiter in pending) {
      waiter.deliver(result);
    }
  }

  void _defer(_Waiter waiter, NativeClientTokenResult result) {
    _execute(() {
      waiter.deliver(result);
    });
  }

  void _publish() {
    final cached = _cached;
    for (final observer in List.of(_tokenObservers)) {
      observer.callback?.call(cached);
    }
    final encoded = cached == null ? '' : encodeToken(cached);
    for (final observer in List.of(_encryptedObservers)) {
      observer.callback?.call(encoded);
    }
  }
}

class _Waiter {
  _Waiter(this.callback);
  void Function(NativeClientTokenResult)? callback;
  final cancellationToken = CancellationToken();
  void cancel() { cancellationToken.cancel(); callback = null; }
  void deliver(NativeClientTokenResult result) {
    final retained = callback;
    callback = null;
    retained?.call(result);
  }
}

class _Observer<T> {
  _Observer(this.callback);
  void Function(T)? callback;
}

class _Acquisition {
  _Acquisition(this.sendOwned);
  final NativeClientTokenSendOwner sendOwned;
  final cancellationToken = CancellationToken();
  NativeClientTokenOwnedSend? _send;
  bool get aborted => cancellationToken.isCancelled;
  void abort() {
    if (aborted) return;
    cancellationToken.cancel(const _Aborted());
    _send?.abort();
  }

  Future<T> wait<T>(Future<T> pending) async {
    final value = await pending.asCancellable(cancellationToken);
    if (aborted) throw const _Aborted();
    return value;
  }

  Future<http.Response> send(Uint8List bytes) async {
    if (aborted) throw const _Aborted();
    final owner = sendOwned(bytes);
    _send = owner;
    final pending = wait(owner.response);
    try {
      if (aborted) owner.abort();
      return await pending;
    } finally {
      if (identical(_send, owner)) _send = null;
    }
  }
}

class _Aborted implements Exception {
  const _Aborted();
}

/// Native cache/storage key, available before constructing the token owner so
/// an explicitly supplied stored token can be decoded with the same key.
String nativeClientDataHash(NativeClientDataFactory factory) {
  final bytes = BytesBuilder(copy: false);
  void text(String value) => bytes.add(utf8.encode(value));
  void integer(int value, int size) {
    final buffer = ByteData(size);
    if (size == 8) { buffer.setInt64(0, value.toSigned(64), Endian.little); }
    else { buffer.setInt32(0, value.toSigned(32), Endian.little); }
    bytes.add(buffer.buffer.asUint8List());
  }
  text(factory.clientId);
  text(factory.clientVersion);
  text(factory.deviceId);
  final facts = factory.facts;
  text(facts.systemVersionString);
  integer(facts.majorVersion, 8);
  integer(facts.minorVersion, 8);
  integer(facts.patchVersion, 8);
  text(facts.hardwareModel);
  integer(facts.cpuType, 4);
  integer(facts.cpuSubtype, 4);
  text('arm64');
  if (factory.developerApiKey case final key?) text(key);
  return '${sha1.convert(bytes.takeBytes())}\u0000';
}
