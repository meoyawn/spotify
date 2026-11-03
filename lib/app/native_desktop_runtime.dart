import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:cancellation_token/cancellation_token.dart';

import '../entities/repository.dart';
import '../entities/models.dart';
import '../entities/native_artist_repository.dart';
import '../entities/native_playlist_repository.dart';
import '../home/repository.dart';
import '../home/models.dart';
import '../home/native_recent_contexts.dart';
import '../home/destinations_repository.dart';
import '../library/repository.dart';
import '../library/saved_tracks.dart';
import '../library/native_collection_read_client.dart';
import '../library/native_saved_track_service.dart';
import '../library/native_saved_tracks.dart';
import '../library/native_rootlist_repository.dart';
import '../library/native_library_repository.dart';
import '../library/native_metadata_client.dart';
import '../playlist_service/native_read_client.dart';
import '../playlist_service/native_rootlist_read_client.dart';
import '../playlist_service/native_track_metadata_request.dart';
import '../playback/audio_source.dart';
import '../async/cancellation.dart';
import '../async/shared_task.dart';
import '../playback/context_player_backend.dart';
import '../playback/engine.dart';
import '../playback/ffmpeg_audio_decoder.dart';
import '../playback/ffmpeg_streaming_decoder.dart';
import '../playback/native_ap_packet_policy.dart';
import '../playback/native_ap_session.dart';
import '../playback/native_audio_files.dart';
import '../playback/native_audio_files_request.dart';
import '../playback/native_audio_quality.dart';
import '../playback/native_audio_selection.dart';
import '../playback/native_connect_state_publisher.dart';
import '../playback/native_playplay_license.dart';
import '../playback/native_playplay_canary.dart';
import '../playback/native_playplay_key_worker.dart';
import '../playback/native_playback_id.dart';
import '../playback/prepared_audio_cache.dart';
import '../playback/session_audio_key_cache.dart';
import '../playback/native_spotify_gid.dart';
import '../playback/native_track_relinker.dart';
import '../playback/spotify_ap.dart';
import '../playback/spotify_ap_session.dart';
import '../playback/spotify_audio_decrypt.dart';
import '../playback/spotify_audio_stager.dart';
import '../playback/spotify_media_client.dart';
import '../playback/spotify_media_source.dart';
import '../playback/spotify_media_cache.dart';
import '../playback/streaming_cache_directory.dart';
import '../playback/spotify_metadata.dart';
import '../playback/spotify_requests.dart';
import '../protocol/desktop_identity.dart';
import '../protocol/esperanto.dart';
import '../protocol/dpop_key.dart';
import '../protocol/dpop_proof.dart';
import '../protocol/generated/es_prefs.pb.dart' as prefs;
import '../protocol/generated/connect.pb.dart' as connect;
import '../protocol/generated/devices.pbenum.dart' as devices;
import '../protocol/generated/extended_metadata.pb.dart' as metadata;
import '../protocol/generated/playlist_api.pb.dart' as playlist;
import '../protocol/generated/playlist_sync_reason.pb.dart';
import '../protocol/native_accounts_callback_server.dart';
import '../protocol/native_ap_authentication.dart';
import '../protocol/native_ap_hello.dart';
import '../protocol/native_ap_resolver.dart';
import '../protocol/native_ap_system_info.dart';
import '../protocol/native_cef_context.dart';
import '../protocol/native_cef_http2_transport.dart';
import '../protocol/native_cef_http2_pool.dart';
import '../protocol/native_cef_http3_transport.dart';
import '../protocol/native_cef_http_transport.dart';
import '../protocol/native_cef_request.dart';
import '../protocol/native_client_data.dart';
import '../protocol/native_client_token_codec.dart';
import '../protocol/native_client_token_provider.dart';
import '../protocol/native_desktop_accounts.dart';
import '../protocol/native_http_credentials.dart';
import '../protocol/native_http_defaults.dart';
import '../protocol/native_metadata_cache.dart';
import '../protocol/native_http_protocol_policy.dart';
import '../protocol/native_image_client.dart';
import '../protocol/native_image_request.dart';
import '../protocol/native_image_projection_map.dart';
import '../protocol/native_playlist_images.dart';
import '../protocol/native_playlist_mosaic.dart';
import '../protocol/native_legacy_auth_codec.dart';
import '../protocol/native_oauth_exchange.dart';
import '../protocol/native_oauth_refresh.dart';
import '../protocol/native_oauth_token_operation.dart';
import '../protocol/native_pusher_connection.dart';
import '../protocol/native_pusher_request.dart';
import '../protocol/native_renderer_http_request.dart';
import '../protocol/native_renderer_image_projections.dart';
import '../lyrics/repository.dart';
import '../protocol/native_renderer_cors.dart';
import '../protocol/native_renderer_http2_transport.dart';
import '../protocol/native_renderer_http3_transport.dart';
import '../protocol/native_token_provider.dart';
import '../protocol/pathfinder.dart';
import '../protocol/platform_identity.dart';
import '../protocol/prefs_store.dart';
import '../protocol/request_builder.dart';
import '../search/repository.dart';
import '../search/models.dart';
import '../transport/quiche/client.dart';
import 'app_runtime.dart';
import 'desktop_host.dart';
import 'desktop_session_vault.dart';
import 'artwork_disk_cache.dart';

/// Owns the installed desktop Accounts -> OAuth -> AP path in Dart. HTTP
/// application fields come from independently executed original producers and
/// native-context CEF captures. Standard Dart TLS/H2 are transport primitives;
/// their packet fingerprints are not claimed to reproduce Chromium.
class NativeDesktopRuntime implements SpotifyAppRuntime {
  NativeDesktopRuntime._({required this.deviceId, required this.preferences,
    required this.streamingDirectory, required this.context, required this.identity,
    required this.facts, required this.apSystemInfo, required this._streamingCache,
    CancellationToken? cancellationToken})
    : _ownerCancellation = cancellationToken;

