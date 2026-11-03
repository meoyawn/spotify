import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';
import 'package:http2/transport.dart' as h2;
import 'package:protobuf/protobuf.dart';

import '../protocol/request_builder.dart';
import '../transport/quiche/client.dart' show Http3ConnectionException, Http3ConnectionFailure;
import 'native_playplay_body.dart';
import 'native_playplay_request.dart';

/// Original response layout: generated writer1004d7880 emits bytes fields1/2.
/// The first is the obfuscated input of10048de68, not a plaintext audio key.
final class NativePlayPlayLicenseReply {
  NativePlayPlayLicenseReply._(this.obfuscatedBytes, this.auxiliaryBytes, this.rawBytes);

  factory NativePlayPlayLicenseReply.fromBuffer(List<int> bytes) {
    final reader = CodedBufferReader(bytes);
    var first = Uint8List(0), second = Uint8List(0);
    while (true) {
      final tag = reader.readTag();
      if (tag == 0) break;
      if (tag == 10) { first = Uint8List.fromList(reader.readBytes()); }
      else if (tag == 18) { second = Uint8List.fromList(reader.readBytes()); }
      else if (!reader.skipField(tag)) {
        throw const FormatException('Invalid Spotify music license response');
      }
    }
    if (first.length != 16) {
      throw const FormatException('Spotify music license did not contain its16-byte obfuscated field');
    }
    return NativePlayPlayLicenseReply._(first.asUnmodifiableView(), second.asUnmodifiableView(),
      Uint8List.fromList(bytes).asUnmodifiableView());
  }

  final Uint8List obfuscatedBytes, auxiliaryBytes, rawBytes;
}

final class NativePlayPlayLicenseException implements Exception {
  NativePlayPlayLicenseException(this.statusCode, {this.retryAfter,
    List<int> responseBody = const [], Map<String, String> responseHeaders = const {}})
    : responseBody = Uint8List.fromList(responseBody.take(4096).toList()).asUnmodifiableView(),
      responseHeaders = Map.unmodifiable({for (final entry in responseHeaders.entries)
        if (const {'date', 'retry-after', 'content-type', 'server', 'x-ratelimit-limit',
          'x-ratelimit-remaining', 'x-ratelimit-reset'}.contains(entry.key.toLowerCase()))
            entry.key.toLowerCase(): entry.value});
  final int statusCode;
  final String? retryAfter;
  final Uint8List responseBody;
  final Map<String, String> responseHeaders;
  @override String toString() => 'Spotify music license returned HTTP $statusCode';
}

final class NativePlayPlayLicenseCancelled extends CancelledException {
  const NativePlayPlayLicenseCancelled();
  @override String toString() => 'The music source no longer owns this key request.';
}

/// State of one original10048c2cc client, shared by its independently owned
/// jobs. The caller chooses that client's lifetime; other clients stay separate.
final class NativePlayPlayMusicKeyClientState {
  final cancellation = CancellationToken();
  Future<void>? disabling;
}

bool _disablesMusicKeyClient(List<int> bytes) {
  if (bytes.isEmpty) return false;
  try {
    final reader = CodedBufferReader(bytes);
    var value = 0;
    while (true) {
      final tag = reader.readTag();
      if (tag == 0) return value == 3;
      if (tag == 8) { value = reader.readInt32(); }
      else if (!reader.skipField(tag)) { return false; }
    }
  } on InvalidProtocolBufferException {
    return false;
  } on ArgumentError {
    return false;
  }
}

void _disableMusicKeyClient(NativePlayPlayMusicKeyClientState client,
    NativePlayPlayLicenseException rejection) {
  if (client.disabling != null || client.cancellation.isCancelled) return;
  // Original10048f338 first fails this job, then queues1004bf384 with delay0.
  // This belongs to the client, so withdrawing the rejected source alone must
  // not discard the owner's pending disable. Retirement cancels the actual task.
  client.disabling = () async {
    try {
      await CancellableFuture.delayed<void>(Duration.zero, client.cancellation);
      // The package delay completes synchronously before detaching its timer.
      // Leave that callback before cancelling its parent token.
      await CancellableFuture.value<void>(null, client.cancellation);
      client.cancellation.throwIfCancelled();
      client.cancellation.cancel(rejection);
    } catch (error) {
      if (!client.cancellation.isCancelled) rethrow;
    }
  }();
}

