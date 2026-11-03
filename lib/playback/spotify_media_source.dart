import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';

import 'audio_source.dart';
import 'native_audio_quality.dart';
import 'native_audio_selection.dart';
import 'native_cdn_recovery.dart';
import '../protocol/generated/storage-resolve.pb.dart' as storage;
import 'spotify_audio_decrypt.dart';
import 'spotify_audio_stager.dart';
import 'spotify_media_client.dart';
import 'spotify_media_cache.dart';

final class SpotifyAudioSelection {
  SpotifyAudioSelection({required this.uri, required List<int> fileId, required List<int> trackGid,
    required this.container, required this.storageMode, required this.audioFormat,
    this.partner = '', Map<String, Object?> metadata = const {}})
    : fileId = Uint8List.fromList(_fileId(fileId)).asUnmodifiableView(),
      trackGid = Uint8List.fromList(_trackGid(trackGid)).asUnmodifiableView(),
      metadata = Map.unmodifiable(metadata);

  /// Carry the original filter's admitted pair directly into storage/key
  /// requests. The owning account policy still supplies rank, flags, track,
  /// container and mode; this factory grants no permission of its own.
  factory SpotifyAudioSelection.fromNativeCandidate({required String uri,
    required NativeAudioFileCandidate candidate, required List<int> trackGid,
    required SpotifyAudioContainer container, required int storageMode,
    String partner = '', Map<String, Object?> metadata = const {}}) =>
    SpotifyAudioSelection(uri: uri, fileId: candidate.fileId, audioFormat: candidate.format,
      trackGid: trackGid, container: container, storageMode: storageMode,
      partner: partner, metadata: metadata);

  /// Rank and filter only candidates already admitted by metadata/account
  /// policy. This joins the recovered preference, rank and format owners to
  /// the real storage/key request pair, without inventing eligibility or codec
  /// capabilities. The decoder owner supplies each admitted format's container.
  factory SpotifyAudioSelection.fromNativePolicy({required String uri,
    required Iterable<NativeAudioFileCandidate> eligibleFiles,
    required NativeAudioQuality quality, required NativeAudioFormatPolicy formatPolicy,
    required List<int> trackGid,
    required SpotifyAudioContainer Function(NativeAudioFileCandidate) containerFor,
    required int storageMode, String partner = '', Map<String, Object?> metadata = const {}}) {
    final selected = formatPolicy.selectOrdered(quality.rankPolicy.order(eligibleFiles));
    if (selected == null) throw const FormatException('No audio file admitted by the native selection policy');
    return SpotifyAudioSelection.fromNativeCandidate(uri: uri, candidate: selected,
      trackGid: trackGid, container: containerFor(selected), storageMode: storageMode,
      partner: partner, metadata: metadata);
  }
  final String uri;
  final Uint8List fileId, trackGid;
  final SpotifyAudioContainer container;
  final int storageMode, audioFormat;
  final String partner;
  final Map<String, Object?> metadata;
}

/// Connects Dart metadata/file policy, guarded requests, authorized keys and
/// decryption to DartAudioEngine.resolveSpotifySource. Nothing is installed by
/// default. The session owner must supply verified format/range/CDN policy and
/// enforce actual account, advert and playback restrictions before selection.
/// Progressive staging can publish PCM while the encrypted source is arriving.
class SpotifyMediaSource {
  SpotifyMediaSource({required this.client, required this.stager,
    required this.selectAudio, required this.obtainDecryption,
    required this.selectCdn, required this.rangeBytes, this.cache,
    this.decryptionAdmission}) {
    if (rangeBytes <= 0) throw RangeError.value(rangeBytes, 'rangeBytes');
  }

  final SpotifyMediaClient client;
  final SpotifyAudioStager stager;
  final Future<SpotifyAudioSelection> Function(String uri, {CancellationToken? cancellationToken}) selectAudio;
  final Future<SpotifyAudioDecryptor> Function(SpotifyAudioSelection selection,
    {CancellationToken? cancellationToken}) obtainDecryption;
  /// A real license response or retained successful key can admit the media
  /// request before local key unwrapping finishes. Without this signal the
  /// source retains its original wait-for-decryptor behavior.
  final Future<void>? decryptionAdmission;
  final String Function(storage.StorageResolveResponse response) selectCdn;
  final int rangeBytes;
  final SpotifyMediaCache? cache;

  Future<PreparedAudioFile> resolve(String uri, {CancellationToken? cancellationToken}) async {
    final owner = CancellationToken();
    final token = MergedCancellationToken([owner, ?cancellationToken]);
    token.throwIfCancelled();
    try { return await _resolve(uri, token); }
    catch (_) { owner.cancel(); rethrow; }
  }