  static Future<NativeDesktopRuntime> open({required String deviceId,
    required PrefsStore preferences, required Directory streamingDirectory,
    CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final catalogue = jsonDecode(await rootBundle.loadString('assets/protocol/native-desktop-locales.json')) as Map;
    cancellationToken?.throwIfCancelled();
    final supported = (catalogue['entries'] as List).map((entry) => (entry as Map)['locale'] as String).toList();
    final languages = await const DesktopHost().appleLanguages(cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    final selected = NativeCefContext.fromPreferences(appleLanguages: languages, supportedLocales: supported);
    preferences.register('language', prefs.Value(string: selected.selectedLocale), flags: 0x84);
    final effective = preferences.get('language').entries['language']!.string;
    final context = NativeCefContext.fromLocale(selectedLocale: effective, appleLanguages: languages);
    // Validate the complete language field before the first possible sender.
    context.acceptLanguageHeader;
    final cache = await openStreamingCacheDirectory(streamingDirectory, cancellationToken: cancellationToken);
    try {
      cancellationToken?.throwIfCancelled();
      final runtime = NativeDesktopRuntime._(deviceId: deviceId, preferences: preferences,
        streamingDirectory: streamingDirectory, context: context, streamingCache: cache,
        identity: MacOSPlatformIdentity.readCurrent(), facts: MacOSPlatformFacts.readCurrent(),
        apSystemInfo: NativeApSystemInfo.readCurrent(), cancellationToken: cancellationToken);
      runtime._warmPlaybackCpu();
      runtime._signingIn = runtime._restoreSession().whenComplete(() => runtime._signingIn = null);
      return runtime;
    } catch (_) {
      await retireStreamingCacheDirectory(cache);
      rethrow;
    }
  }

  final String deviceId;
  final PrefsStore preferences;
  final Directory streamingDirectory;
  // Nullable so an existing hot-reloaded runtime keeps its live legacy paths.
  final StreamingCacheDirectory? _streamingCache;
  Directory get _streamingWorkingDirectory => _streamingCache?.directory ?? streamingDirectory;
  final NativeCefContext context;
  final MacOSPlatformIdentity identity;
  final MacOSPlatformFacts facts;
  final NativeApSystemInfo apSystemInfo;
  final CancellationToken? _ownerCancellation;
  final _status = ValueNotifier<String>('Sign in to listen');
  final _requests = <NativeCefHttp2Transport>{};
  CancellationToken? _sessionCancellation;
  CancellationToken get _sessionToken => _sessionCancellation ??=
    MergedCancellationToken([?_ownerCancellation]);
  NativeCefHttp2Pool? _http2;
  NativeCefHttp2Pool? _rendererHttp2;
  final _http3Requests = <NativeCefHttp3Transport>{};
  QuicheHttp3Client? _http3;
  QuicheHttp3Client? _rendererHttp3;
  late final _httpClock = Stopwatch()..start();
  late final _httpProtocols = NativeHttpProtocolPolicy(nowMicroseconds: _now,
    monotonicMicroseconds: () => _httpClock.elapsedMicroseconds);
  NativePusherConnection? _pushConnection;
  Future<NativePusherConnection>? _pushOpening;
  NativeConnectStatePublisher? _connectStatePublisher;
  Object? _connectReportingError;
  final _rendererRequests = <NativeRendererHttp2Transport>{};
  final _rendererHttp3Requests = <NativeRendererHttp3Transport>{};
  final _rendererClock = Stopwatch()..start();
  NativeRendererCors? _rendererCors;
  final _cdnRequests = <NativeCefHttpTransport>{};
  NativeCefHttpConnectionPool? _cdnPool;
  final _signedMediaUrls = <String>{};
  final _keys = <SpotifyAudioKeyRequest>{};
  NativePlayPlayMusicKeyClientState? _musicKeyClientState;
  final _trackMetadata = <String, Map<String, Object?>>{};
  final _trackDescriptions = <String, SpotifyEntityMetadata>{};
  final _trackDescriptionExpiry = <String, int>{};
  Map<String, SharedTask<Map<String, SpotifyEntityMetadata>>>? _trackDescriptionTasks;
  Map<String, SharedTask<Map<String, SpotifyEntityMetadata>>> get _trackDescriptionJobs =>
    _trackDescriptionTasks ??= {};
  final _serverArtwork = <String, List<Map<String, Object?>>>{};
  final _serverArtworkById = <String, List<Map<String, Object?>>>{};
  final _playlistPresentations = <String, Map<String, Object?>>{};
  final _artworkChanges = ChangeNotifier();
  Map<String, SharedTask<void>>? _playlistArtworkTasks;
  Map<String, SharedTask<void>> get _playlistArtworkJobs => _playlistArtworkTasks ??= {};
  final _playlistArtworkRetryAfter = <String, int>{};
  final _playlistArtworkLanes = [Future<void>.value(), Future<void>.value()];
  int _nextPlaylistArtworkLane = 0;
  final _clock = Stopwatch()..start();
  NativeAccountsCallbackServer? _callback;
  NativeTokenProvider? _tokens;
  NativeClientTokenProvider? _clientTokens;
  NativeHttpCredentials? _credentials;
  NativeLegacyStoredCredentials? _nativeStoredCredentials;
  NativeOAuthTokenResponse? _grant;
  DpopProofGenerator? _proofs;
  NativeOAuthRefreshState? _refreshState;
  Future<void> _vaultWrites = Future<void>.value();
  SpotifyApSession? _ap;
  SpotifyApSession? _connectingAp;
  StreamSubscription<Object>? _connectingApPackets;
  Future<void>? _reconnectingAp;
  bool _apSessionInvalidated = false;
  final _nativeOrigins = <String>{};
  NativeApPacketPolicy? _apPolicy;
  StreamSubscription<Object>? _apPackets;
  List<NativeApResolverEndpoint> _endpoints = const [];
  PlaybackEngine? _engine;
  StreamSubscription<PlayerJson>? _canaryEvents;
  NativePlayPlayCanary? _canary;
  int? _lastCanaryAudioLoad;
  Future<void>? _signingIn;
  int _epoch = 0;
  bool _closed = false;
  SearchRepository? _search;
  HomeRepository? _home;
  EntityRepository? _entities;
  LibraryRepository? _library;
  SavedTracksRepository? _savedTracksRepository;
  final _collections = <String, NativeCollectionReadClient>{};
  LyricsRepository? _lyrics;
  String? _libraryImageUrlTemplate;
  NativeAudioFilesMetadata? _audioMetadata;
  final _audioFilesCache = <String, ({NativeAudioFilesMetadata files, int expiresAtUs})>{};
  NativeImageClient? _imageClient;
  Future<NativeImageProjectionMap?>? _imageProjectionMap;
  Future<ArtworkDiskCache?>? _artworkDiskCache;
  Future<SpotifyMediaCache?>? _mediaCache;
  PreparedAudioCache? _preparedAudio;
  SessionAudioKeyCache? _audioKeys;
  Object? _lastMusicLicenseFailure;
  // Bounded session diagnostics: never retain file IDs, headers or key bytes.
  int _musicLicenseAttempts = 0;
  final _musicLicenseResponses = <int, int>{};
  final _musicLicensePurposeResponses = <String, Map<int, int>>{};
  final _images = <String, SharedTask<Uint8List>>{};
  final _sourceStartupTimings = <Map<String, Object?>>[];

  @override ValueListenable<String> get status => _status;
  @override bool get ready => !_closed && !_apSessionInvalidated && _grant != null &&
    _credentials != null && _apPolicy?.isAuthenticationReady == true &&
    _ap?.welcome?.canonicalUsername == _grant?.username;
  @override String? get username => _grant?.username;
  @override SearchRepository? get searchRepository => ready ? _search ??= _makeSearch() : null;
  @override HomeRepository? get homeRepository => ready ? _home ??= _makeHome() : null;
  @override EntityRepository? get entityRepository => ready ? _entities ??= _makeEntities() : null;
  LyricsRepository? get lyricsRepository => ready ? _lyrics ??= _makeLyrics() : null;
  @override SavedTracksRepository? get savedTracksRepository => ready
    ? _savedTracksRepository ??= _makeSavedTracks() : null;
  @override LibraryRepository? get libraryRepository {
    if (!ready) return null;
    final template = _imageUrlTemplate;
    if (_library == null || _libraryImageUrlTemplate != template) {
      _libraryImageUrlTemplate = template;
      _library = _makeLibrary();
    }
    return _library;
  }
  Listenable get artworkChanges => _artworkChanges;
  int _now() => DateTime.now().microsecondsSinceEpoch;

  void _rememberArtwork(String uri, List<Map<String, Object?>> images) {
    if (!uri.startsWith('spotify:') || images.isEmpty) return;
    final previous = _serverArtwork[uri];
    if (previous != null && previous.length == images.length &&
        previous.indexed.every((entry) => mapEquals(entry.$2, images[entry.$1]))) return;
    final exact = List<Map<String, Object?>>.unmodifiable(images.map(Map<String, Object?>.unmodifiable));
    _serverArtwork.remove(uri);
    _serverArtwork[uri] = exact;
    if (_serverArtwork.length > 512) {
      final evicted = _serverArtwork.keys.first;
      _serverArtwork.remove(evicted);
    }
    for (final image in exact) {
      final url = image['url'];
      if (url is! String) continue;
      final id = RegExp(r'^https://(?:i\.scdn\.co|image-cdn-(?:ak|fa)\.spotifycdn\.com)/image/([0-9a-f]{40})$')
        .firstMatch(url)?.group(1);
      if (id == null) continue;
      final sources = _serverArtworkById.putIfAbsent(id, () => []);
      if (!sources.any((entry) => entry['url'] == url)) sources.add(image);
    }
    while (_serverArtworkById.length > 1024) _serverArtworkById.remove(_serverArtworkById.keys.first);
    _artworkChanges.notifyListeners();
  }

  /// Reuse actual server-provided choices for this entity, or an exact matching
  /// image ID. Every returned URL remains unchanged; no CDN host is fabricated.
  List<Map<String, Object?>> artworkSources(String uri, List<Map<String, Object?>> supplied) {
    final known = _serverArtwork.remove(uri);
    if (known != null) _serverArtwork[uri] = known;
    // A supplied Home cover or playlist banner is presentation-specific. An
    // entity-URI cache is only a fallback, never a replacement for that choice.
    final candidates = <Map<String, Object?>>[...supplied];
    for (final image in supplied) {
      final url = image['url'];
      final id = url is String ? RegExp(r'/image/([0-9a-f]{40})$').firstMatch(url)?.group(1) : null;
      if (id != null) candidates.addAll(_serverArtworkById[id] ?? const []);
    }
    if (candidates.isEmpty) candidates.addAll(known ?? const []);
    final seen = <String>{};
    return [for (final image in candidates)
      if (image['url'] case final String url)
        if (seen.add(url)) image];
  }
  /// Missing playlist pictures are often native mosaics, not failed downloads.
  /// Reuse the verified online playlist/TrackV4 readers and original rank0
  /// selector. At most two cover hydrations run concurrently per session.
  Future<void> ensurePlaylistArtwork(String uri, List<Map<String, Object?>> supplied,
      {CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (!ready || supplied.isNotEmpty || _serverArtwork[uri]?.isNotEmpty == true ||
        !RegExp(r'^spotify:playlist:[0-9A-Za-z]{22}$').hasMatch(uri)) return Future.value();
    if ((_playlistArtworkRetryAfter[uri] ?? 0) > _clock.elapsedMicroseconds) return Future.value();
    final existing = _playlistArtworkJobs[uri];
    if (existing != null && !existing.token.isCancelled) return existing.wait(cancellationToken);
    final epoch = _epoch;
    final sessionToken = _sessionToken;
    final lane = _nextPlaylistArtworkLane++ % _playlistArtworkLanes.length;
    final previous = _playlistArtworkLanes[lane];
    late final SharedTask<void> pending;
    pending = SharedTask((cancellation) async {
      final token = sessionToken.merge(cancellation);
      try {
        await previous.asCancellable(token);
        token.throwIfCancelled(); _check(epoch);
        await _loadPlaylistArtwork(uri, epoch, token);
      } on CancelledException { rethrow; }
      catch (error) {
        token.throwIfCancelled();
        if (!_closed && epoch == _epoch) debugPrint('Playlist cover could not be loaded: $error');
      } finally {
        if (identical(_playlistArtworkJobs[uri], pending)) _playlistArtworkJobs.remove(uri);
        if (!token.isCancelled && !_closed && epoch == _epoch) {
          if (_serverArtwork[uri]?.isNotEmpty == true) {
            _playlistArtworkRetryAfter.remove(uri);
          } else {
            // A failed/incomplete scan cannot permanently hide a playlist cover.
            // Retry only on a later visible rebuild, with no background timer.
            _playlistArtworkRetryAfter[uri] = _clock.elapsedMicroseconds + Duration.microsecondsPerMinute;
            while (_playlistArtworkRetryAfter.length > 512) {
              _playlistArtworkRetryAfter.remove(_playlistArtworkRetryAfter.keys.first);
            }
          }
        }
      }
    });
    // A cancelled queued reader does not let the following reader overtake
    // the lane's still-running predecessor.
    _playlistArtworkLanes[lane] = previous.then((_) => pending.completion)
      .then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _playlistArtworkJobs[uri] = pending;
    return pending.wait(cancellationToken);
  }

  Future<void> _loadPlaylistArtwork(String uri, int epoch, CancellationToken token) async {
    token.throwIfCancelled();
    final snapshot = await _readPlaylist(uri, cancellationToken: token);
    token.throwIfCancelled();
    _check(epoch);
    final supplied = nativePlaylistImages(snapshot.attributes, imageUrlTemplate: _imageUrlTemplate);
    if (supplied.isNotEmpty) { _rememberArtwork(uri, supplied); return; }
    final items = snapshot.contents.items;
    final scan = items.take(64).toList(growable: false);
    final selected = <List<int>>[], identities = <String>{};
    for (var offset = 0; offset < scan.length && selected.length < 4; offset += 8) {
      final uris = scan.skip(offset).take(8).map((item) => item.uri)
        .where((value) => RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(value)).toList(growable: false);
      token.throwIfCancelled();
      final descriptions = await _fetchNativeTrackDescriptions(uris, cancellationToken: token);
      token.throwIfCancelled();
      _check(epoch);
      for (final description in descriptions) {
        final track = description.track;
        if (description.problem != null || track == null || !track.hasAlbum()) continue;
        // This ordinary online TrackV4 model is populated in a ready session.
        // Original101ce54bc gives that model class0 before restriction checks.
        // No alternative/trait provider or deprecated cover is fabricated.
        final id = nativePlaylistMosaicTrackRankZeroImageId(track,
          nativeTrackDataReady: ready, nativeTrackDataClass: 0, includeOtherClasses: false);
        if (id == null || !identities.add(base64Encode(id))) continue;
        selected.add(id);
        if (selected.length == 4) break;
      }
    }
    // Three early distinct covers do not prove that a later fourth is absent.
    // Single-cover fallback requires this whole source to have been read.
    final complete = snapshot.contents.pos == 0 && !snapshot.contents.truncated && scan.length == items.length;
    if (selected.length < 4 && !complete) return;
    final url = nativePlaylistMosaicImageUrl(selected, imageUrlTemplate: _imageUrlTemplate);
    if (url.isNotEmpty) _rememberArtwork(uri, [{'url': url}]);
  }

  @override Future<Uint8List> artwork(String rawUrl, {CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (_closed) return Future.error(StateError('Spotify session is closed'));
    final existing = _images.remove(rawUrl);
    if (existing != null && !existing.token.isCancelled) {
      _images[rawUrl] = existing; return existing.wait(cancellationToken);
    }
    late final SharedTask<Uint8List> pending;
    pending = SharedTask((token) => _loadArtwork(rawUrl, token).onError((Object error, StackTrace stack) {
      if (identical(_images[rawUrl], pending)) _images.remove(rawUrl);
      Error.throwWithStackTrace(error, stack);
    }));
    _images[rawUrl] = pending;
    if (_images.length > 128) _images.remove(_images.keys.first);
    return pending.wait(cancellationToken);
  }

  Future<Uint8List> _loadArtwork(String rawUrl, CancellationToken cancellationToken) async {
    final token = _sessionToken.merge(cancellationToken);
    token.throwIfCancelled();
    final cache = await (_artworkDiskCache ??= _openArtworkCache());
    final cached = await cache?.read(rawUrl);
    token.throwIfCancelled();
    if (cached != null) return cached;
    final client = _imageClient ??= NativeImageClient(acceptLanguage: context.acceptLanguageHeader,
      onResponse: (url, bytes, headers) async { await cache?.storeResponse(url, bytes, headers); });
    final urls = await _artworkUrls(rawUrl).asCancellable(token);
    final unavailableHosts = <String>{};
    Object? failure;
    StackTrace? failureStack;
    for (final url in urls) {
      token.throwIfCancelled();
      final cached = await cache?.read(url);
      token.throwIfCancelled();
      if (cached != null) return cached;
      final host = Uri.parse(url).host;
      if (unavailableHosts.contains(host)) continue;
      try { return await client.load(url, cancellationToken: token); }
      on CancelledException { rethrow; }
      catch (error, stack) {
        token.throwIfCancelled();
        failure = error; failureStack = stack;
        if (error is SocketException || error is HandshakeException || error is TimeoutException) {
          unavailableHosts.add(host);
        }
      }
    }
    Error.throwWithStackTrace(failure ?? const HttpException('No public artwork source was available'),
      failureStack ?? StackTrace.current);
  }

  static const _imageResolveFeatures = NativeImageResolveConfiguration(
    enableProjectionMapLoading: true, enableImageResolve: true,
    enableOnlineImageResolve: true, enableOnlineSizeImageResolve: true);

  Future<List<String>> _artworkUrls(String rawUrl) async {
    final match = RegExp(r'^https://(?:i\.scdn\.co|image-cdn-(?:ak|fa)\.spotifycdn\.com)/image/([0-9a-f]{40})$')
      .firstMatch(rawUrl);
    if (match == null || !ready) return [rawUrl];
    final map = await (_imageProjectionMap ??= _loadImageProjectionMap());
    if (map == null) return [rawUrl];
    final id = match[1]!;
    // The renderer can already have chosen its WebP size variant. The native
    // map need not contain that projection ID: carry the independently
    // extracted renderer dimensions into its original size-based selector.
    final projections = nativeRendererImageProjections[id.substring(0, 8)];
    final projection = id.substring(8, 16);
    final dimensions = projections?['webp']?[projection] ?? projections?['defaultGroup']?[projection];
    final resolved = map.project(imageId20: [for (var index = 0; index < id.length; index += 2)
      int.parse(id.substring(index, index + 2), radix: 16)],
      configuration: _imageResolveFeatures, nativePreference: false,
      width: dimensions?.first, height: dimensions == null ? null : dimensions.elementAtOrNull(1) ?? dimensions.first);
    if (resolved == null) return [rawUrl];
    return {resolved.preferredUrl, ...resolved.urls, rawUrl}.where(nativeImagePublicUrlAllowed).toList();
  }

  Future<NativeImageProjectionMap?> _loadImageProjectionMap() async {
    final epoch = _epoch;
    try {
      final request = NativeImageProjectionMapRequestPlan.forEnabledLoading(
        template: RequestEnvelope(method: 'GET', url: _nativeServerOrigin(),
          headers: _nativeApplicationHeaders, responseType: 'bytes'), configuration: _imageResolveFeatures).request;
      final response = await _sendNativeServer(request, epoch);
      _check(epoch);
      if (response.statusCode != 200) return null;
      return NativeImageProjectionMap.fromResponseBytes(response.bodyBytes);
    } catch (_) {
      // One setup read per session, shared by every visible image. A failed
      // optional map never turns into per-thumbnail setup retries or polling.
      return null;
    }
  }

  Future<ArtworkDiskCache?> _openArtworkCache() async {
    try { return await ArtworkDiskCache.open(Directory('${streamingDirectory.parent.path}/artwork')); }
    on FileSystemException { return null; }
  }

  Future<SpotifyMediaCache?> _openMediaCache() async {
    final token = _sessionToken;
    try { return await SpotifyMediaCache.open(Directory('${_streamingWorkingDirectory.path}/buffers'),
      cancellationToken: token); }
    on FileSystemException { token.throwIfCancelled(); return null; }
  }
  NativeHttpDefaults get _defaults => NativeHttpDefaults(userAgent: identity.nativeUserAgent);

  Map<String, String> get _nativeApplicationHeaders => {
    'Accept-Language': context.selectedLocale,
    'app-platform': DesktopIdentity.appPlatform,
    'spotify-app-version': '${DesktopIdentity.numericVersion}',
    'time-zone': readMacOSIanaTimeZone(),
    'User-Agent': 'Spotify/${DesktopIdentity.numericVersion} ${DesktopIdentity.appPlatform}/${apSystemInfo.systemInformationString}',
  };

  NativeCefHttp2Transport _transport(bool Function(RequestEnvelope) admit) =>
    NativeCefHttp2Transport(defaults: _defaults, options: NativeCefOptions(adapterOption80: 0),
      adapterUserAgent: identity.nativeUserAgent, context: context,
      pool: _http2 ??= NativeCefHttp2Pool(), admitRemoteRequest: admit);

  Future<bool> _useNativeHttp3(RequestEnvelope request, bool Function(RequestEnvelope) admit,
      {CancellationToken? cancellationToken}) async {
    final target = Uri.parse(request.url);
    final raw = '${target.path}${target.hasQuery ? '?${target.query}' : ''}';
    final verified = request.method == 'POST' &&
      (RegExp(r'^/playplay/v1/key/[0-9a-f]{40}$').hasMatch(raw) ||
        raw == '/extended-metadata/v0/extended-metadata') ||
      request.method == 'PUT' && raw == '/connect-state/v1/devices/$deviceId' ||
      request.method == 'GET' &&
        (RegExp(r'^/storage-resolve/v2/files/audio/interactive/1/[0-9a-f]{40}\?product=0$').hasMatch(raw) ||
          RegExp(r'^/playlist/v2/playlist/[0-9A-Za-z]{22}$').hasMatch(raw));
    if (_httpProtocols.select(request, http3FieldsVerified: verified) != NativeHttpProtocol.http3) return false;
    if (target.scheme != 'https' || target.userInfo.isNotEmpty || target.hasFragment || !admit(request)) {
      throw StateError('Native endpoint is not admitted. No request was sent.');
    }
    final origin = Uri(scheme: target.scheme, host: target.host, port: target.port);
    final h3 = _http3Client, h2 = _http2 ??= NativeCefHttp2Pool();
    return await _httpProtocols.selectReady(request, http3FieldsVerified: verified, connectionContext: h3,
      http2Available: () => h2.hasAvailableConnection(origin), http3Available: () => h3.isOriginReady(origin),
      smoothedRttMicroseconds: () => h3.smoothedRttMicroseconds(origin),
      prepareHttp2: () => h2.prepareOrigin(origin,
        Duration(milliseconds: request.nativeTimeoutMilliseconds ?? 30000)),
      prepareHttp3: () => h3.prepareOrigin(origin), cancellationToken: cancellationToken) == NativeHttpProtocol.http3;
  }

  QuicheHttp3Client get _http3Client => _http3 ??= QuicheHttp3Client.bundled(trustedCertificatesPath: '/etc/ssl/cert.pem',
      admitRemoteOrigin: (origin) {
        if (_closed || !ready || origin.scheme != 'https') return false;
        return {_nativeServerOrigin(), ..._nativeOrigins}.any((value) {
          final candidate = Uri.parse(value);
          return candidate.scheme == origin.scheme && candidate.host == origin.host && candidate.port == origin.port;
        });
      });

  QuicheHttp3Client get _rendererClient3 => _rendererHttp3 ??= QuicheHttp3Client.bundled(
    trustedCertificatesPath: '/etc/ssl/cert.pem', admitRemoteOrigin: (origin) =>
      !_closed && ready && origin.scheme == 'https' &&
      origin.host == 'api-partner.spotify.com' && origin.port == 443);

  NativeCefHttp3Transport _transport3(bool Function(RequestEnvelope) admit) {
    return NativeCefHttp3Transport(defaults: _defaults, options: NativeCefOptions(adapterOption80: 0),
      adapterUserAgent: identity.nativeUserAgent, context: context, client: _http3Client, admitRemoteRequest: admit);
  }

  Future<NativePusherConnection> _ensureNativePusher() {
    final existing = _pushConnection;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    if (_pushOpening != null) return _pushOpening!;
    final epoch = _epoch;
    final cancellation = _sessionToken;
    late final Future<NativePusherConnection> opening;
    opening = (() async {
      var endpoint = _endpoints.where((entry) => entry.type == 1 && entry.host.isNotEmpty).firstOrNull;
      if (endpoint == null) {
        // A session restored before push reporting was enabled can lack this
        // endpoint. Resolve only the missing family, without restarting AP or
        // replacing the selected HTTP token provider.
        final plan = NativeApResolver(profile: NativeApResolverProfile.fromNativeIdentity(
          versionValue: DesktopIdentity.numericVersion, systemInfo: apSystemInfo,
          endpointTypes: const [1]), nowMicroseconds: _now,
          template: RequestEnvelope(method: 'GET', url: '', headers: const {}, authorize: false)).plan();
        final response = await _sendOwned(plan.request, (request) => request.method == 'GET' &&
          request.url.startsWith('https://apresolve.spotify.com/v2?')).response;
        _check(epoch);
        final endpoints = decodeNativeApResolverResponse(status: response.statusCode, body: response.bodyBytes);
        endpoint = endpoints.where((entry) => entry.type == 1 && entry.host.isNotEmpty).firstOrNull;
        if (endpoint == null) throw StateError('Spotify did not supply a push endpoint');
        _endpoints = [..._endpoints.where((entry) => entry.type != 1), ...endpoints.where((entry) => entry.type == 1)];
      }
      final connection = await _openNativePusher(endpoint, cancellationToken: cancellation);
      try { _check(epoch); }
      catch (_) { await connection.close(); rethrow; }
      return _pushConnection = connection;
    })().whenComplete(() { if (identical(_pushOpening, opening)) _pushOpening = null; });
    return _pushOpening = opening;
  }

  Future<NativePusherConnection> _openNativePusher(NativeApResolverEndpoint endpoint,
      {CancellationToken? cancellationToken}) async {
    final epoch = _epoch;
    final access = await _sessionAccessToken();
    _check(epoch);
    if (endpoint.type != 1 || endpoint.host.isEmpty) {
      throw StateError('Spotify has not supplied a push endpoint');
    }
    final plan = NativePusherRequestPlan(hostname: 'wss://${endpoint.host}:${endpoint.port}',
      accessToken: access.accessToken, clientVersion: DesktopIdentity.fullVersion,
      osMajor: facts.majorVersion, osMinor: facts.minorVersion, osPatch: facts.patchVersion);
    final connection = await NativePusherConnection.open(plan: plan,
      admitRemoteUrl: (url) => url.scheme == 'wss' && url.host == endpoint.host &&
        url.port == endpoint.port && url.path.isEmpty && !url.hasQuery,
      cancellationToken: cancellationToken);
    try { _check(epoch); return connection; }
    catch (_) { await connection.close(); rethrow; }
  }

  /// A fresh transport owns precisely this request and its actual abort. No
  /// redirects, speculative endpoints, or generic application retries are added.
  NativeOAuthRefreshOwnedSend _sendOwned(RequestEnvelope request,
      bool Function(RequestEnvelope) admit, {bool Function(http.Response)? handleResponse}) {
    if (_closed) throw StateError('Spotify session is closed');
    final epoch = _epoch;
    final cancellation = CancellationToken();
    final token = MergedCancellationToken([_sessionToken, cancellation,
      if (request.cancellationToken != null) request.cancellationToken!]);
    token.throwIfCancelled();
    void Function()? abortTransport;
    final cleanup = CancellationRegistration(token, onCancel: (_) => abortTransport?.call());
    Future<http.Response> fetch() async {
      final h3 = await _useNativeHttp3(request, admit, cancellationToken: token);
      _check(epoch);
      token.throwIfCancelled();
      if (h3) {
        final transport = _transport3(admit);
        abortTransport = transport.close;
        _http3Requests.add(transport);
        try {
          final streamed = await transport.sendStream(request);
          if (epoch == _epoch) _httpProtocols.observeResponse(request.url, streamed.headers);
          return await http.Response.fromStream(streamed);
        } finally { _http3Requests.remove(transport); transport.close(); }
      }
      final transport = _transport(admit);
      abortTransport = transport.close;
      _requests.add(transport);
      try {
        final streamed = await transport.sendStream(request);
        if (epoch == _epoch) _httpProtocols.observeResponse(request.url, streamed.headers);
        return await http.Response.fromStream(streamed);
      } finally { _requests.remove(transport); transport.close(); }
    }
    Future<http.Response> response() async {
      try {
        http.Response? value = await fetch();
        _check(epoch);
        token.throwIfCancelled();
        if (handleResponse != null && !handleResponse(value)) {
          // Original nonmatching client-token-error branches invoke neither
          // response continuation. Retain the request's real cancellation;
          // do not leak the response body or add a refresh/retry/deadline.
          value = null;
          return await CancellableCompleter<http.Response>(token).future;
        }
        return value;
      } finally {
        cleanup.dispose();
        abortTransport = null;
      }
    }
    return NativeOAuthRefreshOwnedSend(response: response().asCancellable(token),
      abort: () => cancellation.cancel(http.RequestAbortedException()));
  }

  bool _accountsRoute(RequestEnvelope request) => request.method == 'POST' &&
    request.url == 'https://accounts.spotify.com/api/token' &&
    request.headers['Content-Type'] == 'application/x-www-form-urlencoded' &&
    request.headers.keys.every((key) => const {'content-type', 'dpop'}.contains(key.toLowerCase()));

  Future<http.Response> _accountsSend(RequestEnvelope request) async {
    final response = await _sendOwned(request, _accountsRoute).response;
    if (response.statusCode == 200 && _grant != null) {
      // Refresh/provider continuations publish in microtasks. Persist their
      // resulting actual token/nonce on the next event turn, never log bytes.
      final cancellation = _sessionToken;
      Future<void> save() async {
        try {
          await CancellableFuture.delayed<void>(Duration.zero, cancellation);
          await _persistSession(cancellationToken: cancellation);
        } catch (error) {
          if (!cancellation.isCancelled && !_closed) _status.value = 'Session could not be saved: $error';
        }
      }
      unawaited(save());
    }
    return response;
  }

  DesktopSessionVault get _sessionVault => DesktopSessionVault(
    directory: Directory('${streamingDirectory.parent.path}/session'));

  Future<void> _persistSession({CancellationToken? cancellationToken}) {
    final grant = _grant, proofs = _proofs, refresh = _refreshState;
    if (grant == null || proofs == null || refresh == null ||
        proofs.key is! P256DpopKey) return Future<void>.value();
    final cancellation = MergedCancellationToken([_sessionToken, ?cancellationToken]);
    cancellation.throwIfCancelled();
    final token = _tokens?.peek() ?? NativeAccessToken(accessToken: grant.accessToken,
      tokenType: grant.tokenType, expiresAtMicroseconds: grant.expiresAtMicroseconds);
    // Also upgrades an already authenticated app-owned session after hot reload;
    // no original profile/cache or foreign account material is read.
    if (_nativeStoredCredentials == null) _cacheNativeWelcomeCredential();
    final keyBytes = (proofs.key as P256DpopKey).exportPrivateBytes();
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'version': 1, 'deviceId': deviceId, 'username': grant.username,
      'accessToken': token.accessToken, 'tokenType': token.tokenType,
      'expiresAtMicroseconds': token.expiresAtMicroseconds,
      'refreshToken': refresh.refreshToken, 'dpopNonce': refresh.dpopNonce,
      'scope': grant.scope, 'dpopPrivateKey': base64Encode(keyBytes),
      if (_nativeStoredCredentials case final stored?) 'nativeStoredCredential': {
        'username': stored.username, 'deviceId': stored.deviceId,
        'encodedBlob': latin1.decode(stored.encodedBlob),
      },
    })));
    keyBytes.fillRange(0, keyBytes.length, 0);
    Future<void> write() async {
      try {
        cancellation.throwIfCancelled();
        await _sessionVault.write(bytes, cancellationToken: cancellation);
      }
      finally { bytes.fillRange(0, bytes.length, 0); }
    }
    return _vaultWrites = _vaultWrites.then((_) => write(), onError: (Object _, StackTrace __) => write());
  }

