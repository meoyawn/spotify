import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../../async/cancellation.dart';
import '../../protocol/request_builder.dart';
import '../nghttp3/bindings.dart' as ng;
import '../nghttp3/session.dart' as codec;
import 'bindings.dart' as native;

/// A connection-creation failure, distinct from an HTTP response or a request
/// cancellation. Selection policy consumes the typed cause, never its text.
enum Http3ConnectionFailure { timeout, nameNotResolved, nameResolutionFailed,
  disconnected, socket, transport, tls, cancelled }

final class Http3ConnectionException extends http.ClientException {
  Http3ConnectionException(this.failure, String message, {this.osErrorCode}) : super(message);
  final Http3ConnectionFailure failure;
  final int? osErrorCode;
}

/// Direct quiche C API integration. Remote DNS origins require explicit
/// admission. No redirects, retries, cookies,
/// user-agent, compression, or other application headers are added here.
class QuicheHttp3Client extends http.BaseClient {
  factory QuicheHttp3Client.bundled({required String trustedCertificatesPath,
      bool Function(Uri origin)? admitRemoteOrigin}) =>
    QuicheHttp3Client(
      libraryPath: '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libquiche.dylib',
      trustedCertificatesPath: trustedCertificatesPath, admitRemoteOrigin: admitRemoteOrigin);