  Future<PreparedAudioFile> _resolve(String uri, CancellationToken cancellationToken) async {
    cancellationToken.throwIfCancelled();
    final selection = await selectAudio(uri, cancellationToken: cancellationToken)
      .asCancellable(cancellationToken);
    cancellationToken.throwIfCancelled();
    if (selection.uri != uri) throw const FormatException('Selected audio belongs to a different item');
    final cached = await cache?.read(selection.fileId, cancellationToken: cancellationToken);
    if (cached != null) {
      Stream<List<int>> ownedRead() async* {
        try { yield* cached.openRead(); }
        finally { await cached.close(); }
      }
      try {
        cancellationToken.throwIfCancelled();
        final decryptor = await obtainDecryption(selection, cancellationToken: cancellationToken)
          .asCancellable(cancellationToken);
        return await stager.stage(ownedRead(), encryptedLength: cached.length,
          decryptor: decryptor, container: selection.container, metadata: selection.metadata,
          cancellationToken: cancellationToken);
      } catch (_) { await cached.close(); rethrow; }
    }
    // Original captures start the key job before storage and open the CDN as
    // soon as successful license/storage replies are available. Local Dart key
    // unwrapping need not delay DNS/TLS and the first encrypted bytes.
    cancellationToken.throwIfCancelled();
    final decryption = obtainDecryption(selection, cancellationToken: cancellationToken)
      .asCancellable(cancellationToken);
    final admitted = Future.any<void>([
      if (decryptionAdmission != null) decryptionAdmission!,
      decryption.then<void>((_) {}),
    ]);
    final resolution = client.storageResolve(selection.fileId,
      storageMode: selection.storageMode, audioFormat: selection.audioFormat, partner: selection.partner,
      cancellationToken: cancellationToken);
    late final NativeCdnResourceCursor resources;
    late final SpotifyAudioRange first;
    StreamIterator<List<int>>? openedReader;
    Future<void>? readerCancellation;
    Future<void> cancelOpenedReader() {
      final reader = openedReader;
      if (reader == null) return Future<void>.value();
      final pending = readerCancellation ??= reader.cancel();
      pending.ignore();
      return pending;
    }
    Future<StreamIterator<List<int>>> openMedia() async {
      final replies = await Future.wait<Object?>([admitted.then<Object?>((_) => null), resolution], eagerError: true)
        .asCancellable(cancellationToken);
      cancellationToken.throwIfCancelled();
      final resolved = replies[1] as storage.StorageResolveResponse;
      final url = selectCdn(resolved);
      if (!resolved.cdnurl.contains(url)) throw const FormatException('Selected CDN was not supplied by storage resolution');
      resources = NativeCdnResourceCursor(resolved.cdnurl)
        ..select(resolved.cdnurl.indexOf(url));
      first = await _range(resources, firstByte: 0, lastByte: rangeBytes - 1,
        cancellationToken: cancellationToken);
      final reader = openedReader = StreamIterator(first.bytes);
      // Start the owned stream and pause after one chunk. This bounds buffering
      // while key work finishes and gives failure cleanup a live subscription
      // to cancel, even through the response's async stream wrappers.
      if (!await reader.moveNext().asCancellable(cancellationToken,
          onCancel: () { unawaited(cancelOpenedReader()); })) {
        throw const FormatException('CDN audio body is empty');
      }
      return reader;
    }
    try {
      final prepared = await Future.wait<Object>([decryption, openMedia()], eagerError: true);
      cancellationToken.throwIfCancelled();
      final decryptor = prepared[0] as SpotifyAudioDecryptor;
      final reader = prepared[1] as StreamIterator<List<int>>;
      Stream<List<int>> initialBytes() async* {
        try {
          yield reader.current;
          while (await reader.moveNext()) { yield reader.current; }
        } finally { await cancelOpenedReader(); }
      }
      final download = _download(resources, first, firstBytes: initialBytes(), cancellationToken: cancellationToken);
      return await stager.stage(cache?.capture(selection.fileId, download,
          length: first.totalBytes, cancellationToken: cancellationToken) ?? download,
        encryptedLength: first.totalBytes,
        decryptor: decryptor, container: selection.container, metadata: selection.metadata,
        cancellationToken: cancellationToken);
    } catch (_) {
      await cancelOpenedReader();
      rethrow;
    }
  }

  Future<SpotifyAudioRange> _range(NativeCdnResourceCursor resources,
      {required int firstByte, required int lastByte, CancellationToken? cancellationToken}) async {
    // Original transient outcome1 searches after the failing resource. This
    // app bounds an early-header-close recovery to each supplied resource
    // once. Native host eligibility/backoff is outside the recovered slice.
    for (var remaining = resources.urls.length; remaining > 0; remaining--) {
      try {
        cancellationToken?.throwIfCancelled();
        return await client.audioRange(signedUrl: resources.currentUrl,
          firstByte: firstByte, lastByte: lastByte, cancellationToken: cancellationToken);
      } on HttpException catch (error) {
        // No response headers or body have been admitted in this exact Dart
        // transport failure, so retry the unchanged byte interval. A body
        // failure, HTTP rejection, cancellation or malformed range propagates.
        cancellationToken?.throwIfCancelled();
        if (error.message != 'Connection closed before full header was received' || remaining == 1) rethrow;
        resources.markTransientFailure();
        resources.select(resources.candidates.first.index);
      }
    }
    throw StateError('No supplied CDN resource remains');
  }

  Stream<List<int>> _download(NativeCdnResourceCursor resources, SpotifyAudioRange first,
      {Stream<List<int>>? firstBytes, CancellationToken? cancellationToken}) async* {
    cancellationToken?.throwIfCancelled();
    yield* firstBytes ?? first.bytes;
    int next = first.lastByte + 1;
    while (next < first.totalBytes) {
      final range = await _range(resources, firstByte: next,
        lastByte: next + min<int>(rangeBytes, first.totalBytes - next) - 1,
        cancellationToken: cancellationToken);
      if (range.totalBytes != first.totalBytes) {
        await range.bytes.listen(null).cancel();
        throw const FormatException('CDN file length changed during download');
      }
      yield* range.bytes;
      next = range.lastByte + 1;
    }
  }
}

List<int> _fileId(List<int> bytes) {
  if (bytes.length != 20 || bytes.any((value) => value < 0 || value > 255)) {
    throw ArgumentError('An audio file ID must contain 20 octets');
  }
  return bytes;
}

List<int> _trackGid(List<int> bytes) {
  if (bytes.length != 16 || bytes.any((value) => value < 0 || value > 255)) {
    throw ArgumentError('A selected track GID must contain 16 octets');
  }
  return bytes;
}
