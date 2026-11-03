import 'dart:async';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';

import '../async/cancellation.dart';

// Pinned http2 3.1.0 owns pooling, peer stream limits, HPACK and HTTP/2.
// Its public Http2Client builds a different pseudoheader order, so retain our
// verified field writer and borrow the standard pool beneath that writer.
import 'package:http2/src/client_pool.dart' as standard;
import 'package:http2/src/connection.dart' as implementation;
import 'package:http2/transport.dart' as h2;

import 'native_http2_priority.dart';

/// A session-owned connection pool. Adapters retain their own request guards
/// and cancellation; they cannot close another adapter's streams.
class NativeCefHttp2Pool {
  NativeCefHttp2Pool({SecurityContext? securityContext}) : _securityContext = securityContext;
  final SecurityContext? _securityContext;
  final _origins = <String, standard.ClientPool>{};
  final _connections = <h2.ClientTransportConnection, SecureSocket>{};
  final _connectionOrigins = <h2.ClientTransportConnection, String>{};
  final _used = <h2.ClientTransportConnection>{};
  late final _priorities = <h2.ClientTransportConnection, NativeHttp2PriorityDependencies>{};
  bool _closed = false;
  CancellationToken? _cancellation;
  CancellationToken get _token => _cancellation ??= CancellationToken();
  int openedConnections = 0, reusedConnections = 0;

  bool hasAvailableConnection(Uri uri) => _connectionOrigins.entries.any((entry) =>
    entry.value == '${uri.host}:${uri.port}' && entry.key.isOpen);

  /// Prepare only TLS/H2. Releasing the lease emits no application request.
  Future<void> prepareOrigin(Uri uri, Duration timeout) async {
    final lease = await acquire(uri, timeout);
    lease.release();
  }

  Future<NativeCefHttp2Lease> acquire(Uri uri, Duration timeout) async {
    if (_closed) throw StateError('Native CEF H2 pool is closed');
    final origin = '${uri.host}:${uri.port}';
    final pool = _origins.putIfAbsent(origin, () => standard.ClientPool(
      () => _open(uri, timeout), maxConcurrentStreams: 100, maxIdleConnections: 1));
    // A peer may have closed an idle connection. Replace it before writing
    // any request. Once makeRequest runs, failures propagate without replay.
    for (var attempt = 0; attempt < 2; attempt++) {
      final lease = await pool.acquire();
      if (_closed || !lease.connection.isOpen) {
        lease.markFailed(); lease.release();
        if (_closed) throw StateError('Native CEF H2 pool is closed');
        continue;
      }
      if (!_used.add(lease.connection)) reusedConnections++;
      return NativeCefHttp2Lease._(lease,
        _priorities.putIfAbsent(lease.connection, NativeHttp2PriorityDependencies.new));
    }
    throw const HttpException('H2 peer closed before request admission');
  }

  Future<implementation.ClientConnection> _open(Uri uri, Duration timeout) async {
    final token = _token;
    token.throwIfCancelled();
    final task = await SecureSocket.startConnect(uri.host, uri.port,
      context: _securityContext, supportedProtocols: const ['h2']);
    if (token.isCancelled) { task.cancel(); token.throwIfCancelled(); }
    final cleanup = CancellationRegistration(token, onCancel: (_) => task.cancel());
    final SecureSocket socket;
    try {
      socket = await task.socket.timeout(timeout, onTimeout: () {
        task.cancel(); throw TimeoutException('Native CEF H2 connection deadline', timeout);
      });
      if (token.isCancelled) { socket.destroy(); token.throwIfCancelled(); }
    } finally { cleanup.dispose(); }
    if (_closed || socket.selectedProtocol != 'h2') {
      socket.destroy();
      throw StateError('Native CEF H2 route did not negotiate the captured protocol');
    }
    final connection = h2.ClientTransportConnection.viaSocket(socket,
      settings: const h2.ClientSettings(headerTableSize: 65536, allowServerPushes: false,
        streamWindowSize: 6291456, maxHeaderListSize: 262144,
        connectionWindowSize: 15728640)) as implementation.ClientConnection;
    _connections[connection] = socket;
    _connectionOrigins[connection] = '${uri.host}:${uri.port}';
    openedConnections++;
    void forget() {
      _connections.remove(connection); _connectionOrigins.remove(connection); _used.remove(connection);
      _priorities.remove(connection);
    }
    unawaited(socket.done.then<void>((_) => forget(), onError: (Object _) => forget()));
    // Original cold native H2 sessions send HEADERS before receiving initial
    // server SETTINGS, including metadata sessions697/1907 in the pinned
    // upload capture. The standard transport sends its preface immediately
    // and applies peer settings when received; do not add a round-trip here.
    // Once dispatched, normal stream errors/deadlines propagate without replay.
    return connection;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _token.cancel();
    for (final entry in _connections.entries.toList()) {
      unawaited(entry.key.terminate().catchError((Object _) => null));
      entry.value.destroy();
    }
    _connections.clear(); _connectionOrigins.clear(); _used.clear();
    _priorities.clear();
    for (final pool in _origins.values) {
      unawaited(pool.terminate().catchError((Object _) {}));
    }
    _origins.clear();
  }
}

class NativeCefHttp2Lease {
  NativeCefHttp2Lease._(this._lease, this._priorities);
  final standard.PoolLease _lease;
  final NativeHttp2PriorityDependencies _priorities;
  h2.ClientTransportConnection get connection => _lease.connection;
  h2.ClientTransportStream makeRequest(List<h2.Header> headers,
      {required int priorityBand, bool endStream = false}) =>
    _priorities.makeRequest(connection, headers, priorityBand: priorityBand, endStream: endStream);
  void release() => _lease.release();
  void markFailed() => _lease.markFailed();
}