  QuicheHttp3Client({required String libraryPath,
    required this.trustedCertificatesPath,
    this.admitRemoteOrigin,
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 30)})
    : _api = _load(libraryPath),
      _http3Api = ng.Nghttp3Bindings(DynamicLibrary.open('${File(libraryPath).parent.path}/libnghttp3.dylib'));

  final native.QuicheBindings _api;
  final ng.Nghttp3Bindings _http3Api;
  final String trustedCertificatesPath;
  final bool Function(Uri origin)? admitRemoteOrigin;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final _connections = <String, _Connection>{};
  final _roundTripTimes = <String, int>{};
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  bool _closed = false;

  String get version => _api.quiche_version().cast<Utf8>().toDartString();

  /// Establish only the transport. No HTTP headers or body are constructed.
  /// Connection selection can race this against TLS/H2 before dispatch.
  Future<void> prepareOrigin(Uri origin) async {
    final connection = _connectionFor(origin);
    await connection.ready.future;
    if (_closed) throw Http3ConnectionException(Http3ConnectionFailure.cancelled, 'HTTP/3 client closed');
    if (connection.disposed) throw Http3ConnectionException(Http3ConnectionFailure.transport,
      'HTTP/3 connection is closed');
  }

  bool isOriginReady(Uri origin) {
    final connection = _connections[_authority(origin)];
    return connection != null && !connection.disposed && connection.h3 != null;
  }

  int? smoothedRttMicroseconds(Uri origin) =>
    _connections[_authority(origin)]?.smoothedRttMicroseconds ?? _roundTripTimes[_authority(origin)];

  static String _authority(Uri uri) => '${uri.host}:${uri.port}';

  _Connection _connectionFor(Uri uri) {
    if (_closed) throw http.RequestAbortedException();
    final loopback = uri.host == 'localhost';
    final origin = Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasFragment ||
        uri.port < 1 || uri.port > 65535 ||
        (!loopback && (!_dnsName(uri.host) || !(admitRemoteOrigin?.call(origin) ?? false)))) {
      throw http.ClientException('Remote HTTP/3 transport is unverified. No request was sent.');
    }
    final authority = _authority(uri);
    final existing = _connections[authority];
    if (existing != null) return existing;
    late final _Connection opening;
    opening = _Connection(_api, _http3Api, uri.port, () {
      final rtt = opening.lastRttMicroseconds;
      if (rtt != null) _roundTripTimes[authority] = rtt;
      if (identical(_connections[authority], opening)) _connections.remove(authority);
    }, loopback: loopback);
    _connections[authority] = opening;
    unawaited(opening.open(uri.host, trustedCertificatesPath, connectTimeout));
    return opening;
  }

  /// Keeps the original encoded target across dart:core Uri normalization.
  Future<http.Response> sendEnvelope(RequestEnvelope envelope,
      {Future<void>? abortTrigger, CancellationToken? cancellationToken}) async =>
    http.Response.fromStream(await sendEnvelopeStream(envelope,
      abortTrigger: abortTrigger, cancellationToken: cancellationToken));

  /// Exact application fields with a streamed response and request-scoped
  /// abortion. Neither this API nor [send] adds application headers or replays.
  Future<http.StreamedResponse> sendEnvelopeStream(RequestEnvelope envelope,
      {Future<void>? abortTrigger, CancellationToken? cancellationToken}) {
    final request = _ExactRequest(envelope.method, envelope.url,
      abortTrigger: abortTrigger,
      cancellationToken: MergedCancellationToken([
        if (envelope.cancellationToken != null) envelope.cancellationToken!,
        if (cancellationToken != null) cancellationToken]),
      timeout: envelope.nativeTimeoutMilliseconds == null ? null :
        Duration(milliseconds: envelope.nativeTimeoutMilliseconds!))
      ..followRedirects = false
      ..headers.addAll(envelope.headers)
      ..bodyBytes = envelope.body;
    return send(request);
  }

  static native.QuicheBindings _load(String path) {
    if (Abi.current() != Abi.macosArm64) {
      throw UnsupportedError('The pinned quiche ABI currently targets macOS arm64');
    }
    return native.QuicheBindings(DynamicLibrary.open(path));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.RequestAbortedException();
    final uri = request.url;
    // The current quiche verifier accepts DNS names; IP SAN support is unverified.
    final loopback = uri.host == 'localhost';
    final origin = Uri(scheme: uri.scheme, host: uri.host, port: uri.port);
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasFragment ||
        uri.port < 1 || uri.port > 65535 ||
        (!loopback && (!_dnsName(uri.host) || !(admitRemoteOrigin?.call(origin) ?? false)))) {
      throw http.ClientException('Remote HTTP/3 transport is unverified. No request was sent.');
    }
    final headers = <(String, String)>[
      (':method', request.method),
      (':authority', request is _ExactRequest ? request.authority : uri.authority),
      (':scheme', 'https'),
      (':path', request is _ExactRequest ? request.target :
        '${uri.path.isEmpty ? '/' : uri.path}${uri.hasQuery ? '?${uri.query}' : ''}'),
    ];
    for (final entry in request.headers.entries) {
      final name = entry.key.toLowerCase();
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$").hasMatch(name) ||
          {'connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'host'}.contains(name) ||
          (name == 'te' && entry.value != 'trailers') ||
          entry.value.contains(RegExp(r'[\x00\r\n]'))) {
        throw http.ClientException('Header cannot be represented in HTTP/3: $name');
      }
      headers.add((name, entry.value));
    }
    final cancellation = _RequestCancellation(request, _token);
    await cancellation.check();
    final body = await cancellation.readBody();
    cancellation.throwIfAborted();
    if (_closed) throw http.RequestAbortedException();
    final connection = _connectionFor(uri);
    await cancellation.waitFor(connection.ready.future);
    cancellation.throwIfAborted();
    if (_closed) throw http.RequestAbortedException();
    return await connection.send(request, headers, body,
      request is _ExactRequest ? request.timeout ?? requestTimeout : requestTimeout, cancellation);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _token.cancel(http.RequestAbortedException());
    for (final connection in _connections.values.toList()) {
      connection.close();
    }
    _connections.clear();
    _roundTripTimes.clear();
    super.close();
  }
}

bool _dnsName(String value) => value.isNotEmpty && value.length <= 253 &&
  InternetAddress.tryParse(value) == null &&
  RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$')
    .hasMatch(value);