  void _cacheNativeWelcomeCredential() {
    final welcome = _ap?.welcome;
    if (welcome == null || _ap?.state != SpotifyApSessionState.ready ||
        welcome.canonicalUsername != username || welcome.reusableAuthCredentialsType != 1 ||
        welcome.reusableAuthCredentials.isEmpty) return;
    _nativeStoredCredentials = NativeLegacyAuthCodec().encode(username: welcome.canonicalUsername,
      data: welcome.reusableAuthCredentials, deviceId: deviceId,
      authenticationType: welcome.reusableAuthCredentialsType);
  }

  Future<void> _restoreSession() async {
    final epoch = _epoch;
    final cancellation = _sessionToken;
    try {
      final bytes = await _sessionVault.read(cancellationToken: cancellation);
      if (bytes == null) { cancellation.throwIfCancelled(); _check(epoch); return; }
      late final Map saved;
      try {
        cancellation.throwIfCancelled(); _check(epoch);
        saved = jsonDecode(utf8.decode(bytes)) as Map;
      }
      finally { bytes.fillRange(0, bytes.length, 0); }
      if (saved['version'] != 1 || saved['deviceId'] != deviceId) return;
      final keyBytes = base64Decode(saved['dpopPrivateKey'] as String);
      late final P256DpopKey key;
      try { key = P256DpopKey.fromPrivateBytes(keyBytes); }
      finally { keyBytes.fillRange(0, keyBytes.length, 0); }
      final grant = NativeOAuthTokenResponse(accessToken: saved['accessToken'] as String,
        tokenType: saved['tokenType'] as String, expiresIn: 0,
        expiresAtMicroseconds: saved['expiresAtMicroseconds'] as int,
        refreshToken: saved['refreshToken'] as String, scope: saved['scope'] as String,
        username: saved['username'] as String, dpopNonce: saved['dpopNonce'] as String);
      final stored = saved['nativeStoredCredential'];
      if (stored is Map && stored['username'] == grant.username && stored['deviceId'] == deviceId &&
          stored['encodedBlob'] is String) {
        final encoded = NativeLegacyStoredCredentials(username: grant.username, deviceId: deviceId,
          encodedBlob: latin1.encode(stored['encodedBlob'] as String));
        final credential = NativeLegacyAuthCodec().decode(encoded);
        if (credential?.authenticationType == 1 && credential!.data.isNotEmpty) {
          _nativeStoredCredentials = encoded;
        }
      }
      _grant = grant;
      _status.value = 'Reconnecting to Spotify…';
      // The stored Accounts owner uses original101635ea4 without a token seed.
      // AP reusable credentials restore the socket, independently of the
      // Accounts provider retained by this saved browser-authenticated session.
      _installCredentials(grant, DpopProofGenerator(key: key), seedAccessToken: false);
      await _connectAp(epoch, grant);
      _check(epoch);
      _status.value = 'Connected as ${grant.username}';
      await _persistSession();
    } catch (error) {
      if (cancellation.isCancelled) return;
      if (!_closed && epoch == _epoch) {
        await _retire();
        if (!_closed && _ownerCancellation?.isCancelled != true) _status.value = 'Sign in to reconnect: $error';
      }
    }
  }

  Future<NativeAccessToken> _accessToken({CancellationToken? cancellationToken}) async {
    final token = MergedCancellationToken([_sessionToken, ?cancellationToken]);
    token.throwIfCancelled();
    final provider = _tokens;
    if (provider == null) throw StateError('Sign in to Spotify');
    final cached = provider.peek();
    if (cached != null) return cached;
    final result = Completer<NativeTokenResult>();
    final cancel = provider.request(result.complete);
    try {
      final value = await result.future.asCancellable(token);
      if (value is NativeTokenSuccess) return value.token;
      throw StateError('Spotify access token is unavailable');
    } finally { cancel(); }
  }

  // Original AccessTokenClient context+88 and native HTTP context+98 both
  // resolve owner+38. This runtime installs an Accounts API after browser
  // sign-in and restores its Accounts grant. An AP Welcome credential alone
  // does not establish the original early Login5 cache/result/provider path.
  Future<NativeAccessToken> _sessionAccessToken({CancellationToken? cancellationToken}) =>
    _accessToken(cancellationToken: cancellationToken);

  void _invalidateSessionAccessToken() { _tokens?.invalidate(); }

  Future<String> _clientToken({CancellationToken? cancellationToken}) async {
    final token = MergedCancellationToken([_sessionToken, ?cancellationToken]);
    token.throwIfCancelled();
    final provider = _clientTokens;
    if (provider == null) throw StateError('Sign in to Spotify');
    final cached = provider.peek();
    if (cached != null) return cached.token;
    final result = Completer<NativeClientTokenResult>();
    final cancel = provider.acquire(result.complete);
    try {
      final value = await result.future.asCancellable(token);
      if (value is NativeClientTokenSuccess) return value.token.token;
      throw StateError(value is NativeClientTokenFailure ? value.message : 'Spotify client token is unavailable');
    } finally { cancel(); }
  }

