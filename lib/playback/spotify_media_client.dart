import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/request_builder.dart';
import '../protocol/native_http_credentials.dart';
import '../protocol/generated/extended_metadata.pb.dart' as metadata;
import '../protocol/generated/storage-resolve.pb.dart' as storage;
import 'spotify_requests.dart';

typedef SpotifyMediaSend = Future<http.StreamedResponse> Function(RequestEnvelope request);

final class SpotifyMediaHttpException implements Exception {
  const SpotifyMediaHttpException(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Spotify media HTTP status $statusCode';
}

final class SpotifyAudioRange {
  const SpotifyAudioRange({required this.firstByte, required this.lastByte,
    required this.totalBytes, required this.bytes});
  final int firstByte, lastByte, totalBytes;
  final Stream<List<int>> bytes;
}

/// Dart request/response owner. The caller injects the existing guarded Dart
/// sender; this class creates no client, connection, retries or credentials.
/// Application fields do not establish complete original HTTP wire behavior.
class SpotifyMediaClient {
  const SpotifyMediaClient({required this.requests, required this.send, this.playbackId16});

  /// Apply the original native credential decorators to metadata, storage and
  /// signed media requests before the separately verified transport boundary.
  factory SpotifyMediaClient.authenticated({required SpotifyRequests requests,
    required NativeHttpCredentials credentials, required SpotifyMediaSend send}) =>
    SpotifyMediaClient(requests: requests,
      send: (request) async => send(await credentials.prepare(request)));
  final SpotifyRequests requests;
  final SpotifyMediaSend send;
  final List<int>? playbackId16;

  Future<metadata.BatchedExtensionResponse> extendedMetadata(
    metadata.BatchedEntityRequest request, {CancellationToken? cancellationToken}) async =>
    metadata.BatchedExtensionResponse.fromBuffer(await _protobuf(
      requests.extendedMetadata(request), cancellationToken));

  Future<storage.StorageResolveResponse> storageResolve(List<int> fileId,
    {required int storageMode, required int audioFormat, String partner = '',
      CancellationToken? cancellationToken}) async {
    final response = storage.StorageResolveResponse.fromBuffer(await _protobuf(
      requests.storageResolve(fileId, storageMode: storageMode, audioFormat: audioFormat, partner: partner),
      cancellationToken));
    if (response.result != storage.StorageResolveResponse_Result.CDN || response.cdnurl.isEmpty) {
      throw const FormatException('Storage resolver did not authorize a CDN source');
    }
    if (response.fileid.isNotEmpty && !_sameBytes(response.fileid, fileId)) {
      throw const FormatException('Storage resolver returned a different file');
    }
    return response;
  }

  /// A signed URL is passed through intact. Validate offsets before allowing
  /// decryption: a successful HTTP status alone cannot identify a byte range.
  Future<SpotifyAudioRange> audioRange({required String signedUrl,
    required int firstByte, required int lastByte, CancellationToken? cancellationToken}) async {
    final response = await _send(requests.signedCdnRange(signedUrl: signedUrl,
      firstByte: firstByte, lastByte: lastByte, playbackId16: playbackId16), cancellationToken);
    try {
      if (response.statusCode != 206) throw SpotifyMediaHttpException(response.statusCode);
      final value = _header(response.headers, 'content-range');
      final match = value == null ? null : RegExp(r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$').firstMatch(value);
      final start = int.tryParse(match?.group(1) ?? '');
      final end = int.tryParse(match?.group(2) ?? '');
      final total = int.tryParse(match?.group(3) ?? '');
      if (start == null || end == null || total == null || start != firstByte ||
          end < start || total <= end || end > lastByte ||
          end != lastByte && end != total - 1) {
        throw const FormatException('CDN response does not match the requested range');
      }
      final length = end - start + 1;
      if (response.contentLength != null && response.contentLength != length) {
        throw const FormatException('CDN response length disagrees with its range');
      }
      return SpotifyAudioRange(firstByte: start, lastByte: end, totalBytes: total,
        bytes: _body(response.stream, cancellationToken, length: length));
    } catch (_) {
      await response.stream.listen(null).cancel();
      rethrow;
    }
  }

  Future<http.StreamedResponse> _send(RequestEnvelope request, CancellationToken? token) async {
    token?.throwIfCancelled();
    final response = await send(token == null ? request : request.withCancellation(token));
    if (token?.isCancelled == true) {
      await response.stream.listen(null).cancel();
      token!.throwIfCancelled();
    }
    return response;
  }

  Future<Uint8List> _protobuf(RequestEnvelope request, CancellationToken? token) async {
    final response = await _send(request, token);
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw SpotifyMediaHttpException(response.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in _body(response.stream, token)) {
      if (chunk.length > 8 * 1024 * 1024 - bytes.length) {
        throw const FormatException('Metadata response exceeds the supported size');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Stream<List<int>> _body(Stream<List<int>> body, CancellationToken? token, {int? length}) async* {
    final iterator = StreamIterator(body);
    Future<void>? cancellation;
    Future<void> cancelInput() {
      final pending = cancellation ??= iterator.cancel();
      pending.ignore();
      return pending;
    }
    var count = 0;
    try {
      while (true) {
        token?.throwIfCancelled();
        if (!await iterator.moveNext().asCancellable(token,
            onCancel: () { unawaited(cancelInput()); })) { break; }
        token?.throwIfCancelled();
        final chunk = iterator.current;
        if (length != null && chunk.length > length - count) {
          throw const FormatException('CDN body exceeds its range');
        }
        count += chunk.length;
        yield chunk;
      }
      token?.throwIfCancelled();
      if (length != null && count != length) throw const FormatException('CDN body ended before its range');
    } finally { await cancelInput(); }
  }
}

String? _header(Map<String, String> headers, String name) {
  final values = headers.entries.where((entry) => entry.key.toLowerCase() == name).toList();
  return values.length == 1 ? values.single.value : null;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) { if (left[i] != right[i]) return false; }
  return true;
}