class _RequestCancellation {
  _RequestCancellation(this.request, CancellationToken owner) {
    final supplied = request is _ExactRequest ? (request as _ExactRequest).cancellationToken : null;
    token = MergedCancellationToken([owner, _local, ?supplied]);
    final trigger = request is http.Abortable ? (request as http.Abortable).abortTrigger : null;
    unawaited(trigger?.then((_) => cancel(http.RequestAbortedException(request.url))));
  }
  final http.BaseRequest request;
  final _local = CancellationToken();
  late final CancellationToken token;

  void cancel(http.ClientException reason) {
    _local.cancel(reason);
  }

  void throwIfAborted() {
    token.throwIfCancelled();
  }

  Future<void> check() async {
    // Give an already completed abort trigger precedence over finalization.
    await Future<void>.value().asCancellable(token);
    throwIfAborted();
  }

  Future<T> waitFor<T>(Future<T> future) {
    return future.asCancellable(token);
  }

  Future<Uint8List> readBody() {
    throwIfAborted();
    StreamSubscription<List<int>>? subscription;
    final result = CancellableCompleter<Uint8List>(token,
      onCancel: () { unawaited(subscription?.cancel()); });
    final bytes = BytesBuilder(copy: false);
    final input = request.finalize();
    if (token.isCancelled) return result.future;
    subscription = input.listen(bytes.add,
      onError: (Object error, StackTrace trace) => result.completeError(error, trace),
      onDone: () => result.complete(bytes.takeBytes()), cancelOnError: true);
    if (token.isCancelled) unawaited(subscription.cancel());
    return result.future;
  }
}

class _ExactRequest extends http.Request with http.Abortable {
  _ExactRequest(String method, String rawUrl, {this.abortTrigger, this.timeout, this.cancellationToken})
      : super(method, Uri.parse(rawUrl)) {
    final match = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]+)([^#]*)(?:#.*)?$')
      .firstMatch(rawUrl);
    if (match == null) throw http.ClientException('Invalid absolute request URL');
    authority = match.group(1)!;
    final suffix = match.group(2)!;
    target = suffix.startsWith('/') ? suffix : '/$suffix';
    if (target.contains(RegExp(r'[^\x21-\x7e]')) ||
        target.contains(RegExp(r'%(?![A-Fa-f0-9]{2})'))) {
      throw http.ClientException('Request target requires verified URL escaping');
    }
  }
  late final String authority;
  late final String target;
  @override
  final Future<void>? abortTrigger;
  final CancellationToken? cancellationToken;
  final Duration? timeout;
}

class _Connection {
  _Connection(this.api, this.http3Api, this.port, this.onDispose, {required this.loopback});
  final native.QuicheBindings api;
  final ng.Nghttp3Bindings http3Api;
  late final RawDatagramSocket socket;
  late final InternetAddress peer;
  final bool loopback;
  final int port;
  final void Function() onDispose;
  final arena = Arena();
  final ready = Completer<void>();
  final pending = <_Exchange>[];
  final exchanges = <int, _Exchange>{};
  final egress = Queue<Uint8List>();
  Pointer<native.quiche_conn> quic = nullptr;
  codec.Nghttp3Session? h3;
  int _nextStreamId = 0;
  late final Pointer<Uint8> buffer = arena<Uint8>(65535);
  late final Pointer<native.quiche_recv_info> recvInfo = arena<native.quiche_recv_info>();
  late final Pointer<native.quiche_send_info> sendInfo = arena<native.quiche_send_info>();
  StreamSubscription<RawSocketEvent>? subscription;
  Timer? timer;
  Timer? handshakeTimer;
  bool socketBound = false;
  bool disposed = false;
  int? lastRttMicroseconds;

  int? get smoothedRttMicroseconds {
    if (disposed || quic == nullptr || h3 == null) return lastRttMicroseconds;
    return using((temporary) {
      final stats = temporary<native.quiche_path_stats>();
      if (api.quiche_conn_path_stats(quic, 0, stats) != 0 || !stats.ref.active) return lastRttMicroseconds;
      final micros = stats.ref.rtt ~/ 1000;
      if (micros > 0) lastRttMicroseconds = micros;
      return lastRttMicroseconds;
    });
  }