  Future<http.StreamedResponse> _sendRendererPrepared(NativeRendererHttpRequestPlan plan, {
      required NativeRendererSearchProfile profile, required int epoch, int? nativeTimeoutMilliseconds,
      CancellationToken? cancellationToken}) async {
      _check(epoch);
      final token = MergedCancellationToken([_sessionToken, ?cancellationToken]);
      token.throwIfCancelled();
      bool admit(RequestEnvelope request) {
        if (const {'POST', 'OPTIONS'}.contains(request.method) &&
            request.url == 'https://api-partner.spotify.com/pathfinder/v2/query') return true;
        final target = Uri.parse(request.url);
        return const {'GET', 'OPTIONS'}.contains(request.method) && target.scheme == 'https' &&
          target.host == 'spclient.wg.spotify.com' && !target.hasPort && target.userInfo.isEmpty &&
          (RegExp(r'^/metadata/4/track/[0-9a-f]{32}$').hasMatch(target.path) ||
           RegExp(r'^/color-lyrics/v2/track/[0-9A-Za-z]{22}/image/.+$').hasMatch(target.path));
      }
      final request = RequestEnvelope(method: plan.method, url: plan.url,
        headers: plan.headers, body: plan.body, authorize: false, responseType: 'bytes',
        nativeTimeoutMilliseconds: nativeTimeoutMilliseconds, cancellationToken: token);
      if (!admit(request)) throw StateError('Renderer endpoint is not admitted. No request was sent.');
      var protocol = _httpProtocols.select(request, http3FieldsVerified: true);
      if (protocol == NativeHttpProtocol.http3) {
        final target = Uri.parse(plan.url);
        final origin = Uri(scheme: target.scheme, host: target.host, port: target.hasPort ? target.port : null);
        final client = _rendererClient3, pool = _rendererHttp2 ??= NativeCefHttp2Pool();
        protocol = await _httpProtocols.selectReady(request, http3FieldsVerified: true,
          connectionContext: client, http2Available: () => pool.hasAvailableConnection(origin),
          http3Available: () => client.isOriginReady(origin),
          smoothedRttMicroseconds: () => client.smoothedRttMicroseconds(origin),
          prepareHttp2: () => pool.prepareOrigin(origin,
            Duration(milliseconds: nativeTimeoutMilliseconds ?? 30000)),
          prepareHttp3: () => client.prepareOrigin(origin));
        _check(epoch);
      }
      final h3 = protocol == NativeHttpProtocol.http3
        ? NativeRendererHttp3Transport(profile: profile, clientToken: _clientToken,
            client: _rendererClient3, admitRemoteRequest: admit) : null;
      final h2 = h3 == null ? NativeRendererHttp2Transport(profile: profile,
        clientToken: _clientToken, admitRemoteRequest: admit,
        pool: _rendererHttp2 ??= NativeCefHttp2Pool()) : null;
      if (h3 != null) _rendererHttp3Requests.add(h3);
      if (h2 != null) _rendererRequests.add(h2);
      var released = false;
      void release() {
        if (released) return;
        released = true;
        if (h3 != null) { _rendererHttp3Requests.remove(h3); h3.close(); }
        if (h2 != null) { _rendererRequests.remove(h2); h2.close(); }
      }
      try {
        final streamed = await (h3?.sendPrepared(plan, nativeTimeoutMilliseconds: nativeTimeoutMilliseconds,
          cancellationToken: token) ?? h2!.sendPrepared(plan, nativeTimeoutMilliseconds: nativeTimeoutMilliseconds,
            cancellationToken: token));
        _check(epoch);
        _httpProtocols.observeResponse(plan.url, streamed.headers);
        Stream<List<int>> body() async* {
          try {
            await for (final chunk in streamed.stream) { _check(epoch); token.throwIfCancelled(); yield chunk; }
            _check(epoch);
          } finally { release(); }
        }
        return http.StreamedResponse(body(), streamed.statusCode, headers: streamed.headers,
          contentLength: streamed.contentLength, reasonPhrase: streamed.reasonPhrase);
      } catch (_) { release(); rethrow; }
  }