/// One owned music-key job, including original same-job HTTP/transport retries.
/// Template, native interactivity,
/// clock and cache identity are explicit original-owner inputs. Session/auth,
/// concurrent-job deduplication and protected-key interpretation stay outside.
class NativePlayPlayMusicKeyExchange {
  NativePlayPlayMusicKeyExchange({required this.template, required this.send,
    required this.timestampSeconds, required List<int> cacheId,
    NativePlayPlayMusicKeyClientState? clientState})
    : cacheId = Uint8List.fromList(cacheId).asUnmodifiableView(),
      clientState = clientState ?? NativePlayPlayMusicKeyClientState() {
    if (cacheId.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('PlayPlay cache identity must contain octets');
    }
  }

  final RequestEnvelope template;
  final Future<http.Response> Function(RequestEnvelope request) send;
  final int Function() timestampSeconds;
  final Uint8List cacheId;
  final NativePlayPlayMusicKeyClientState clientState;

  Future<NativePlayPlayLicenseReply> request(List<int> fileId20,
      {required int nativeInteractivity, CancellationToken? cancellationToken,
       void Function(Object error, int attempt, Duration delay)? onRetry,
       Future<void> Function(Duration delay)? waitForRetry}) async {
    final token = MergedCancellationToken([clientState.cancellation,
      ?template.cancellationToken, ?cancellationToken]);
    void checkOwner() { token.throwIfCancelled(); }
    checkOwner();
    final body = NativePlayPlayLicenseBody(cacheId: cacheId,
      timestampSeconds: timestampSeconds(), nativeInteractivity: nativeInteractivity).encode();
    final plan = NativePlayPlayRequestPlan.musicKey(template: template,
      fileId20: fileId20, serializedBody: body);
    var attempt = 0;
    while (true) {
      checkOwner();
      attempt++;
      final http.Response response;
      try { response = await send(plan.request.withCancellation(token)).asCancellable(token); }
      catch (error) {
        checkOwner();
        if (!_retryableTransport(error)) rethrow;
        // Original1004bebac retries non-aborted HTTP transport failures on the
        // same serialized job, without the extra rate-limit delay.
        final delay = retryDelay(attempt: attempt, nativeInteractivity: nativeInteractivity,
          rateLimited: false);
        onRetry?.call(error, attempt, delay);
        await (waitForRetry?.call(delay) ?? CancellableFuture.delayed<void>(delay, token));
        continue;
      }
      checkOwner();
      if (response.statusCode == 200) return NativePlayPlayLicenseReply.fromBuffer(response.bodyBytes);
      final error = NativePlayPlayLicenseException(response.statusCode,
        retryAfter: response.headers['retry-after'], responseBody: response.bodyBytes,
        responseHeaders: response.headers);
      if (response.statusCode == 403 && _disablesMusicKeyClient(response.bodyBytes)) {
        _disableMusicKeyClient(clientState, error);
      }
      if (response.statusCode == 402 || response.statusCode == 403) throw error;
      final delay = retryDelay(attempt: attempt, nativeInteractivity: nativeInteractivity,
        rateLimited: response.statusCode == 429);
      onRetry?.call(error, attempt, delay);
      // Original10048f4f8 keeps the same job and calls10048cbcc again. Do not
      // rebuild its serialized body, identity or template for a retry.
      await (waitForRetry?.call(delay) ?? CancellableFuture.delayed<void>(delay, token));
    }
  }

  static bool _retryableTransport(Object error) {
    if (error is http.RequestAbortedException || error is Http3ConnectionException &&
        error.failure == Http3ConnectionFailure.cancelled) return false;
    return error is SocketException || error is TlsException || error is TimeoutException ||
      error is HttpException || error is http.ClientException || error is h2.TransportException;
  }

  static Duration retryDelay({required int attempt, required int nativeInteractivity,
      bool rateLimited = true}) {
    final wire = nativeInteractivity == 0 ? 1 : nativeInteractivity == 2 ? 3 : 2;
    final shift = (attempt - 2).clamp(0, 9);
    final backoff = attempt < 2 ? 0 : 1 << shift;
    return Duration(seconds: (rateLimited ? wire == 1 ? 3 : 30 : 0) + backoff);
  }
}