  Future<void> open(String host, String certificates, Duration timeout) async {
    try {
      handshakeTimer = Timer(timeout,
        () => fail(Http3ConnectionException(Http3ConnectionFailure.timeout, 'HTTP/3 handshake timed out')));
      List<InternetAddress> addresses;
      try {
        addresses = loopback ? [InternetAddress.loopbackIPv4] :
          await InternetAddress.lookup(host, type: InternetAddressType.IPv4);
      } on SocketException catch (error) {
        // This primitive is macOS arm64 only. Darwin getaddrinfo EAI_NODATA=7
        // and EAI_NONAME=8 map to NAME_NOT_RESOLVED in pinned Chromium source;
        // its other getaddrinfo failures map to NAME_RESOLUTION_FAILED.
        throw Http3ConnectionException(const {7, 8}.contains(error.osError?.errorCode)
          ? Http3ConnectionFailure.nameNotResolved : Http3ConnectionFailure.nameResolutionFailed,
          'HTTP/3 name resolution failed', osErrorCode: error.osError?.errorCode);
      }
      if (disposed) return;
      if (addresses.isEmpty) throw Http3ConnectionException(Http3ConnectionFailure.nameNotResolved,
        'HTTP/3 DNS host has no IPv4 address');
      peer = addresses.first;
      final bound = await RawDatagramSocket.bind(
        loopback ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4, 0);
      if (disposed) {
        bound.close();
        return;
      }
      socket = bound;
      socketBound = true;
      _initialize(host, certificates);
      subscription = socket.listen(_onEvent,
        onError: fail,
        onDone: () => fail(http.ClientException('UDP socket closed')));
      _drive();
    } catch (error) {
      fail(error);
    }
  }

  void _initialize(String host, String certificates) {
    final config = api.quiche_config_new(native.QUICHE_PROTOCOL_VERSION);
    if (config == nullptr) throw http.ClientException('Cannot allocate quiche configuration');
    try {
      using((temporary) {
        api.quiche_config_verify_peer(config, true);
        final ca = certificates.toNativeUtf8(allocator: temporary).cast<Char>();
        if (api.quiche_config_load_verify_locations_from_file(config, ca) < 0) {
          throw http.ClientException('Cannot load trusted certificates');
        }
        final alpn = temporary<Uint8>(3)..asTypedList(3).setAll(0, [2, 104, 51]);
        if (api.quiche_config_set_application_protos(config, alpn, 3) < 0) {
          throw http.ClientException('Cannot configure HTTP/3 ALPN');
        }
        // Numeric receive limits agree in all101 original client TP events.
        // This does not establish the remaining TLS/QUIC wire fingerprint.
        api.quiche_config_set_max_idle_timeout(config, 30000);
        api.quiche_config_set_max_recv_udp_payload_size(config, 1472);
        api.quiche_config_set_max_send_udp_payload_size(config, 1350);
        api.quiche_config_set_initial_max_data(config, 15728640);
        api.quiche_config_set_initial_max_stream_data_bidi_local(config, 6291456);
        api.quiche_config_set_initial_max_stream_data_bidi_remote(config, 6291456);
        api.quiche_config_set_initial_max_stream_data_uni(config, 6291456);
        api.quiche_config_set_initial_max_streams_bidi(config, 100);
        api.quiche_config_set_initial_max_streams_uni(config, 103);
        // Standard RFC9297 support. Queues are local bounded storage; their
        // lengths are not advertised or inferred from original NetLogs.
        api.quiche_config_enable_dgram(config, true, 16, 16);
        api.quiche_config_enable_pacing(config, false);
        final local = _address(socket.address, socket.port);
        final remote = _address(peer, port);
        recvInfo.ref..from = remote..from_len = 16..to = local..to_len = 16;
        final random = Random.secure();
        final id = temporary<Uint8>(16)
          ..asTypedList(16).setAll(0, List.generate(16, (_) => random.nextInt(256)));
        quic = api.quiche_connect(host.toNativeUtf8(allocator: temporary).cast<Char>(),
          id, 16, local, 16, remote, 16, config);
        if (quic == nullptr) throw http.ClientException('Cannot create QUIC connection');
      });
    } finally {
      api.quiche_config_free(config);
    }
  }