  ({PathfinderLoader loader, Future<void> Function({CancellationToken? cancellationToken}) prepare}) _pathfinder() {
    final epoch = _epoch;
    final builder = SpotifyRequestBuilder(locale: context.selectedLocale,
      globalHeaders: NativeRendererSearchProfile.globalHeaders);
    final loader = PathfinderLoader(builder, send: (request) async {
      _check(epoch);
      final profile = NativeRendererSearchProfile(locale: context.selectedLocale);
      final clientToken = await _clientToken(cancellationToken: request.envelope.cancellationToken);
      _check(epoch);
      final plan = profile.prepareSearch(request.envelope, clientToken: clientToken);
      final cors = _rendererCors ??= NativeRendererCors(nowMicroseconds: () => _rendererClock.elapsedMicroseconds);
      final response = await http.Response.fromStream(await cors.send(plan, profile: profile,
        cancellationToken: request.envelope.cancellationToken,
        sendPrepared: (prepared, token) => _sendRendererPrepared(prepared, profile: profile,
          epoch: epoch, nativeTimeoutMilliseconds: request.envelope.nativeTimeoutMilliseconds,
          cancellationToken: token)));
      _check(epoch);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpResponseError(message: 'Spotify returned ${response.statusCode}',
          url: request.envelope.url, method: request.envelope.method, status: response.statusCode);
      }
      return PathfinderResponse(body: jsonDecode(utf8.decode(response.bodyBytes)));
    });
    Future<void> prepare({CancellationToken? cancellationToken}) async {
      _check(epoch);
      final token = await _sessionAccessToken(cancellationToken: cancellationToken);
      _check(epoch);
      // Original renderer RequestBuilder uses the literal Bearer prefix;
      // the native HTTP decorator has its distinct token-type-aware policy.
      builder.accessToken = token.accessToken;
    }
    return (loader: loader, prepare: prepare);
  }

  LyricsRepository _makeLyrics() {
    final epoch = _epoch;
    final builder = SpotifyRequestBuilder(locale: context.selectedLocale, market: 'from_token',
      globalHeaders: NativeRendererSearchProfile.globalHeaders);
    return LyricsRepository(builder: builder, send: (envelope) async {
      _check(epoch);
      final token = await _sessionAccessToken(cancellationToken: envelope.cancellationToken);
      final clientToken = await _clientToken(cancellationToken: envelope.cancellationToken);
      _check(epoch);
      final authenticated = RequestEnvelope(method: envelope.method, url: envelope.url,
        headers: {...envelope.headers, 'Authorization': 'Bearer ${token.accessToken}'},
        cancellationToken: envelope.cancellationToken);
      final profile = NativeRendererSearchProfile(locale: context.selectedLocale);
      final plan = profile.prepareLyrics(authenticated, clientToken: clientToken);
      final cors = _rendererCors ??= NativeRendererCors(nowMicroseconds: () => _rendererClock.elapsedMicroseconds);
      final response = await http.Response.fromStream(await cors.send(plan, profile: profile,
        cancellationToken: envelope.cancellationToken,
        sendPrepared: (prepared, token) => _sendRendererPrepared(prepared, profile: profile,
          epoch: epoch, cancellationToken: token)));
      _check(epoch);
      return LyricsResponse(response.statusCode, response.statusCode >= 200 && response.statusCode < 300
        ? jsonDecode(utf8.decode(response.bodyBytes)) : null);
    });
  }

  SearchRepository _makeSearch() {
    final session = _pathfinder();
    return _AuthenticatedSearchRepository(PathfinderSearchRepository(session.loader), session.prepare, (page) {
      for (final item in page.items) {
        _rememberArtwork(item.uri, item.images);
        _trackMetadata[item.uri] = {'title': item.name,
          'artist': item.contributors.join(', '), if (item.durationMs != null) 'duration_ms': item.durationMs,
          if (item.images.firstOrNull?['url'] case final String image) 'image_url': image};
      }
    });
  }

  HomeRepository _makeHome() {
    final session = _pathfinder();
    return _AuthenticatedHomeRepository(PathfinderHomeRepository(session.loader,
      context: HomeRequestContext(timeZone: readMacOSIanaTimeZone())), session.prepare, (page) {
        for (final section in page.sections) {
          for (final item in section.items) {
            _rememberArtwork(item.uri, item.images);
            if (item.type != 'playlist') continue;
            final data = item.contentData;
            final attributes = {for (final entry in data['attributes'] as List? ?? const [])
              if (entry is Map && entry['key'] is String) entry['key'] as String: entry['value']};
            final owner = ((data['ownerV2'] as Map?)?['data'] as Map?) ?? const {};
            final imageItems = (data['images'] as Map?)?['items'] as List? ?? const [];
            _playlistPresentations.remove(item.uri);
            _playlistPresentations[item.uri] = {
              if (attributes['madeFor.displayed'] == '1' && attributes['madeFor.username'] is String)
                'madeForName': attributes['madeFor.username'],
              if (owner['uri'] is String) 'ownerUsername': (owner['uri'] as String).split(':').last,
              'ownerName': owner['name'],
              if (imageItems.isNotEmpty && imageItems.first is Map)
                'extractedColors': (imageItems.first as Map)['extractedColors'],
            };
            while (_playlistPresentations.length > 128) {
              _playlistPresentations.remove(_playlistPresentations.keys.first);
            }
          }
        }
      });
  }

  LibraryRepository _makeLibrary() {
    final epoch = _epoch;
    final rootlist = NativeRootlistLibraryRepository(NativeRootlistReadClient(
      baseUrl: _nativeServerOrigin(), username: username!,
      headers: NativePlaylistRequestHeaders(locale: context.selectedLocale,
        timeZone: readMacOSIanaTimeZone(), userAgent: _nativeApplicationHeaders['User-Agent']!),
      nativeHttpSend: (request) { _check(epoch); return _sendNativeServer(request, epoch); }),
      imageUrlTemplate: _imageUrlTemplate);
    return NativeLibraryRepository(rootlist: rootlist,
      collection: _collection('collection'), artists: _collection('artist'),
      recentContexts: NativeRecentContextsClient(baseUrl: _nativeServerOrigin(),
        inheritedHeaders: _nativeApplicationHeaders, nowMicroseconds: _now,
        send: (request) { _check(epoch); return _sendNativeServer(request, epoch); }),
      metadata: NativeLibraryMetadataClient(requests: SpotifyRequests(baseUrl: _nativeServerOrigin(),
        inheritedHeaders: _nativeApplicationHeaders, defaults: _defaults),
        country: latin1.decode(_apPolicy!.countryCode), catalogue: _ap!.productState['catalogue'] ?? '',
        imageUrlTemplate: _imageUrlTemplate, nowMicroseconds: () => _now(),
        send: (request) { _check(epoch); return _sendNativeServer(request, epoch); }));
  }

  NativeCollectionReadClient _collection(String collectionSet) => _collections.putIfAbsent(collectionSet, () {
    final epoch = _epoch;
    return NativeCollectionReadClient(baseUrl: _nativeServerOrigin(), username: username!,
      collectionSet: collectionSet, inheritedHeaders: _nativeApplicationHeaders,
      send: (request) async {
        _check(epoch);
        final response = await _sendNativeServer(request, epoch);
        _check(epoch);
        return response;
      });
  });

  SavedTracksRepository _makeSavedTracks() {
    final epoch = _epoch;
    final origin = _nativeServerOrigin();
    Future<http.Response> send(RequestEnvelope request) async {
      _check(epoch);
      final response = await _sendNativeServer(request, epoch);
      _check(epoch);
      return response;
    }
    // Original URI parser gives tracks kind4. Contains1005492dc selects
    // bucket0 for that kind;101b7a618 names that bucket "collection".
    final membership = _collection('collection');
    final dispatcher = EsperantoDispatcher();
    NativeSavedTrackService(baseUrl: origin, username: username!, headers: _nativeApplicationHeaders,
      membership: membership, readPlaylist: (uri, {cancellationToken}) {
        _check(epoch); return _readPlaylist(uri, cancellationToken: cancellationToken); },
      send: send, requestedLenses: const ['auto'], dsaMode: false, listPlayerEnabled: true)
      .register(dispatcher);
    // Installed renderer LibraryAPI defaults enable both Liked Songs platform
    // flags; its fixed playlist branch is independently executed in the oracle.
    return NativeSavedTracksRepository(dispatcher, likedSongsListPlatformEnabled: true,
      likedSongsUri: NativeSavedTracksRepository.likedSongsAsPlaylistUri);
  }

  EntityRepository _makeEntities() {
    final session = _pathfinder();
    final epoch = _epoch;
    return _AuthenticatedEntityRepository(DesktopEntityRepository(session.loader,
      dispatcher: EsperantoDispatcher()), session.prepare, (rows) {
        for (final row in rows) {
          if (row.isDisc || !row.isSupported) continue;
          _rememberArtwork(row.uri, row.images);
          if (row.type != 'track' && row.type != 'episode') continue;
          _trackMetadata[row.playbackUri] = {'title': row.name,
            ...row.playbackArtistMetadata,
            if (row.album?['name'] case final String album) 'album': album,
            if (row.album?['uri'] case final String albumUri) 'album_uri': albumUri,
            if (row.durationMs != null) 'duration_ms': row.durationMs,
            if (row.images.firstOrNull?['url'] case final String image) 'image_url': image};
        }
      }, playlistRepository: NativePlaylistEntityRepository(
        imageUrlTemplate: _imageUrlTemplate,
        presentation: (uri) => _playlistPresentations[uri] ?? const {},
        read: (uri, {cancellationToken}) { _check(epoch); return _readPlaylist(uri, cancellationToken: cancellationToken); },
        describeTracks: (uris, {cancellationToken}) {
          _check(epoch); return _describePlaylistTracks(uris, cancellationToken: cancellationToken); }),
      trackRepository: _NativeTrackEntityRepository((uris, {cancellationToken}) {
        _check(epoch); return _describePlaylistTracks(uris, cancellationToken: cancellationToken);
      }), artistRepository: NativeArtistEntityRepository(session.loader,
        readPopularTracks: (uri, {cancellationToken}) { _check(epoch); return _readPlaylist(uri,
          caller: PlaylistSyncCaller.SYNC_POLICY, cancellationToken: cancellationToken); },
        preReleaseV2: false, describeTracks: (uris, {cancellationToken}) {
          _check(epoch); return _describePlaylistTracks(uris, cancellationToken: cancellationToken);
        }));
  }

  SpotifyEntityMetadata? _cachedNativeTrackDescription(String uri) {
    final cached = _trackDescriptions.remove(uri), expiry = _trackDescriptionExpiry.remove(uri);
    if (cached == null || expiry == null || expiry < _now()) return null;
    _trackDescriptions[uri] = cached;
    _trackDescriptionExpiry[uri] = expiry;
    return cached;
  }

  Future<List<SpotifyEntityMetadata>> _fetchNativeTrackDescriptions(List<String> uris,
      {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (uris.isEmpty) return const [];
    final token = MergedCancellationToken([_sessionToken, ?cancellationToken]);
    final selected = uris.toSet().toList(growable: false);
    final result = <String, SpotifyEntityMetadata>{};
    try {
      for (var offset = 0; offset < selected.length; offset += 50) {
        token.throwIfCancelled();
        final waiting = <SharedTask<Map<String, SpotifyEntityMetadata>>, List<String>>{};
        final missing = <String>[];
        for (final uri in selected.skip(offset).take(50)) {
          final cached = _cachedNativeTrackDescription(uri);
          if (cached != null) { result[uri] = cached; continue; }
          final pending = _trackDescriptionJobs[uri];
          if (pending == null || pending.token.isCancelled) {
            missing.add(uri);
          } else {
            waiting.putIfAbsent(pending, () => []).add(uri);
          }
        }
        if (missing.isNotEmpty) {
          late final SharedTask<Map<String, SpotifyEntityMetadata>> job;
          job = SharedTask((workToken) async {
            try { return await _requestNativeTrackDescriptions(missing, workToken); }
            finally {
              for (final uri in missing) {
                if (identical(_trackDescriptionJobs[uri], job)) _trackDescriptionJobs.remove(uri);
              }
            }
          });
          for (final uri in missing) { _trackDescriptionJobs[uri] = job; }
          waiting[job] = missing;
        }
        final jobs = waiting.keys.toList(growable: false);
        final batches = await Future.wait(jobs.map((job) => job.wait(token)), eagerError: true);
        token.throwIfCancelled();
        for (var index = 0; index < jobs.length; index++) {
          for (final uri in waiting[jobs[index]]!) { result[uri] = batches[index][uri]!; }
        }
      }
      return [for (final uri in uris) result[uri]!];
    } finally {
      // A failed or abandoned read releases only its own interests in each
      // batch. Independently needed readers keep the actual HTTP task alive.
      token.cancel();
    }
  }

  Future<Map<String, SpotifyEntityMetadata>> _requestNativeTrackDescriptions(
      List<String> uris, CancellationToken token) async {
    token.throwIfCancelled();
    final epoch = _epoch;
    final policy = _apPolicy, ap = _ap;
    if (!ready || policy == null || ap == null) throw StateError('Sign in to Spotify');
    final plan = NativePlaylistTrackMetadataPlan.forFreshTracks(uris: uris,
      country: latin1.decode(policy.countryCode), catalogue: ap.productState['catalogue'] ?? '',
      fetchAssociationsWithTrackV4Enabled: false);
    final requests = SpotifyRequests(baseUrl: _nativeServerOrigin(),
      inheritedHeaders: _nativeApplicationHeaders, defaults: _defaults);
    final response = await _sendNativeServer(plan.envelope(requests)
      .withCancellation(token), epoch);
    token.throwIfCancelled();
    _check(epoch);
    if (response.statusCode != 200) throw SpotifyMediaHttpException(response.statusCode);
    final batch = SpotifyMetadataBatch.forTracks(uris,
      metadata.BatchedExtensionResponse.fromBuffer(response.bodyBytes));
    for (final entity in batch.entities) {
      final expiry = entity.problem == null && entity.providerErrorStatus == 200 &&
          entity.entityStatusCode == 200 && entity.matches.length == 1
        ? nativeMetadataExpiryMicroseconds(
          providerTtlSeconds: entity.matches.single.provider.header.cacheTtlInSeconds.toInt(),
          entityTtlSeconds: entity.matches.single.entity.header.cacheTtlInSeconds.toInt(),
          nowMicroseconds: _now()) : null;
      _trackDescriptions.remove(entity.uri); _trackDescriptionExpiry.remove(entity.uri);
      if (expiry == null) continue;
      _trackDescriptions[entity.uri] = entity;
      _trackDescriptionExpiry[entity.uri] = expiry;
      // This application bound is not a recovered native cache capacity.
      // Per-read snapshots retain their rows even when the LRU evicts a batch.
      while (_trackDescriptions.length > 512) {
        _trackDescriptionExpiry.remove(_trackDescriptions.keys.first);
        _trackDescriptions.remove(_trackDescriptions.keys.first);
      }
    }
    return {for (final entity in batch.entities) entity.uri: entity};
  }

  Future<SpotifyEntityMetadata> _lookupNativeTrack(String uri, {CancellationToken? cancellationToken}) async =>
    (await _fetchNativeTrackDescriptions([uri], cancellationToken: cancellationToken)).single;

  NativeTrackRelinker _trackRelinker({NativeTrackMetadataLookup? lookup}) {
    final policy = _apPolicy, ap = _ap;
    if (!ready || policy == null || ap == null) throw StateError('Sign in to Spotify');
    return NativeTrackRelinker(country: latin1.decode(policy.countryCode),
      catalogue: ap.productState['catalogue'] ?? '', lookup: lookup ?? _lookupNativeTrack);
  }

  Future<Map<String, EntityRow>> _describePlaylistTracks(List<String> uris, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final descriptions = await _fetchNativeTrackDescriptions(uris, cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    final snapshot = {for (final entity in descriptions) entity.uri: entity};
    final relinker = _trackRelinker(lookup: (uri, {cancellationToken}) async {
      cancellationToken?.throwIfCancelled();
      // Relinking consumes this read's result even when it grants no cache TTL.
      // This snapshot expires with the read; it does not extend server expiry.
      return snapshot[uri] ??= await _lookupNativeTrack(uri, cancellationToken: cancellationToken);
    });
    final rows = <String, EntityRow>{};
    for (final uri in uris) {
      cancellationToken?.throwIfCancelled();
      final original = snapshot[uri]!;
      SpotifyEntityMetadata entity = original;
      String? selectedUri;
      try {
        final resolved = await relinker.resolve(uri, cancellationToken: cancellationToken);
        selectedUri = resolved.selectedUri;
        entity = resolved.selectedMetadata ?? original;
      } on UnsupportedError {
        // Nonempty availability has its own original projection; no guessed
        // permission or alternative is admitted by this bounded path.
      }
      final row = _nativeTrackRow(uri, original, entity, selectedUri);
      if (row != null) rows[uri] = row;
    }
    return rows;
  }

  EntityRow? _nativeTrackRow(String uri, SpotifyEntityMetadata original,
      SpotifyEntityMetadata entity, String? selectedUri) {
    final track = entity.track;
    if (track == null || !track.hasName()) return null;
    final displayName = original.track?.name.isNotEmpty == true ? original.track!.name : track.name;
    final album = track.album;
    final covers = album.coverGroup.image.isNotEmpty ? album.coverGroup.image : album.cover;
    final images = <EntityJson>[for (final image in covers)
      if (image.fileId.length == 20) {
        'url': nativeImageUrlForId(image.fileId, template: _imageUrlTemplate),
        if (image.hasWidth()) 'width': image.width,
        if (image.hasHeight()) 'height': image.height,
      }];
    return EntityRow.fromJson({
        'type': 'track', 'uri': uri, 'name': displayName,
        if (selectedUri != null && selectedUri != uri) 'linkedUri': selectedUri,
        'artists': [for (final artist in track.artist) <String, Object?>{'name': artist.name,
          if (artist.gid.length == 16) 'uri': nativeSpotifyEntityUri('artist', artist.gid)}],
        'album': {'type': 'album', 'name': album.name, 'images': images,
          if (album.gid.length == 16) 'uri': nativeSpotifyEntityUri('album', album.gid)},
        if (track.hasDuration()) 'duration': {'milliseconds': track.duration},
        if (track.hasNumber()) 'trackNumber': track.number,
        if (track.hasDiscNumber()) 'discNumber': track.discNumber,
        'isExplicit': track.explicit,
        'canRequestPlayback': selectedUri != null &&
          entity.providerErrorStatus == 200 && entity.entityStatusCode == 200,
      }, source: {'uri': uri, 'selectedUri': selectedUri,
        'providerStatus': entity.providerErrorStatus, 'entityStatus': entity.entityStatusCode},
        unsupportedFeatures: const ['decorated-track-play-state']);
  }

  String _nativeServerOrigin() => nativeRegionalSpclientOrigin(_endpoints);

  String get _imageUrlTemplate => _ap?.productState['image-url'] ?? 'https://i.scdn.co/image/{file_id}';

  Future<http.Response> _sendNativeServer(RequestEnvelope request, int epoch,
      {String? sourceUri, bool prefetch = false}) async {
    final cancellation = CancellationToken();
    final token = MergedCancellationToken([_sessionToken, cancellation, ?request.cancellationToken]);
    void checkOwner() {
      _check(epoch);
      token.throwIfCancelled();
      if (sourceUri != null && _sourceCancelled(epoch, sourceUri, prefetch)) {
        throw const NativePlayPlayLicenseCancelled();
      }
    }
    checkOwner();
    final origin = _nativeServerOrigin();
    bool admit(RequestEnvelope request) {
      String? matched;
      for (final candidate in {origin, ..._nativeOrigins}) {
        if (request.url.startsWith('$candidate/')) { matched = candidate; break; }
      }
      if (matched == null) return false;
      final target = request.url.substring(matched.length);
      return request.method == 'POST' && (target == '/extended-metadata/v0/extended-metadata' ||
        target == '/collection/v2/paging' ||
        target == '/playlist/v2/playlist/37i9dQZF1F5p3rmiWPIYgZ/changes' ||
        RegExp(r'^/playplay/v1/key/[0-9a-f]{40}$').hasMatch(target)) ||
        request.method == 'PUT' && target == '/connect-state/v1/devices/$deviceId' ||
        request.method == 'GET' && (RegExp(r'^/playlist/v2/playlist/[0-9A-Za-z]{22}$').hasMatch(target) ||
          target == nativeRecentContextsTarget ||
          target == '/image-resolve/v1/resolve/map' ||
          RegExp(r'^/playlist/v2/list/popular-release-segments-main-roles/artist_[0-9A-Za-z]{22}$').hasMatch(target) ||
          RegExp(r'^/playlist/v2/user/(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+/rootlist\?decorate=revision%2Cattributes%2Clength%2Cowner%2Ccapabilities%2Cstatus_code%2Ctimestamp&from=(?:0|[1-9][0-9]*)&length=[1-9][0-9]*$').hasMatch(target) ||
          RegExp(r'^/storage-resolve/v2/files/audio/interactive/(?:0|1|2|8|9|16|22)/[0-9a-f]{40}\?product=0$').hasMatch(target));
    }
    if (!admit(request)) throw UnsupportedError('This native Spotify request is not connected');
    final credentials = _credentials;
    if (credentials == null) throw StateError('Sign in to Spotify');
    final subscription = sourceUri == null ? null : _watchSource(epoch, sourceUri, prefetch, cancellation);
    try {
    final prepared = await credentials.prepare(request.withCancellation(token)).asCancellable(token);
    // Credential acquisition can yield while the selected source changes.
    // An abandoned key job must not dispatch after that continuation resumes.
    checkOwner();
    if (sourceUri != null && prepared.method == 'POST' &&
        Uri.parse(prepared.url).path.startsWith('/playplay/v1/key/')) _musicLicenseAttempts++;
    final owned = _sendOwned(prepared, admit, handleResponse: (response) {
      checkOwner();
      return credentials.handleResponse(url: response.request?.url.toString() ?? prepared.url,
        statusCode: response.statusCode, headers: response.headers);
    });
      final response = await owned.response;
      checkOwner();
      return response;
    } catch (_) {
      checkOwner();
      rethrow;
    } finally { await subscription?.cancel(); }
  }

  NativePlayPlayMusicKeyExchange _makeMusicLicense({required String sourceUri, required bool prefetch,
      CancellationToken? cancellationToken}) {
    final epoch = _epoch;
    return NativePlayPlayMusicKeyExchange(template: RequestEnvelope(method: 'GET',
      url: _nativeServerOrigin(), headers: _nativeApplicationHeaders,
      authorize: false, includeCredentials: false, responseType: 'bytes', cancellationToken: cancellationToken),
      send: (request) async {
        final response = await _sendNativeServer(request, epoch, sourceUri: sourceUri, prefetch: prefetch);
        _musicLicenseResponses.update(response.statusCode, (count) => count + 1, ifAbsent: () => 1);
        (_musicLicensePurposeResponses.putIfAbsent(prefetch ? 'prefetch' : 'foreground', () => {}))
          .update(response.statusCode, (count) => count + 1, ifAbsent: () => 1);
        return response;
      },
      cacheId: const [],
      // Decoded current/queued sources use the ordinary raw0 client. The gated
      // Prefetch key-cache worker and integrity canary are separate owners.
      clientState: _musicKeyClientState ??= NativePlayPlayMusicKeyClientState(),
      timestampSeconds: () => DateTime.now().microsecondsSinceEpoch ~/ Duration.microsecondsPerSecond);
  }

  Future<playlist.SelectedListContent> _readPlaylist(String uri, {PlaylistSyncCaller caller = PlaylistSyncCaller.ESPERANTO,
      CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    final epoch = _epoch;
    final client = NativePlaylistReadClient(baseUrl: _nativeServerOrigin(),
      policy: NativePlaylistReadPolicy(caller: caller,
        prioritized: true, acceptListItems: true, dsaMode: false,
        listPlayerEnabled: true, applyAutoLens: true),
      headers: NativePlaylistRequestHeaders(locale: context.selectedLocale,
        timeZone: readMacOSIanaTimeZone(), userAgent: _nativeApplicationHeaders['User-Agent']!),
      nativeHttpSend: (request) => _sendNativeServer(request, epoch));
    return client.read(uri, cancellationToken: cancellationToken);
  }

  @override Future<void> signIn({CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    _ownerCancellation?.throwIfCancelled();
    if (_closed) throw StateError('Spotify session is closed');
    if (ready) return;
    final registration = CancellationRegistration(cancellationToken,
      onCancel: (error) => _sessionToken.cancel(error));
    try {
      await (_signingIn ??= _authenticate(cancellationToken: cancellationToken)
        .whenComplete(() => _signingIn = null));
      cancellationToken?.throwIfCancelled();
    } finally { registration.dispose(); }
  }

  Future<void> _authenticate({CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    await _retire();
    cancellationToken?.throwIfCancelled();
    _sessionCancellation = null;
    final token = _sessionToken;
    token.throwIfCancelled();
    final epoch = _epoch;
    try {
      final proofs = DpopProofGenerator(key: P256DpopKey.generate());
      final callback = await NativeAccountsCallbackServer.open(cancellationToken: token);
      try { token.throwIfCancelled(); _check(epoch); }
      catch (_) { await callback.close(); rethrow; }
      _callback = callback;
      _status.value = 'Finish signing in in your browser';
      final grant = await callback.authenticate(login: NativeDesktopAccountsLogin(
        send: _accountsSend, proofs: proofs, nowMicroseconds: _now),
        openBrowser: (url) => const DesktopHost().openExternalUrl(url, cancellationToken: token),
        cancellationToken: token);
      _check(epoch);
      _callback = null;
      _grant = grant;
      _status.value = 'Connecting to Spotify…';
      _installCredentials(grant, proofs, seedAccessToken: true);
      await _persistSession();
      await _connectAp(epoch, grant);
      _check(epoch);
      _status.value = 'Connected as ${grant.username}';
    } catch (error) {
      if (!_closed && epoch == _epoch && _ownerCancellation?.isCancelled != true) {
        await _retire();
        if (!_closed && _ownerCancellation?.isCancelled != true) {
          _status.value = cancellationToken?.isCancelled == true
            ? 'Sign in to listen' : 'Sign-in could not finish: $error';
        }
      }
      rethrow;
    }
  }

  void _installCredentials(NativeOAuthTokenResponse grant, DpopProofGenerator proofs,
      {required bool seedAccessToken}) {
    final state = NativeOAuthRefreshState(refreshToken: grant.refreshToken, dpopNonce: grant.dpopNonce);
    _proofs = proofs;
    _refreshState = state;
    late final NativeTokenProvider tokens;
    void fail(Object error, StackTrace stack) {
      tokens.close();
      if (!_closed && !_sessionToken.isCancelled) _status.value = 'Spotify session needs sign-in: $error';
    }
    tokens = NativeTokenProvider(initialToken: seedAccessToken ? NativeAccessToken(accessToken: grant.accessToken,
      tokenType: grant.tokenType, expiresAtMicroseconds: grant.expiresAtMicroseconds) : null,
      nowMicroseconds: _now, nowNanoseconds: () => _clock.elapsedMicroseconds * 1000,
      operationFactory: () => NativeOAuthTokenOperation(onError: fail,
        sendOwned: (request) => _sendOwned(request, _accountsRoute),
        refresh: NativeOAuthRefresh(clientId: DesktopIdentity.accountsClientId,
          state: state, send: _accountsSend, nowMicroseconds: _now,
          proof: ({required method, required url, required nonce}) async =>
            proofs.createProof(method: method, url: url, nonce: nonce))));
    _tokens = tokens;
    final codec = NativeClientTokenCodec();
    late final NativeClientTokenProvider clientTokens;
    clientTokens = NativeClientTokenProvider(
      clientData: NativeClientDataFactory(facts: facts,
        clientId: DesktopIdentity.accountsClientId, deviceId: deviceId),
      nowMicroseconds: _now, encodeToken: codec.encode,
      onError: (error, stack) {
        clientTokens.close();
        if (!_closed) _status.value = 'Spotify connection failed: $error';
      }, sendOwned: (body) {
        final owner = _sendOwned(RequestEnvelope(method: 'POST',
          url: 'https://clienttoken.spotify.com/v1/clienttoken', authorize: false,
          nativeTimeoutMilliseconds: 30000, body: body, headers: const {
            'Content-Type': 'application/x-protobuf', 'Accept': 'application/x-protobuf',
            'Cache-Control': 'no-cache, no-store, max-age=0'}),
          (request) => request.method == 'POST' && request.url == 'https://clienttoken.spotify.com/v1/clienttoken');
        return NativeClientTokenOwnedSend(response: owner.response, abort: owner.abort);
      });
    clientTokens.enable();
    _clientTokens = clientTokens;
    _credentials = NativeHttpCredentials(accessTokens: tokens, clientTokens: clientTokens,
      loadAccessToken: _sessionAccessToken, invalidateAccessToken: _invalidateSessionAccessToken);
  }

  Future<void> _connectAp(int epoch, NativeOAuthTokenResponse grant) async {
    final token = _sessionToken;
    token.throwIfCancelled();
    final previous = _ap, previousPackets = _apPackets, previousPolicy = _apPolicy;
    final previousCountry = previousPolicy?.countryCode.toString();
    final previousCatalogue = previous?.productState['catalogue'];
    if (_endpoints.isNotEmpty) _nativeOrigins.add(_nativeServerOrigin());
    final stored = _nativeStoredCredentials != null
      ? NativeLegacyAuthCodec().decode(_nativeStoredCredentials!) : null;
    final credential = stored ?? NativeLegacyCredential.accountsAccessToken(
      username: grant.username, accessToken: (await _accessToken()).accessToken);
    _check(epoch);
    final plan = NativeApResolver(profile: NativeApResolverProfile.fromNativeIdentity(
      versionValue: DesktopIdentity.numericVersion, systemInfo: apSystemInfo,
      endpointTypes: const [0, 1, 2, 3]), nowMicroseconds: _now,
      template: RequestEnvelope(method: 'GET', url: '', headers: const {}, authorize: false)).plan();
    final resolved = await _sendOwned(plan.request, (request) => request.method == 'GET' &&
      request.url.startsWith('https://apresolve.spotify.com/v2?')).response;
    _check(epoch);
    _endpoints = decodeNativeApResolverResponse(status: resolved.statusCode, body: resolved.bodyBytes);
    _nativeOrigins.add(_nativeServerOrigin());
    final endpoint = _endpoints.firstWhere((endpoint) => endpoint.type == 0 && endpoint.host.isNotEmpty,
      orElse: () => throw const FormatException('Spotify did not supply an access point'));
    token.throwIfCancelled();
    final task = await Socket.startConnect(endpoint.host, endpoint.port);
    if (token.isCancelled) { task.cancel(); token.throwIfCancelled(); }
    final dial = CancellationRegistration(token, onCancel: (_) => task.cancel());
    final Socket socket;
    try {
      socket = await task.socket.timeout(const Duration(seconds: 30), onTimeout: () {
        task.cancel(); throw TimeoutException('Spotify AP connection deadline', const Duration(seconds: 30));
      });
      if (token.isCancelled) { socket.destroy(); token.throwIfCancelled(); }
    } finally { dial.dispose(); }
    if (_closed || epoch != _epoch) { socket.destroy(); _check(epoch); }
    final policy = NativeApPacketPolicy();
    final ap = createNativeSpotifyApSession(helloProfile: NativeApHelloProfile.referenceDesktop(),
      authenticationProfile: NativeApAuthenticationProfile.freshDesktop(deviceId: deviceId,
        language: context.selectedLocale, systemInfo: apSystemInfo, platformIdentity: identity),
      credential: credential,
      incoming: socket, sendBytes: (bytes) async { _check(epoch); socket.add(bytes); await socket.flush(); },
      closeTransport: () async { socket.destroy(); }, packetPolicy: policy);
    _connectingAp = ap;
    final packets = ap.packets.listen((_) {}, onError: (Object error) {
      if (!_closed && identical(_ap, ap)) _apFailed(ap, error);
    }, onDone: () {
      if (!_closed && identical(_ap, ap) && ap.failure != null) _apFailed(ap, ap.failure!);
    });
    _connectingApPackets = packets;
    var installed = false;
    try {
      final welcome = await ap.start(cancellationToken: token);
      _check(epoch);
      if (welcome.canonicalUsername != grant.username) {
        throw const FormatException('Spotify returned a different account for playback');
      }
      // Do not replace verified account facts with a half-open connection.
      bool factsPresent() => ap.serverAttributes.containsKey(0x1b) &&
        ap.serverAttributes.containsKey(0x50);
      if (!factsPresent()) await ap.packets.firstWhere((_) => factsPresent()).asCancellable(token);
      _check(epoch);
      if (ap.state != SpotifyApSessionState.ready) throw ap.failure ?? StateError('AP connection closed');
      _ap = ap; _apPolicy = policy; _apPackets = packets;
      _cacheNativeWelcomeCredential();
      _apSessionInvalidated = false;
      installed = true;
      if (previousCountry != null && (previousCountry != policy.countryCode.toString() ||
          previousCatalogue != ap.productState['catalogue'])) {
        for (final job in _trackDescriptionJobs.values.toSet()) { job.token.cancel(); }
        _trackDescriptionJobs.clear();
        _trackDescriptions.clear(); _trackDescriptionExpiry.clear();
        _search = null; _home = null; _entities = null; _library = null;
      }
      await previousPackets?.cancel();
      await previous?.close();
      unawaited(_persistSession(cancellationToken: token).catchError((Object error) {
        if (!token.isCancelled) debugPrint('Spotify session could not be saved: $error');
      }));
    } finally {
      if (identical(_connectingAp, ap)) {
        _connectingAp = null; _connectingApPackets = null;
      }
      if (!installed) { await packets.cancel(); await ap.close(); }
    }
  }

  void _apFailed(SpotifyApSession ap, Object error) {
    if (!identical(_ap, ap)) return;
    if (error is NativeApSessionInvalidated || error is SpotifyApAuthenticationException) {
      _apSessionInvalidated = true;
      _status.value = 'Spotify sign-in needs to be renewed';
      unawaited(_engine?.command('unload'));
      return;
    }
    _kickApRecovery();
  }

  Future<void> _recoverAp() async {
    final grant = _grant;
    if (_closed || grant == null || _apSessionInvalidated ||
        _ap?.state == SpotifyApSessionState.ready) return;
    final epoch = _epoch;
    _status.value = 'Reconnecting to Spotify…';
    try {
      await _connectAp(epoch, grant);
      _check(epoch);
      _status.value = 'Connected as ' + (username ?? '');
    } catch (error) {
      if (!_closed && epoch == _epoch) {
        if (error is NativeApSessionInvalidated || error is SpotifyApAuthenticationException) {
          _apSessionInvalidated = true;
        }
        _status.value = 'Spotify connection could not recover: $error';
      }
      rethrow;
    }
  }

  void _kickApRecovery() {
    if (_closed || _grant == null || _apSessionInvalidated || _signingIn != null ||
        _connectingAp != null || _reconnectingAp != null ||
        _ap?.state == SpotifyApSessionState.ready) return;
    late final Future<void> pending;
    pending = _recoverAp().then<void>((_) {}, onError: (Object error, StackTrace stack) {})
      .whenComplete(() { if (identical(_reconnectingAp, pending)) _reconnectingAp = null; });
    _reconnectingAp = pending;
  }

  @override void bindEngine(PlaybackEngine engine) {
    if (!identical(_engine, engine) || _canaryEvents == null) {
      unawaited(_canaryEvents?.cancel());
      _canaryEvents = engine.events.listen((event) {
        if (identical(_engine, engine)) {
          _observeCanaryAudioStart(event);
          if (event['type'] == 'player' && event['event'] == 'volume_changed') {
            _connectStatePublisher?.deviceChanged();
          }
        }
      });
    }
    _engine = engine;
    _warmPlaybackCpu();
    // A hot-reloaded session can still contain the old global preference.
    // Only regional music owners are admitted by the captured policy.
    final globalOrigins = {for (final endpoint in _endpoints.where((entry) => entry.type == 2))
      'https://${endpoint.host}${endpoint.port == 443 ? '' : ':${endpoint.port}'}'};
    _nativeOrigins.removeAll(globalOrigins);
    _kickApRecovery();
  }

  void bindContextPlayer(ContextPlayerBackend backend) {
    if (_closed || identical(_connectStatePublisher?.backend, backend)) return;
    unawaited(_connectStatePublisher?.close());
    _connectStatePublisher = NativeConnectStatePublisher(backend: backend, deviceId: deviceId,
      isReady: () => ready, origin: _nativeServerOrigin, openPush: _ensureNativePusher,
      template: () => RequestEnvelope(method: 'GET', url: _nativeServerOrigin(),
        headers: _nativeApplicationHeaders, responseType: 'bytes'),
      deviceInfo: () => connect.DeviceInfo(canPlay: ready && _engine != null,
        volume: preferences.get('app.player.volume').entries['app.player.volume']?.number.toInt() ?? 65535,
        name: 'Spotify Flutter', deviceId: deviceId, clientId: DesktopIdentity.accountsClientId,
        deviceSoftwareVersion: DesktopIdentity.fullVersion, deviceType: devices.DeviceType.COMPUTER,
        productId: _ap?.productState['product'] ?? '',
        capabilities: connect.Capabilities(canBePlayer: true, isObservable: true,
          disableVolume: true, supportedTypes: const ['audio/track'])),
      send: (request) async {
        final response = await _sendNativeServer(request, _epoch);
        if (response.statusCode != 200) throw HttpResponseError(message: 'Spotify playback reporting returned ${response.statusCode}',
          status: response.statusCode, url: request.url, method: request.method);
        final cluster = connect.Cluster.fromBuffer(response.bodyBytes);
        _connectReportingError = null;
        return cluster;
      },
      onError: (error) {
        if (_connectReportingError?.runtimeType != error.runtimeType) {
          debugPrint('Spotify playback reporting: ${error.runtimeType}');
        }
        _connectReportingError = error;
      });
  }

  void _observeCanaryAudioStart(PlayerJson event) {
    if (!ready || event['type'] != 'player' ||
        (event['event'] != 'playing' && event['event'] != 'transition')) return;
    final engine = _engine;
    if (engine is! AudioSourceOwner || !engine.isCurrentAudioSourceEvent(event)) return;
    final load = event['play_request_id'];
    if (load is! int || load == _lastCanaryAudioLoad) return;
    final product = _ap!.productState;
    // This runtime owns the AP XML product-state path. A separate original
    // UCS product-state provider must not be substituted with this AP map.
    if (product.isEmpty || product['com.spotify.madprops.use.ucs.product.state'] == '1') return;
    _lastCanaryAudioLoad = load;
    final epoch = _epoch;
    final owner = _canary ??= NativePlayPlayCanary(template: RequestEnvelope(method: 'GET',
      url: _nativeServerOrigin(), headers: _nativeApplicationHeaders,
      authorize: false, includeCredentials: false, responseType: 'bytes', cancellationToken: _sessionToken),
      productState: () => _ap!.productState,
      monotonicNanoseconds: () => _clock.elapsedMicroseconds * 1000,
      timestampSeconds: () => DateTime.now().microsecondsSinceEpoch ~/ Duration.microsecondsPerSecond,
      isReady: () => ready && epoch == _epoch &&
        _ap!.productState['com.spotify.madprops.use.ucs.product.state'] != '1',
      send: (request) => _sendNativeServer(request, epoch));
    // Original current-track +f30 is explicitly onAudioStarted. The Dart
    // output has started or crossed its real queued-track sample boundary;
    // metadata, selection and successful license replies do not call this.
    owner.onAudioStarted();
  }

  void _warmPlaybackCpu() {
    // CPU-only, deduplicated and bounded. Sign-in/browsing proceed immediately;
    // no synthetic result enters the successful-key cache or any request.
    final cancellation = _sessionToken;
    unawaited(warmNativePlayPlayMusicKeyWorker(cancellationToken: cancellation).catchError((Object error) {
      if (!cancellation.isCancelled && error is! CancelledException) debugPrint('Playback CPU warm-up: $error');
    }));
  }

  @override Future<PreparedAudioFile> resolve(String uri, {CancellationToken? cancellationToken}) =>
    _resolvePlayback(uri, NativePlaybackId().bytes, cancellationToken: cancellationToken);

  Future<PreparedAudioFile> resolvePlayback(SpotifyAudioSourceRequest request) =>
    _resolvePlayback(request.uri, request.playbackId, prefetch: request.prefetch,
      cancellationToken: request.cancellationToken);

  Future<PreparedAudioFile> _resolvePlayback(String uri, List<int> playbackId, {bool prefetch = false,
      CancellationToken? cancellationToken}) async {
    final token = cancellationToken == null ? _sessionToken : _sessionToken.merge(cancellationToken);
    token.throwIfCancelled();
    if (_sourceCancelled(_epoch, uri, prefetch)) throw const NativePlayPlayLicenseCancelled();
    final stopwatch = Stopwatch()..start();
    final timing = <String, Object?>{'next': prefetch};
    _kickApRecovery();
    if (!ready) throw StateError('Sign in to listen to Spotify');
    final relink = await _trackRelinker().resolve(uri, cancellationToken: token);
    token.throwIfCancelled();
    timing['track_info_ms'] = stopwatch.elapsedMilliseconds;
    final selectedUri = relink.selectedUri;
    if (selectedUri == null) {
      throw const PlaybackEngineException('track_unavailable', 'Spotify has no available version of this track for this session.');
    }
    // TrackV4 is already required for source admission. Its decoded metadata
    // also owns the player title/artwork/links for direct URLs and fresh sign-in;
    // do not depend on a preceding Search or playlist-page visit to seed them.
    final row = _nativeTrackRow(uri, relink.originalMetadata, relink.selectedMetadata!, selectedUri);
    if (row != null) {
      final display = <String, Object?>{...?_trackMetadata[uri], 'title': row.name,
        ...row.playbackArtistMetadata,
        if (row.album?['name'] case final String name) 'album': name,
        if (row.album?['uri'] case final String albumUri) 'album_uri': albumUri,
        if (row.durationMs != null) 'duration_ms': row.durationMs,
        if (row.images.firstOrNull?['url'] case final String image) 'image_url': image};
      _trackMetadata[uri] = display;
      _trackMetadata[selectedUri] = display;
      _rememberArtwork(uri, row.images);
    }
    final ap = _ap!, policy = _apPolicy!;
    final config = NativeCoreBitrateConfiguration();
    final quality = NativeAudioQualityPolicy(preferences: preferences, productState: ap.productState)
      .resolve(backend: config.backendSettings(ap.productState), isMetered: false, useNetworkSelection: false);
    final progressive = Platform.isMacOS && FfmpegStreamingDecoder.available;
    final cacheKey = jsonEncode([selectedUri, latin1.decode(policy.countryCode),
      ap.productState['catalogue'], ap.productState['explicit-content'],
      relink.selectedMetadata!.matches.single.entity.header.etag,
      quality.setting, quality.secondarySetting, quality.nativeClassLimit,
      if (progressive) 'pcm48-stream-v1']);
    final cache = _preparedAudio ??= PreparedAudioCache();
    final hits = cache.hits;
    try {
      final file = await cache.obtain(cacheKey,
        (cancellation) => _resolveFreshPlayback(selectedUri, playbackId, prefetch: prefetch,
          cancellation: cancellation,
          ownerUri: uri, timing: timing, progressive: progressive),
        requestClass: prefetch ? 'prefetch' : 'foreground', cancellationToken: token);
      timing['cached_pcm'] = cache.hits > hits;
      timing['result'] = 'ready';
      return file;
    } catch (_) { timing['result'] = 'failed'; rethrow; }
    finally {
      timing['total_ms'] = stopwatch.elapsedMilliseconds;
      _sourceStartupTimings.add(Map.unmodifiable(timing));
      if (_sourceStartupTimings.length > 24) _sourceStartupTimings.removeAt(0);
    }
  }

  bool _sourceCancelled(int epoch, String uri, bool prefetch) {
    if (_closed || epoch != _epoch || !ready) return true;
    final engine = _engine;
    return engine is AudioSourceOwner && !engine.wantsAudioSource(uri, prefetch: prefetch);
  }

  StreamSubscription<void>? _watchSource(int epoch, String uri, bool prefetch, CancellationToken token) {
    final engine = _engine;
    return engine is AudioSourceOwner ? engine.audioSourceChanges.listen((_) {
      if (_sourceCancelled(epoch, uri, prefetch)) token.cancel(const NativePlayPlayLicenseCancelled());
    }) : null;
  }

  Future<void> _waitMusicRetry(Duration delay, CancellationToken token) =>
    CancellableFuture.delayed<void>(delay, token);

  Future<PreparedAudioFile> _resolveFreshPlayback(String uri, List<int> playbackId,
      {required bool prefetch, required String ownerUri, required Map<String, Object?> timing,
      required CancellationToken cancellation, bool progressive = false}) async {
    cancellation.throwIfCancelled();
    final owner = _streamingCache;
    if (owner == null) {
      return _prepareFreshPlayback(uri, playbackId, prefetch: prefetch,
        ownerUri: ownerUri, timing: timing, cancellation: cancellation, progressive: progressive);
    }
    retainStreamingCacheDirectory(owner);
    PreparedAudioFile? source;
    var transferred = false;
    try {
      final file = source = await _prepareFreshPlayback(uri, playbackId, prefetch: prefetch,
        ownerUri: ownerUri, timing: timing, cancellation: cancellation, progressive: progressive);
      final lease = PreparedAudioFile(path: file.path, metadata: file.metadata,
        encoding: file.encoding, progress: file.progress, release: () async {
          try { await file.close(); }
          finally { await releaseStreamingCacheDirectory(owner); }
        });
      transferred = true;
      return lease;
    } finally {
      // Includes the complete producer/decoder cleanup, not just a cancelled
      // reader Future. Successful sources hold the root through their last lease.
      if (!transferred) {
        try { await source?.close(); }
        finally { await releaseStreamingCacheDirectory(owner); }
      }
    }
  }

  Future<PreparedAudioFile> _prepareFreshPlayback(String uri, List<int> playbackId,
      {required bool prefetch, required String ownerUri, required Map<String, Object?> timing,
      required CancellationToken cancellation, bool progressive = false}) async {
    final phase = Stopwatch()..start();
    if (!ready) throw StateError('Sign in to listen to Spotify');
    nativeSpotifyTrackGid(uri);
    final epoch = _epoch;
    final token = _sessionToken.merge(cancellation);
    if (_sourceCancelled(epoch, ownerUri, prefetch)) cancellation.cancel(const NativePlayPlayLicenseCancelled());
    token.throwIfCancelled();
    final sourceWatch = _watchSource(epoch, ownerUri, prefetch, cancellation);
    var progressOwnsWatch = false;
    final ap = _ap!, policy = _apPolicy!;
    final origin = _nativeServerOrigin();
    final requests = SpotifyRequests(baseUrl: origin, inheritedHeaders: _nativeApplicationHeaders, defaults: _defaults);
    void checkOwner() {
      _check(epoch);
      token.throwIfCancelled();
    }
    Future<http.StreamedResponse> send(RequestEnvelope request) async {
      checkOwner();
      final cdn = _signedMediaUrls.contains(request.url);
      if (!cdn) {
        final stage = Uri.parse(request.url).path.startsWith('/extended-metadata/') ? 'audio_info' : 'storage';
        final timer = Stopwatch()..start();
        // Metadata and storage use the same native template, credential
        // response chain and cancelable owner as browsing and music keys.
        final response = await _sendNativeServer(request.withCancellation(token), epoch,
          sourceUri: ownerUri, prefetch: prefetch);
        timing.putIfAbsent('${stage}_http_ms', () => timer.elapsedMilliseconds);
        checkOwner();
        return http.StreamedResponse(Stream.value(response.bodyBytes), response.statusCode,
          headers: response.headers, contentLength: response.bodyBytes.length,
          request: response.request, reasonPhrase: response.reasonPhrase);
      }
      timing.putIfAbsent('cdn_started_ms', () => phase.elapsedMilliseconds);
      final transport = NativeCefHttpTransport(defaults: _defaults,
        options: NativeCefOptions(adapterOption80: 0),
        adapterUserAgent: identity.nativeUserAgent, context: context,
        pool: _cdnPool ??= NativeCefHttpConnectionPool(),
        admitRemoteRequest: (request) => request.method == 'GET' && _signedMediaUrls.contains(request.url));
      _cdnRequests.add(transport);
      void release() { _cdnRequests.remove(transport); transport.close(); }
      final cleanup = CancellationRegistration(token, onCancel: (_) => release());
      try {
        final headersTimer = Stopwatch()..start();
        final response = await transport.sendStream(request.withCancellation(token)).asCancellable(token);
        checkOwner();
        timing.putIfAbsent('cdn_response_headers_ms', () => headersTimer.elapsedMilliseconds);
        Stream<List<int>> body() async* {
          try {
            await for (final chunk in response.stream) { checkOwner(); yield chunk; }
            checkOwner();
          } finally { cleanup.dispose(); release(); }
        }
        return http.StreamedResponse(body(), response.statusCode, headers: response.headers,
          contentLength: response.contentLength, reasonPhrase: response.reasonPhrase);
      } catch (_) {
        cleanup.dispose();
        release();
        checkOwner();
        rethrow;
      }
    }
    if (!prefetch && !_sourceCancelled(epoch, ownerUri, prefetch)) _status.value = 'Opening track…';
    try {
      // Exact original single-source cache-miss plan. Both trait prewarming and
      // BYOM use their independently recovered false config fallbacks. This
      // music source has no video-association capability (raw owner flag52).
      final country = latin1.decode(policy.countryCode), catalogue = ap.productState['catalogue'] ?? '';
      final metadataCacheKey = jsonEncode([uri, country, catalogue]);
      final cachedFiles = _audioFilesCache.remove(metadataCacheKey);
      final NativeAudioFilesMetadata files;
      int? receivedAtUs;
      if (cachedFiles != null && _now() <= cachedFiles.expiresAtUs) {
        files = cachedFiles.files;
        _audioFilesCache[metadataCacheKey] = cachedFiles;
        timing['cached_audio_info'] = true;
      } else {
        final plan = NativeAudioFilesRequestPlan.forReadyTrackCacheMiss(uri: uri,
          country: country, catalogue: catalogue,
          nativeOwnerFlag51: false, nativeOwnerFlag52: false, nativeOwnerFlag53: false);
        final metadataRequests = SpotifyRequests(baseUrl: origin,
          inheritedHeaders: _nativeApplicationHeaders, defaults: _defaults);
        final response = await http.Response.fromStream(await send(plan.envelope(metadataRequests)));
        receivedAtUs = _now();
        checkOwner();
        if (response.statusCode != 200) throw SpotifyMediaHttpException(response.statusCode);
        files = NativeAudioFilesMetadata.fromResponse(uri,
          metadata.BatchedExtensionResponse.fromBuffer(response.bodyBytes));
        timing['cached_audio_info'] = false;
      }
      timing['audio_info_ms'] = phase.elapsedMilliseconds;
      checkOwner();
      _audioMetadata = files;
      // Original normal-source projection100845e34/100845ee4 consumes the
      // successfully decoded kind5 payload; provider_error_status is a raw
      // status value, not an independently established zero-success enum.
      if (files.problem != null) {
        throw StateError('Spotify did not supply this track (${files.problem!.name})');
      }
      if (files.providerErrorStatus != 200 || files.entityStatusCode != 200) {
        throw StateError('Spotify did not make this track available');
      }
      final payload = files.payload!;
      // Native streaming-source identity virtual+0x28 (10129a720) returns
      // this exact16-byte audio_id through101d0715c. Shared audio may have an
      // identity different from the URI; no synthetic GID/remap is generated.
      final audioIdentity = files.audioIdentity;
      if (receivedAtUs != null) {
        final match = files.matches.single;
        // Original10060caa0: nonzero entity TTL overrides provider TTL;
        // expiry truncates to whole seconds. Positive server lifetimes only,
        // capped at the original90-day bound. We never extend a TTL using
        // the native owner's separately configured minimum.
        final expiry = nativeMetadataExpiryMicroseconds(
          providerTtlSeconds: match.provider.header.cacheTtlInSeconds.toInt(),
          entityTtlSeconds: match.entity.header.cacheTtlInSeconds.toInt(), nowMicroseconds: receivedAtUs);
        if (expiry != null) {
          _audioFilesCache[metadataCacheKey] = (files: files, expiresAtUs: expiry);
          if (_audioFilesCache.length > 128) _audioFilesCache.remove(_audioFilesCache.keys.first);
        }
      }
      final eligible = <NativeAudioFileCandidate>[
        for (final entry in payload.files)
          if (entry.hasFile() && entry.file.hasFormat() && entry.file.fileId.length == 20)
            NativeAudioFileCandidate(fileId: entry.file.fileId, format: entry.file.format.value),
      ];
      final config = NativeCoreBitrateConfiguration();
      final quality = NativeAudioQualityPolicy(preferences: preferences, productState: ap.productState)
        .resolve(backend: config.backendSettings(ap.productState), isMetered: false, useNetworkSelection: false);
      final selection = SpotifyAudioSelection.fromNativePolicy(uri: uri, eligibleFiles: eligible,
        quality: quality, formatPolicy: config.formatPolicy(
          supportsFormat: (format) => const {0, 1, 2, 8, 9, 16, 22}.contains(format)),
        trackGid: audioIdentity, storageMode: 0,
        containerFor: (file) => switch (file.format) {
          0 || 1 || 2 => SpotifyAudioContainer.ogg,
          8 || 9 => SpotifyAudioContainer.mp4,
          16 || 22 => SpotifyAudioContainer.flac,
          _ => throw const FormatException('Unsupported audio container'),
        }, metadata: {...?_trackMetadata[uri],
          if (payload.audioId.length == 16)
            'audio_id': payload.audioId.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()});
      final client = SpotifyMediaClient(requests: requests, send: send, playbackId16: playbackId);
      final cache = await (_mediaCache ??= _openMediaCache());
      checkOwner();
      final keys = _audioKeys ??= SessionAudioKeyCache();
      var admittedKey = false;
      var usedCachedKey = false;
      final decryptionAdmission = Completer<void>();
      void admitDecryption() {
        timing.putIfAbsent('license_admitted_ms', () => phase.elapsedMilliseconds);
        if (!decryptionAdmission.isCompleted) decryptionAdmission.complete();
      }
      try {
        final source = SpotifyMediaSource(client: client,
          cache: cache,
          decryptionAdmission: decryptionAdmission.future,
          stager: SpotifyAudioStager(directory: _streamingWorkingDirectory, streamOgg: progressive,
            cancellationToken: token), rangeBytes: 0x300000,
          selectAudio: (_, {cancellationToken}) async {
            cancellationToken?.throwIfCancelled();
            return selection;
          },
          selectCdn: (resolved) {
            final url = resolved.cdnurl.first;
            _signedMediaUrls.addAll(resolved.cdnurl);
            return url;
          }, obtainDecryption: (selection, {cancellationToken}) async {
            final keyCancellation = MergedCancellationToken([token, ?cancellationToken]);
            keyCancellation.throwIfCancelled();
            final keyTimer = Stopwatch()..start();
            checkOwner();
            final cachedKey = keys.read(selection.fileId);
            if (cachedKey != null) {
              usedCachedKey = true;
              admitDecryption();
              timing['cached_key'] = true;
              timing['key_ms'] = keyTimer.elapsedMilliseconds;
              try { return SpotifyAudioDecryptor.encrypted(cachedKey); }
              finally { cachedKey.fillRange(0, cachedKey.length, 0); }
            }
            // Current and queued decoded audio both use the ordinary source
            // contract100a40420/100a40f44, which supplies fixed raw0. Raw2 is
            // a separate, gated future-key-cache worker1005b6524; preparing
            // the next decoder does not make this a future-key-cache job.
            const nativeInteractivity = 0;
            final NativePlayPlayLicenseReply reply;
            final licenseTimer = Stopwatch()..start();
            try { reply = await _makeMusicLicense(sourceUri: ownerUri, prefetch: prefetch,
              cancellationToken: keyCancellation).request(selection.fileId,
              nativeInteractivity: nativeInteractivity,
              cancellationToken: keyCancellation,
              waitForRetry: (delay) => _waitMusicRetry(delay, keyCancellation),
              onRetry: (error, attempt, delay) {
                timing['key_retries'] = attempt;
                _lastMusicLicenseFailure = error;
                if (!prefetch && !_sourceCancelled(epoch, ownerUri, prefetch)) {
                  _status.value = 'Waiting for Spotify…';
                }
              }); }
            on NativePlayPlayLicenseException catch (error) {
              _lastMusicLicenseFailure = error;
              rethrow;
            }
            keyCancellation.throwIfCancelled();
            checkOwner();
            timing['license_ms'] = licenseTimer.elapsedMilliseconds;
            admitDecryption();
            final unwrapTimer = Stopwatch()..start();
            final key = await unwrapNativePlayPlayMusicKey(reply.obfuscatedBytes, cancellationToken: keyCancellation);
            timing['unwrap_ms'] = unwrapTimer.elapsedMilliseconds;
            timing['cached_key'] = false;
            timing['key_ms'] = keyTimer.elapsedMilliseconds;
            try {
              checkOwner();
              // A successful key belongs to the session, independently of
              // the CDN connection and decoder. A transport failure must not
              // force another license acquisition on the next user attempt.
              keys.admit(selection.fileId, key);
              timing['key_ready_ms'] = phase.elapsedMilliseconds;
              admittedKey = true;
              return SpotifyAudioDecryptor.encrypted(key);
            } finally { key.fillRange(0, key.length, 0); }
          });
        final containerTimer = Stopwatch()..start();
        var file = await source.resolve(uri, cancellationToken: token);
        timing['container_ms'] = containerTimer.elapsedMilliseconds;
        // macOS26.4's native Vorbis path grows the caulk realtime allocator
        // rapidly even with a paused player. Decode compressed Ogg with our
        // existing standard FFmpeg primitive; AVFoundation receives PCM only.
        if (progressive && file.encoding != PreparedAudioEncoding.pcmS16leStereo48000) {
          file = await const FfmpegStreamingDecoder().prepareFile(file, directory: _streamingWorkingDirectory,
            cancellationToken: token);
        } else if (Platform.isMacOS && selection.container == SpotifyAudioContainer.ogg &&
            file.encoding != PreparedAudioEncoding.pcmS16leStereo48000) {
          final decodeTimer = Stopwatch()..start();
          file = await const FfmpegAudioDecoder().prepare(file, directory: _streamingWorkingDirectory,
            cancellationToken: token);
          timing['decode_ms'] = decodeTimer.elapsedMilliseconds;
        }
        if (file.encoding == PreparedAudioEncoding.pcmS16leStereo48000) {
          timing['first_pcm_ms'] = phase.elapsedMilliseconds;
          timing['progressive_pcm'] = true;
          final progress = file.progress;
          if (progress != null) unawaited(progress.completion.then<void>((_) {},
            onError: (Object error, StackTrace _) {
              if (error is PlaybackEngineException && error.code == 'audio_decode') {
                keys.invalidate(selection.fileId);
              }
            }));
        }
        try { checkOwner(); }
        catch (_) { await file.close(); rethrow; }
        if (file.progress case final progress?) {
          progressOwnsWatch = true;
          unawaited(progress.completion.then<void>((_) async { await sourceWatch?.cancel(); },
            onError: (Object _, StackTrace _) async { await sourceWatch?.cancel(); }));
        }
        if (!prefetch && !_sourceCancelled(epoch, ownerUri, prefetch)) {
          _status.value = 'Connected as ${username ?? ''}';
        }
        return file;
      } on PlaybackEngineException catch (error) {
        // Only a real container/decoder rejection withdraws this admission;
        // malformed HTTP framing and connection failures are not key rejection.
        if (error.code == 'audio_decode' && (usedCachedKey || admittedKey)) keys.invalidate(selection.fileId);
        rethrow;
      }
    } catch (error) {
      if (!prefetch && !_sourceCancelled(epoch, ownerUri, prefetch)) {
        _status.value = 'Could not open track: $error';
      }
      rethrow;
    } finally { if (!progressOwnsWatch) await sourceWatch?.cancel(); }
  }

  void _check(int epoch) {
    _ownerCancellation?.throwIfCancelled();
    if (_closed || epoch != _epoch) throw StateError('Spotify session changed');
  }

  @override Future<void> cancelSignIn() async {
    await _retire();
    if (!_closed) _status.value = 'Sign in to listen';
  }

  @override Future<void> signOut() async {
    try { await cancelSignIn(); }
    finally {
      await _vaultWrites.catchError((Object _) {});
      await _sessionVault.delete();
    }
  }

  Future<void> _retire() async {
    _epoch++;
    _sessionToken.cancel(http.RequestAbortedException());
    _musicKeyClientState?.cancellation.cancel(http.RequestAbortedException());
    _musicKeyClientState = null;
    _httpProtocols.clear();
    _rendererCors?.clear(); _rendererCors = null;
    _canary?.close(); _canary = null;
    _lastCanaryAudioLoad = null;
    final publisher = _connectStatePublisher;
    _connectStatePublisher = null;
    await publisher?.close();
    _connectReportingError = null;
    _pushOpening = null;
    final pushConnection = _pushConnection;
    _pushConnection = null;
    final callback = _callback, ap = _ap, packets = _apPackets, mediaCache = _mediaCache,
      preparedAudio = _preparedAudio, connectingAp = _connectingAp,
      connectingPackets = _connectingApPackets;
    _audioKeys?.close(); _audioKeys = null;
    _audioFilesCache.clear();
    _imageProjectionMap = null;
    _connectingAp = null; _connectingApPackets = null; _reconnectingAp = null;
    _apSessionInvalidated = false;
    _nativeOrigins.clear();
    _mediaCache = null;
    _preparedAudio = null;
    _lastMusicLicenseFailure = null;
    _musicLicenseAttempts = 0;
    _musicLicenseResponses.clear();
    _musicLicensePurposeResponses.clear();
    _sourceStartupTimings.clear();
    _callback = null; _ap = null; _apPolicy = null; _apPackets = null;
    _tokens?.close(); _tokens = null;
    _nativeStoredCredentials = null;
    _clientTokens?.close(); _clientTokens = null;
    _credentials = null; _grant = null; _endpoints = const []; _search = null; _home = null; _entities = null; _library = null;
    _savedTracksRepository = null;
    _collections.clear();
    _lyrics = null;
    _libraryImageUrlTemplate = null;
    _proofs = null; _refreshState = null; _audioMetadata = null;
    _trackMetadata.clear(); _signedMediaUrls.clear();
    for (final job in _trackDescriptionJobs.values.toSet()) { job.token.cancel(); }
    _trackDescriptions.clear();
    _trackDescriptionExpiry.clear(); _trackDescriptionJobs.clear();
    _serverArtwork.clear(); _serverArtworkById.clear(); _playlistPresentations.clear();
    _playlistArtworkJobs.clear(); _playlistArtworkRetryAfter.clear();
    for (var index = 0; index < _playlistArtworkLanes.length; index++) {
      _playlistArtworkLanes[index] = Future<void>.value();
    }
    if (!_closed) _artworkChanges.notifyListeners();
    for (final key in _keys.toList()) { key.cancel(); }
    for (final request in _requests.toList()) { request.close(); }
    _requests.clear();
    _http2?.close(); _http2 = null;
    for (final request in _http3Requests.toList()) { request.close(); }
    _http3Requests.clear();
    _http3?.close(); _http3 = null;
    await pushConnection?.close();
    for (final request in _rendererRequests.toList()) { request.close(); }
    _rendererRequests.clear();
    _rendererHttp2?.close(); _rendererHttp2 = null;
    for (final request in _rendererHttp3Requests.toList()) { request.close(); }
    _rendererHttp3Requests.clear();
    _rendererHttp3?.close(); _rendererHttp3 = null;
    for (final request in _cdnRequests.toList()) { request.close(); }
    _cdnRequests.clear();
    _cdnPool?.close(); _cdnPool = null;
    await preparedAudio?.close();
    await (await mediaCache)?.close();
    await callback?.close();
    await ap?.close();
    await connectingAp?.close();
    await connectingPackets?.cancel();
    await packets?.cancel();
    final engine = _engine;
    if (engine != null) { await engine.command('unload'); }
  }

  @override Future<void> close() async {
    if (_closed) return;
    try { if (!_sessionToken.isCancelled) await _persistSession(); }
    finally {
      _closed = true;
      try {
        await _canaryEvents?.cancel(); _canaryEvents = null;
        await _retire();
        await stopNativePlayPlayMusicKeyWarmUp();
        _clock.stop();
        _imageClient?.close();
        _images.clear();
        _artworkChanges.dispose();
        _status.dispose();
      } finally { await retireStreamingCacheDirectory(_streamingCache); }
    }
  }
}

class _AuthenticatedEntityRepository implements EntityRepository {
  const _AuthenticatedEntityRepository(this.repository, this.prepare, this.observe,
    {this.playlistRepository, this.trackRepository, this.artistRepository});
  final EntityRepository repository;
  final EntityRepository? playlistRepository, trackRepository, artistRepository;
  final Future<void> Function({CancellationToken? cancellationToken}) prepare;
  final void Function(List<EntityRow>) observe;
  @override Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    final album = uri.startsWith('spotify:album:');
    final artist = uri.startsWith('spotify:artist:') || uri.startsWith('spotify:app:artist:');
    final selected = album ? repository : uri.startsWith('spotify:track:') ? trackRepository :
      artist ? artistRepository : playlistRepository;
    if (selected == null) {
      throw const EntityQueryError({'message': 'This collection is not available yet.'});
    }
    if (album || artist) await prepare(cancellationToken: cancellationToken);
    final page = await selected.open(uri, cancellationToken: cancellationToken);
    cancellationToken?.throwIfCancelled();
    observe(page.tracks.rows);
    return page;
  }
  @override Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) async {
    final album = details.type == 'album';
    final artist = details.type == 'artist' || details.type == 'artist-section';
    final selected = album ? repository : details.type == 'track' ? trackRepository :
      artist ? artistRepository : playlistRepository;
    if (selected == null) throw const EntityQueryError({'message': 'This collection is not available yet.'});
    if (album || artist) await prepare(cancellationToken: cancellationToken);
    final page = await selected.tracks(details, offset: offset, limit: limit, cancellationToken: cancellationToken);
    observe(page.rows);
    return page;
  }
}

/// Track links reuse the already verified native TrackV4 read and its session
/// TTL. Opening a song does not start playback or resolve a streaming license.
class _NativeTrackEntityRepository implements EntityRepository {
  const _NativeTrackEntityRepository(this.describe);
  final Future<Map<String, EntityRow>> Function(List<String>, {CancellationToken? cancellationToken}) describe;
  @override Future<EntityPage> open(String uri, {CancellationToken? cancellationToken}) async {
    if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)) {
      throw const EntityQueryError({'message': 'This song is unavailable.'});
    }
    final row = (await describe([uri], cancellationToken: cancellationToken))[uri];
    if (row == null) throw const EntityQueryError({'message': 'This song is unavailable.'});
    return EntityPage(details: EntityDetails.fromJson({...row.data,
      'type': 'track', 'images': row.images, 'nrTracks': 1,
      'hasSpotifyTracks': true, 'hasEpisodes': false}, source: row.source),
      tracks: EntityTrackPage(rows: [row], offset: 0, limit: 1, totalLength: 1));
  }
  @override Future<EntityTrackPage> tracks(EntityDetails details, {required int offset, int? limit, CancellationToken? cancellationToken}) async => offset == 0 ? (await open(details.uri, cancellationToken: cancellationToken)).tracks :
    EntityTrackPage(offset: offset, limit: limit ?? 1, totalLength: 1);
}

