import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;

import 'bindings.dart' as ng;

sealed class Http3Event {
  const Http3Event(this.streamId);
  final int streamId;
}
final class Http3Headers extends Http3Event {
  const Http3Headers(super.streamId, this.headers);
  final List<(String, String)> headers;
}
final class Http3Data extends Http3Event {
  const Http3Data(super.streamId, this.bytes);
  final Uint8List bytes;
}
final class Http3Finished extends Http3Event { const Http3Finished(super.streamId); }
final class Http3Stop extends Http3Event {
  const Http3Stop(super.streamId, this.read, this.error);
  final bool read;
  final int error;
}
final class Http3Shutdown extends Http3Event { const Http3Shutdown(super.streamId); }

/// Standard HTTP/3 and dynamic QPACK codec. The QUIC owner supplies actual
/// stream I/O and peer ACK offsets. No HTTP request, provider, retry, header
/// identity or Spotify session policy is constructed here.
final class Nghttp3Session {
  Nghttp3Session(this.api) {
    try { _initialize(); }
    catch (_) { close(); rethrow; }
  }
  final ng.Nghttp3Bindings api;
  final _arena = Arena();
  final _callbacks = <NativeCallable>[];
  final events = <Http3Event>[];
  final _headers = <int, List<(String, String)>>{};
  final _headerSizes = <int, int>{};
  final _uploads = <int, (Pointer<Uint8>, int, bool)>{};
  final writtenStreams = <int>{};
  final blockedStreams = <int>{};
  Pointer<ng.nghttp3_conn> connection = nullptr;
  Object? _callbackError;
  bool _closed = false;

  void _check(int value) {
    if (_callbackError case final error?) throw error;
    if (value < 0) throw http.ClientException(
      'HTTP/3 codec: ${api.nghttp3_strerror(value).cast<Utf8>().toDartString()} ($value)');
  }