  Pointer<native.sockaddr> _address(InternetAddress address, int port) {
    final bytes = arena<Uint8>(16);
    final view = bytes.asTypedList(16);
    view[0] = 16; // Darwin sockaddr_in.sin_len
    view[1] = 2; // AF_INET
    ByteData.sublistView(view).setUint16(2, port, Endian.big);
    view.setAll(4, address.rawAddress);
    return bytes.cast<native.sockaddr>();
  }

  Future<http.StreamedResponse> send(http.BaseRequest request,
      List<(String, String)> headers, Uint8List body, Duration timeout,
      _RequestCancellation cancellation) {
    cancellation.throwIfAborted();
    if (disposed) return Future.error(http.ClientException('HTTP/3 connection is closed'));
    final exchange = _Exchange(request, headers, body);
    pending.add(exchange);
    exchange.timer = Timer(timeout, () => _cancel(exchange,
      http.ClientException('HTTP/3 request timed out')));
    exchange.body.onCancel = () => _cancel(exchange,
      http.RequestAbortedException(request.url));
    exchange.body.onListen = _drive;
    exchange.body.onResume = _drive;
    exchange.cancellation = CancellationRegistration(cancellation.token,
      onCancel: (error) => _cancel(exchange, error));
    _drive();
    return exchange.response.future;
  }

  void _cancel(_Exchange exchange, Object reason) {
    if (exchange.done) return;
    _terminate(exchange, reason);
    if (!disposed) _drive();
  }

  void _terminate(_Exchange exchange, Object reason, {int errorCode = 0x10c}) {
    if (exchange.done) return;
    if (!disposed && exchange.id != null) {
      api.quiche_conn_stream_shutdown(quic, exchange.id!,
        native.quiche_shutdown.QUICHE_SHUTDOWN_READ, errorCode);
      api.quiche_conn_stream_shutdown(quic, exchange.id!,
        native.quiche_shutdown.QUICHE_SHUTDOWN_WRITE, errorCode);
      h3?.closeStream(exchange.id!, error: errorCode);
    }
    pending.remove(exchange);
    exchanges.remove(exchange.id);
    exchange.fail(reason);
  }

  void _onEvent(RawSocketEvent event) {
    if (disposed) return;
    try {
      if (event == RawSocketEvent.read) {
        Datagram? packet;
        while ((packet = socket.receive()) != null) {
          if (packet!.address != peer || packet.port != port) continue;
          buffer.asTypedList(packet.data.length).setAll(0, packet.data);
          final result = api.quiche_conn_recv(quic, buffer, packet.data.length, recvInfo);
          if (result < -1) throw Http3ConnectionException(result == -10
            ? Http3ConnectionFailure.tls : Http3ConnectionFailure.transport, 'QUIC receive failed ($result)');
        }
      } else if (event == RawSocketEvent.closed) {
        fail(Http3ConnectionException(Http3ConnectionFailure.transport, 'UDP socket closed'));
        return;
      }
      _drive();
    } catch (error) {
      fail(error);
    }
  }