class _AuthenticatedHomeRepository implements HomeRepository, HomeDestinationProvider {
  const _AuthenticatedHomeRepository(this.repository, this.prepare, this.observe);
  final HomeRepository repository;
  final Future<void> Function({CancellationToken? cancellationToken}) prepare;
  final void Function(HomePage) observe;
  @override HomeDestinationRepository get destinations => _AuthenticatedHomeDestinations(
    (repository as HomeDestinationProvider).destinations, prepare, observe);
  @override Future<HomePage> load({String facet = '', CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    final page = await repository.load(facet: facet, cancellationToken: cancellationToken);
    observe(page);
    return page;
  }
}

class _AuthenticatedHomeDestinations implements HomeDestinationRepository {
  const _AuthenticatedHomeDestinations(this.repository, this.prepare, this.observe);
  final HomeDestinationRepository repository;
  final Future<void> Function({CancellationToken? cancellationToken}) prepare;
  final void Function(HomePage) observe;
  @override Future<HomeDestinationPage> destination(HomeDestinationTarget target, {int offset = 0, CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    final page = await repository.destination(target, offset: offset, cancellationToken: cancellationToken);
    observe(HomePage(sections: page.sections));
    return page;
  }
}

class _AuthenticatedSearchRepository implements SearchRepository, SearchModalRepository, FullSearchRepository {
  const _AuthenticatedSearchRepository(this.repository, this.prepare, this.observe);
  final SearchRepository repository;
  final Future<void> Function({CancellationToken? cancellationToken}) prepare;
  final void Function(SearchPage) observe;
  @override Future<SearchPage> suggestions(String query, {CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    final result = await repository.suggestions(query, cancellationToken: cancellationToken);
    observe(result);
    return result;
  }
  @override Future<SearchPage> recent({CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    final result = await repository.recent(cancellationToken: cancellationToken);
    observe(result);
    return result;
  }
  @override Future<SearchPage> modal(String query, {CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    final result = await (repository as SearchModalRepository).modal(query, cancellationToken: cancellationToken);
    observe(result);
    return result;
  }
  @override Future<SearchResults> results(String query, {SearchCategory? category, int offset = 0, int? limit, CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    final result = await (repository as FullSearchRepository).results(query, category: category, offset: offset, limit: limit, cancellationToken: cancellationToken);
    observe(SearchPage(query: query, items: result.items.toList(growable: false)));
    return result;
  }
  @override Future<void> removeRecent(List<String> uris, {CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    await (repository as FullSearchRepository).removeRecent(uris, cancellationToken: cancellationToken);
  }
  @override Future<void> saveRecent(List<String> uris, {CancellationToken? cancellationToken}) async {
    await prepare(cancellationToken: cancellationToken);
    await (repository as FullSearchRepository).saveRecent(uris, cancellationToken: cancellationToken);
  }
}