  void _initialize() {
    final callbacks = _arena<ng.nghttp3_callbacks>();
    final begin = NativeCallable<ng.nghttp3_begin_headersFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, Pointer<Void> __, Pointer<Void> ___) {
        _headers[id] = []; _headerSizes[id] = 0; return 0;
      }, exceptionalReturn: -1);
    final header = NativeCallable<ng.nghttp3_recv_headerFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, int token, Pointer<ng.nghttp3_rcbuf> name,
          Pointer<ng.nghttp3_rcbuf> value, int flags, Pointer<Void> __, Pointer<Void> ___) {
        try {
          final key = api.nghttp3_rcbuf_get_buf(name), data = api.nghttp3_rcbuf_get_buf(value);
          final size = (_headerSizes[id] ?? 0) + key.len + data.len + 32;
          if (size > 262144) throw http.ClientException('HTTP/3 header section exceeds advertised limit');
          _headerSizes[id] = size;
          (_headers[id] ??= []).add((ascii.decode(key.base.asTypedList(key.len)),
            latin1.decode(data.base.asTypedList(data.len))));
          return 0;
        } catch (error) { _callbackError = error; return -1; }
      }, exceptionalReturn: -1);
    final end = NativeCallable<ng.nghttp3_end_headersFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, int fin, Pointer<Void> __, Pointer<Void> ___) {
        events.add(Http3Headers(id, _headers.remove(id) ?? []));
        _headerSizes.remove(id); return 0;
      }, exceptionalReturn: -1);
    final data = NativeCallable<ng.nghttp3_recv_dataFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, Pointer<Uint8> bytes, int length,
          Pointer<Void> __, Pointer<Void> ___) {
        events.add(Http3Data(id, Uint8List.fromList(bytes.asTypedList(length)))); return 0;
      }, exceptionalReturn: -1);
    final finished = NativeCallable<ng.nghttp3_end_streamFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, Pointer<Void> __, Pointer<Void> ___) {
        events.add(Http3Finished(id)); return 0;
      }, exceptionalReturn: -1);
    final stop = NativeCallable<ng.nghttp3_stop_sendingFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, int error, Pointer<Void> __, Pointer<Void> ___) {
        events.add(Http3Stop(id, true, error)); return 0;
      }, exceptionalReturn: -1);
    final reset = NativeCallable<ng.nghttp3_reset_streamFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, int error, Pointer<Void> __, Pointer<Void> ___) {
        events.add(Http3Stop(id, false, error)); return 0;
      }, exceptionalReturn: -1);
    final shutdown = NativeCallable<ng.nghttp3_shutdownFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, Pointer<Void> __) { events.add(Http3Shutdown(id)); return 0; }, exceptionalReturn: -1);
    final random = Random.secure();
    final rand = NativeCallable<ng.nghttp3_randFunction>.isolateLocal(
      (Pointer<Uint8> bytes, int length) {
        bytes.asTypedList(length).setAll(0, List.generate(length, (_) => random.nextInt(256)));
      });
    final reader = NativeCallable<ng.nghttp3_read_data_callbackFunction>.isolateLocal(
      (Pointer<ng.nghttp3_conn> _, int id, Pointer<ng.nghttp3_vec> vectors, int capacity,
          Pointer<Uint32> flags, Pointer<Void> __, Pointer<Void> ___) {
        try {
          final upload = _uploads[id];
          flags.value |= ng.NGHTTP3_DATA_FLAG_EOF;
          if (upload == null || upload.$3) return 0;
          if (capacity == 0) return ng.NGHTTP3_ERR_WOULDBLOCK;
          vectors.ref..base = upload.$1..len = upload.$2;
          _uploads[id] = (upload.$1, upload.$2, true);
          return 1;
        } catch (error) { _callbackError = error; return ng.NGHTTP3_ERR_CALLBACK_FAILURE; }
      }, exceptionalReturn: -1);
    _callbacks.addAll([begin, header, end, data, finished, stop, reset, shutdown, rand, reader]);
    callbacks.ref
      ..begin_headers = begin.nativeFunction..recv_header = header.nativeFunction
      ..end_headers = end.nativeFunction..begin_trailers = begin.nativeFunction
      ..recv_trailer = header.nativeFunction..end_trailers = end.nativeFunction
      ..recv_data = data.nativeFunction..end_stream = finished.nativeFunction
      ..stop_sending = stop.nativeFunction..reset_stream = reset.nativeFunction
      ..shutdown = shutdown.nativeFunction..rand = rand.nativeFunction;
    _reader = _arena<ng.nghttp3_data_reader>()..ref.read_data = reader.nativeFunction;
    final settings = _arena<ng.nghttp3_settings>();
    api.nghttp3_settings_default_versioned(ng.NGHTTP3_SETTINGS_VERSION, settings);
    // All four default original NetLogs agree (97 named SETTINGS events).
    settings.ref..max_field_section_size = 262144..qpack_max_dtable_capacity = 65536
      ..qpack_encoder_max_dtable_capacity = 65536..qpack_blocked_streams = 100..h3_datagram = 1;
    final output = _arena<Pointer<ng.nghttp3_conn>>();
    _check(api.nghttp3_conn_client_new_versioned(output, ng.NGHTTP3_CALLBACKS_VERSION,
      callbacks, ng.NGHTTP3_SETTINGS_VERSION, settings, nullptr, nullptr));
    connection = output.value;
    using((temporary) {
      // Original public QuicSendControlStream draws two independent uint32s.
      // NetLog casts the value to signed int32; the wire keeps all 32 bits.
      final id = temporary<Uint64>()..value = 31 * random.nextInt(0x100000000) + 33;
      final value = temporary<Uint64>()..value = random.nextInt(0x100000000);
      _check(api.nghttp3_conn_set_additional_settings(connection, id, value, 1));
      // The next uint32 determines both the reserved frame type and length.
      // This is drawn once per session, before control-stream bytes are queued.
      final frameIndex = random.nextInt(0x100000000);
      final length = frameIndex % 4;
      final payload = length == 0 ? nullptr.cast<Uint8>() : temporary<Uint8>(length);
      for (var index = 0; index < length; index++) payload[index] = random.nextInt(256);
      _check(api.nghttp3_conn_set_additional_control_frame(connection,
        31 * frameIndex + 33, payload, length));
    });
    _check(api.nghttp3_conn_bind_control_stream(connection, 2));
    _check(api.nghttp3_conn_bind_qpack_streams(connection, 6, 10));
  }
  late final Pointer<ng.nghttp3_data_reader> _reader;

  void submit(int id, List<(String, String)> fields, Pointer<Uint8> payload, int length) {
    using((temporary) {
      final headers = temporary<ng.nghttp3_nv>(fields.length);
      for (var index = 0; index < fields.length; index++) {
        final (name, value) = fields[index];
        final key = utf8.encode(name), bytes = utf8.encode(value);
        (headers + index).ref
          ..name = (temporary<Uint8>(max(1, key.length))..asTypedList(key.length).setAll(0, key))
          ..namelen = key.length
          ..value = (temporary<Uint8>(max(1, bytes.length))..asTypedList(bytes.length).setAll(0, bytes))
          ..valuelen = bytes.length..flags = ng.NGHTTP3_NV_FLAG_NONE;
      }
      if (length > 0) _uploads[id] = (payload, length, false);
      _check(api.nghttp3_conn_submit_request(connection, id, headers,
        fields.length, length == 0 ? nullptr : _reader, nullptr));
      // Original H3 sends one request-stream PRIORITY_UPDATE with the exact
      // Priority field value. The standard codec copies these bytes and queues
      // the control frame before its output writer selects request headers.
      for (final (name, value) in fields) {
        if (name != 'priority') continue;
        final bytes = ascii.encode(value);
        final data = temporary<Uint8>(max(1, bytes.length))..asTypedList(bytes.length).setAll(0, bytes);
        _check(api.nghttp3_conn_set_client_stream_priority(connection, id, data, bytes.length));
        break;
      }
    });
  }

  void receive(int id, Pointer<Uint8> bytes, int length, bool fin) =>
    _check(api.nghttp3_conn_read_stream(connection, id, bytes, length, fin ? 1 : 0));

  /// Every vector stays owned by nghttp3 until real QUIC ACKs (or closeStream).
  void write(int Function(int id, Pointer<Uint8> bytes, int length, bool fin) send) {
    using((temporary) {
      final id = temporary<Int64>(), fin = temporary<Int>(), vectors = temporary<ng.nghttp3_vec>(16);
      for (var turn = 0; turn < 1024; turn++) {
        final count = api.nghttp3_conn_writev_stream(connection, id, fin, vectors, 16);
        _check(count);
        if (id.value < 0) break;
        var accepted = 0;
        var blocked = false;
        var stopped = false;
        for (var index = 0; index < max(1, count); index++) {
          final vector = (vectors + index).ref;
          final length = count == 0 ? 0 : vector.len;
          final result = send(id.value, count == 0 ? nullptr : vector.base, length,
            fin.value != 0 && index == max(1, count) - 1);
          if (result == -1 || result == -13) { blocked = true; break; }
          if (result == -15) { stopped = true; break; }
          if (result < 0) throw http.ClientException('QUIC stream write failed ($result)');
          accepted += result;
          if (result < length) { blocked = true; break; }
        }
        _check(api.nghttp3_conn_add_write_offset(connection, id.value, accepted));
        writtenStreams.add(id.value);
        if (blocked && !stopped) {
          api.nghttp3_conn_block_stream(connection, id.value);
          blockedStreams.add(id.value);
        }
      }
    });
  }

  void unblock(int id) {
    _check(api.nghttp3_conn_unblock_stream(connection, id));
    blockedStreams.remove(id);
  }
  void acknowledge(int id, int offset) => _check(api.nghttp3_conn_update_ack_offset(connection, id, offset));
  bool isWriteFlushed(int id) => api.nghttp3_conn_is_stream_flushed(connection, id) != 0;
  void stopUpload(int id) {
    api.nghttp3_conn_shutdown_stream_write(connection, id);
    _uploads.remove(id);
  }
  void closeStream(int id, {int error = 0x100}) {
    final result = api.nghttp3_conn_close_stream(connection, id, error);
    if (result != ng.NGHTTP3_ERR_STREAM_NOT_FOUND) _check(result);
    _uploads.remove(id); _headers.remove(id); _headerSizes.remove(id);
    writtenStreams.remove(id); blockedStreams.remove(id);
  }
  void close() {
    if (_closed) return;
    _closed = true;
    if (connection != nullptr) api.nghttp3_conn_del(connection);
    connection = nullptr;
    for (final callback in _callbacks) { callback.close(); }
    _callbacks.clear(); events.clear(); _uploads.clear(); _headers.clear(); _headerSizes.clear();
    writtenStreams.clear(); blockedStreams.clear();
    _arena.releaseAll();
  }
}