  void _drive() {
    if (disposed) return;
    try {
      if (api.quiche_conn_is_closed(quic)) {
        throw Http3ConnectionException(Http3ConnectionFailure.transport, 'QUIC connection closed');
      }
      if (h3 == null && api.quiche_conn_is_established(quic)) {
        h3 = codec.Nghttp3Session(http3Api);
        handshakeTimer?.cancel();
        ready.complete();
      }
      if (h3 != null) {
        _sendRequests();
        _poll();
        _writeStreams();
        _acknowledgeStreams();
      }
      _flush();
      timer?.cancel();
      final milliseconds = api.quiche_conn_timeout_as_millis(quic);
      if (milliseconds >= 0) {
        timer = Timer(Duration(milliseconds: milliseconds), () {
          if (disposed) return;
          api.quiche_conn_on_timeout(quic);
          _drive();
        });
      }
    } catch (error) {
      fail(error);
    }
  }

  void _sendRequests() {
    using((temporary) {
      final error = temporary<Uint64>();
      for (final exchange in pending.toList()) {
        // Opening an empty QUIC stream checks the actual peer stream limit.
        // No HTTP fields/body are emitted until the standard codec writes.
        final id = _nextStreamId;
        final opened = api.quiche_conn_stream_send(quic, id, nullptr, 0, false, error);
        if (opened == -1 || opened == -13) break;
        if (opened < 0) throw http.ClientException('QUIC request stream open failed ($opened)');
        h3!.submit(id, exchange.headers,
          exchange.payload.isEmpty ? nullptr : exchange.nativeBody, exchange.payload.length);
        _nextStreamId += 4;
        exchange.id = id;
        exchanges[id] = exchange;
        pending.remove(exchange);
      }
    });
  }

  void _stopUpload(_Exchange exchange) {
    if (exchange.uploadStopped || exchange.payload.isEmpty || h3!.isWriteFlushed(exchange.id!)) return;
    api.quiche_conn_stream_shutdown(quic, exchange.id!,
      native.quiche_shutdown.QUICHE_SHUTDOWN_WRITE, 0x100);
    h3!.stopUpload(exchange.id!);
    exchange.uploadStopped = true;
    exchange.releasePayload();
  }

  void _writeStreams() {
    final session = h3!;
    for (final id in session.blockedStreams.toList()) {
      final capacity = api.quiche_conn_stream_capacity(quic, id);
      if (capacity > 0) {
        session.unblock(id);
      } else if (capacity == -15) {
        final exchange = exchanges[id];
        if (exchange != null) _stopUpload(exchange);
        session.blockedStreams.remove(id);
      }
    }
    using((temporary) {
      final error = temporary<Uint64>();
      session.write((id, bytes, length, fin) {
        final result = api.quiche_conn_stream_send(quic, id, bytes, length, fin, error);
        if (result == -15) {
          final exchange = exchanges[id];
          if (exchange == null) throw http.ClientException('HTTP/3 critical stream was stopped');
          _stopUpload(exchange);
        }
        return result;
      });
    });
  }

  void _acknowledgeStreams() {
    using((temporary) {
      final offset = temporary<Uint64>();
      for (final id in h3!.writtenStreams.toList()) {
        if (api.quiche_conn_stream_acked_offset(quic, id, offset)) {
          h3!.acknowledge(id, offset.value);
        }
      }
    });
  }

  void _poll() {
    final iterator = api.quiche_conn_readable(quic);
    if (iterator == nullptr) return;
    try {
      using((temporary) {
        final id = temporary<Uint64>(), fin = temporary<Bool>(), error = temporary<Uint64>();
        final streams = <int>[];
        while (api.quiche_stream_iter_next(iterator, id)) { streams.add(id.value); }
        // QPACK/control streams stay readable even when a response consumer is
        // paused. nghttp3 owns blocked-field-section synchronization.
        for (final streamId in streams) {
          for (var turn = 0; turn < 1024; turn++) {
            final exchange = exchanges[streamId];
            if (exchange != null && exchange.response.isCompleted &&
                (!exchange.body.hasListener || exchange.body.isPaused)) break;
            final count = api.quiche_conn_stream_recv(quic, streamId, buffer, 65535, fin, error);
            if (count == -1) break;
            if (count == -16) {
              if (exchange == null) throw http.ClientException('HTTP/3 critical stream reset');
              h3!.closeStream(streamId, error: error.value);
              exchanges.remove(streamId);
              exchange.fail(http.ClientException('HTTP/3 stream reset'));
              break;
            }
            if (count < 0) throw http.ClientException('QUIC stream read failed ($count)');
            h3!.receive(streamId, buffer, count, fin.value);
            _deliverEvents();
            if (fin.value || streamId % 4 == 0 && !exchanges.containsKey(streamId)) break;
          }
        }
      });
    } finally { api.quiche_stream_iter_free(iterator); }
    _deliverEvents();
  }

  void _deliverEvents() {
    while (h3!.events.isNotEmpty) {
      final events = h3!.events.toList();
      h3!.events.clear();
      for (final event in events) {
        final exchange = exchanges[event.streamId];
        switch (event) {
          case codec.Http3Headers():
            if (exchange != null) _headers(exchange, event.headers);
          case codec.Http3Data():
            if (exchange == null) continue;
            exchange.received += event.bytes.length;
            if (exchange.expectedResponseLength != null &&
                exchange.received > exchange.expectedResponseLength!) {
              _terminate(exchange, exchange.bodyLengthError, errorCode: 0x10e);
            } else { exchange.body.add(event.bytes); }
          case codec.Http3Finished():
            if (exchange == null) continue;
            if (exchange.expectedResponseLength != null &&
                exchange.received != exchange.expectedResponseLength) {
              _terminate(exchange, exchange.bodyLengthError, errorCode: 0x10e);
            } else {
              _stopUpload(exchange);
              h3!.closeStream(event.streamId);
              exchanges.remove(event.streamId);
              exchange.finish();
            }
          case codec.Http3Stop():
            api.quiche_conn_stream_shutdown(quic, event.streamId,
              event.read ? native.quiche_shutdown.QUICHE_SHUTDOWN_READ :
                native.quiche_shutdown.QUICHE_SHUTDOWN_WRITE, event.error);
            if (!event.read && exchange != null) _stopUpload(exchange);
          case codec.Http3Shutdown():
            throw http.ClientException('HTTP/3 peer sent GOAWAY');
        }
      }
    }
  }

  void _headers(_Exchange exchange, List<(String, String)> headers) {
    if (exchange.response.isCompleted) return; // Trailers have no BaseClient field.
    final statuses = headers.where((header) => header.$1 == ':status').toList();
    final status = statuses.length == 1 ? int.tryParse(statuses.single.$2) : null;
    if (status == null || status < 100 || status > 599) {
      throw http.ClientException('Invalid HTTP/3 response status');
    }
    if (status < 200) return;
    int? declaredLength;
    for (final (_, value) in headers.where((header) => header.$1 == 'content-length')) {
      for (final part in value.split(',')) {
        final normalized = part.replaceAll(RegExp(r'^[ \t]+|[ \t]+$'), '');
        final length = RegExp(r'^[0-9]+$').hasMatch(normalized) ? int.tryParse(normalized) : null;
        if (length == null || (declaredLength != null && declaredLength != length)) {
          _terminate(exchange, http.ClientException('Invalid HTTP/3 content-length'), errorCode: 0x10e);
          return;
        }
        declaredLength = length;
      }
    }
    exchange.responseBodyForbidden = exchange.request.method == 'HEAD' ||
      status == 204 || status == 205 || status == 304;
    exchange.expectedResponseLength = exchange.responseBodyForbidden ? 0 : declaredLength;
    final combined = <String, String>{};
    for (final (name, value) in headers) {
      if (name.startsWith(':')) continue;
      combined.update(name, (previous) => '$previous,$value', ifAbsent: () => value);
    }
    exchange.response.complete(http.StreamedResponse(exchange.body.stream,
      status, headers: combined, request: exchange.request,
      contentLength: declaredLength,
      isRedirect: status >= 300 && status < 400 && combined.containsKey('location')));
  }

  void _flush() {
    while (true) {
      if (egress.isNotEmpty) {
        final packet = egress.first;
        final sent = socket.send(packet, peer, port);
        if (sent == 0) {
          socket.writeEventsEnabled = true;
          return;
        }
        if (sent != packet.length) throw http.ClientException('Partial UDP send');
        egress.removeFirst();
      }
      final count = api.quiche_conn_send_on_path(quic, buffer, 1350,
        recvInfo.ref.to, recvInfo.ref.to_len,
        recvInfo.ref.from, recvInfo.ref.from_len, sendInfo);
      if (count == -1) break;
      if (count < 0) throw Http3ConnectionException(Http3ConnectionFailure.transport, 'QUIC send failed ($count)');
      // send_on_path selects this connection's bound local and resolved peer tuple.
      egress.add(Uint8List.fromList(buffer.asTypedList(count)));
    }
    socket.writeEventsEnabled = false;
  }

  void fail(Object error) {
    if (disposed) return;
    if (!ready.isCompleted) {
      // Darwin ENETDOWN=50 is Chromium's INTERNET_DISCONNECTED. Other socket
      // errors (including unreachable/refused/reset) are distinct failures.
      final cause = error is SocketException ? Http3ConnectionException(
        error.osError?.errorCode == 50 ? Http3ConnectionFailure.disconnected : Http3ConnectionFailure.socket,
        'HTTP/3 socket connection failed', osErrorCode: error.osError?.errorCode) : error;
      ready.completeError(cause);
    }
    for (final exchange in [...pending, ...exchanges.values]) {
      exchange.fail(error);
    }
    _dispose();
  }

  void close() => fail(Http3ConnectionException(Http3ConnectionFailure.cancelled, 'HTTP/3 client closed'));

  void _dispose() {
    if (disposed) return;
    lastRttMicroseconds = smoothedRttMicroseconds;
    disposed = true;
    timer?.cancel();
    handshakeTimer?.cancel();
    unawaited(subscription?.cancel());
    if (socketBound) socket.close();
    h3?.close(); h3 = null;
    if (quic != nullptr) api.quiche_conn_free(quic);
    arena.releaseAll();
    pending.clear();
    exchanges.clear();
    egress.clear();
    onDispose();
  }
}

class _Exchange {
  _Exchange(this.request, this.headers, this.payload);
  final http.BaseRequest request;
  final List<(String, String)> headers;
  final Uint8List payload;
  final response = Completer<http.StreamedResponse>();
  final body = StreamController<List<int>>();
  Pointer<Uint8> _nativeBody = nullptr;
  Pointer<Uint8> get nativeBody {
    if (_nativeBody == nullptr) {
      _nativeBody = calloc<Uint8>(payload.length)
        ..asTypedList(payload.length).setAll(0, payload);
    }
    return _nativeBody;
  }
  int? id;
  bool uploadStopped = false;
  int received = 0;
  int? expectedResponseLength;
  bool responseBodyForbidden = false;
  bool done = false;
  Timer? timer;
  CancellationRegistration? cancellation;

  http.ClientException get bodyLengthError => http.ClientException(responseBodyForbidden
    ? 'HTTP/3 response contains forbidden content'
    : 'HTTP/3 response body does not match content-length');

  void releasePayload() {
    if (_nativeBody == nullptr) return;
    calloc.free(_nativeBody);
    _nativeBody = nullptr;
  }

  void finish() {
    if (done) return;
    if (!response.isCompleted) {
      fail(http.ClientException('HTTP/3 response ended without headers'));
      return;
    }
    done = true;
    cancellation?.dispose();
    cancellation = null;
    timer?.cancel();
    releasePayload();
    unawaited(body.close());
  }

  void fail(Object error) {
    if (done) return;
    done = true;
    cancellation?.dispose();
    cancellation = null;
    timer?.cancel();
    releasePayload();
    if (response.isCompleted) {
      body.addError(error);
    } else {
      response.completeError(error);
    }
    unawaited(body.close());
  }
}
