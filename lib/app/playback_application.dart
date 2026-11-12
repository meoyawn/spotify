import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:cancellation_token/cancellation_token.dart';

import '../entities/models.dart';
import '../home/models.dart';
import '../library/saved_tracks_controller.dart';
import '../playback/client.dart';
import '../playback/audio_source.dart';
import '../playback/controller.dart';
import '../playback/models.dart';
import '../playback/context_player_backend.dart';
import '../playback/dart_audio_engine.dart';
import '../playback/requests.dart';
import '../playback/spotify_playback_session.dart';
import '../protocol/esperanto.dart';
import '../protocol/native_login5_credentials.dart';
import '../protocol/native_legacy_auth_codec.dart';
import '../protocol/native_legacy_auth_preferences.dart';
import '../protocol/prefs_persistence.dart';
import '../protocol/prefs_store.dart';
import '../protocol/native_renderer_image.dart';
import '../protocol/generated/es_prefs.pb.dart' as prefs;
import '../search/models.dart';
import 'app.dart';
import 'app_scale.dart';
import 'artwork.dart';
import 'app_runtime.dart';
import 'desktop_media_controls.dart';
import 'desktop_host.dart';
import 'desktop_tray.dart';
import 'shell.dart';
import 'native_desktop_runtime.dart';
import 'navigation.dart';
import 'playback_bar.dart';
import 'settings_dialog.dart';
import 'snack_bar.dart';
import 'track_save_button.dart';

/// Application composition: the existing Flutter controller uses a real
/// Dart playback owner through the local ContextPlayer dispatcher.
class SpotifyPlaybackApplication extends StatefulWidget {
  const SpotifyPlaybackApplication({super.key, this.resolveSpotifySource,
    this.playbackSession, this.runtimeFactory = NativeDesktopRuntime.open});
  final SpotifyAudioSourceResolver? resolveSpotifySource;
  /// Optional fully configured owner; this root closes it with the application.
  final SpotifyPlaybackSession? playbackSession;
  final SpotifyAppRuntimeFactory runtimeFactory;

  @override
  State<SpotifyPlaybackApplication> createState() => _SpotifyPlaybackApplicationState();
}

class _SpotifyPlaybackApplicationState extends State<SpotifyPlaybackApplication> {
  final _shell = GlobalKey<SpotifyDesktopShellState>();
  final _navigator = GlobalKey<NavigatorState>();
  final _scale = GlobalKey<DesktopAppScaleState>();
  ContextPlayerBackend? _backend;
  PlaybackController? _controller;
  StreamSubscription<Object>? _errors;
  StreamSubscription<Object>? _resumeStates;
  SharedPreferences? _settings;
  Timer? _resumeTimer;
  Future<void> _resumeWrites = Future<void>.value();
  Map<String, Object?>? _pendingResume;
  bool _restoreAttempted = false;
  PrefsStore? _store;
  PrefsPersistence? _persistence, _playerPersistence;
  NativeLegacyAuthPreferences? _credentials;
  SpotifyAppRuntime? _runtime;
  SavedTracksController? _savedTracks;
  DesktopTray? _tray;
  Future<void>? _trayOpening;
  DesktopMediaControls? _mediaControls;
  bool _mediaSessionReady = false;
  Future<void>? _mediaOpening;
  final _codec = NativeLegacyAuthCodec();
  String? _deviceId;
  String? _initializationError;
  Future<void>? _opening;
  double _volume = 1;
  double _volumeBehindMute = 0.35;
  bool _signingIn = false;
  bool _settingsOpen = false;
  bool _openLinkOpen = false;
  int _playSelectionRevision = 0;
  CancellationToken? _applicationCancellation;
  CancellationToken get _lifetime => _applicationCancellation ??= CancellationToken();
  CancellationToken? _playSelectionCancellation;
  CancellationToken? _signInCancellation;
  final _openLinkDialog = GlobalKey<_OpenSpotifyLinkDialogState>();
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleSearchShortcut);
    FocusManager.instance.addEarlyKeyEventHandler(_handlePlayPauseShortcut);
    _opening = _initialize();
  }

  bool _handleSearchShortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!mounted || event is KeyUpEvent || !keyboard.isMetaPressed ||
        keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isShiftPressed) return false;
    final search = event.logicalKey == LogicalKeyboardKey.keyL ||
      event.physicalKey == PhysicalKeyboardKey.keyL;
    final quickSearch = event.logicalKey == LogicalKeyboardKey.keyK ||
      event.physicalKey == PhysicalKeyboardKey.keyK;
    if (!search && !quickSearch) return false;
    if (event is KeyDownEvent) {
      if (search) { _focusGlobalSearch(); }
      else { _openGlobalQuickSearch(); }
    }
    return true;
  }

  void _focusGlobalSearch() {
    _navigator.currentState?.popUntil((route) => route.isFirst);
    _shell.currentState?.focusSearch();
  }

  void _openGlobalQuickSearch() {
    unawaited(_shell.currentState?.openQuickSearch());
  }

  KeyEventResult _handlePlayPauseShortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey != LogicalKeyboardKey.space || event is KeyUpEvent ||
        keyboard.isMetaPressed || keyboard.isControlPressed ||
        keyboard.isAltPressed || keyboard.isShiftPressed) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && (focused.widget is EditableText ||
        focused.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return KeyEventResult.ignored;
    }
    final state = _controller?.state;
    if (state == null || state.item == null ||
        (state.isPaused ? !state.restrictions.canResume : !state.restrictions.canPause)) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) unawaited(_toggle());
    return KeyEventResult.handled;
  }

  Future<void> _initialize() async {
    final token = _lifetime;
    try {
      token.throwIfCancelled();
      final settings = await SharedPreferences.getInstance();
      token.throwIfCancelled();
      _settings = settings;
      final bookmark = settings.getString('playback.resume');
      if (bookmark != null) {
        try { _pendingResume = (jsonDecode(bookmark) as Map).cast<String, Object?>(); }
        on FormatException { /* Ignore an incomplete app-owned bookmark. */ }
        on TypeError { /* Ignore an older or invalid app-owned bookmark. */ }
      }
      if (!mounted) return;
      _deviceId = settings.getString('playback.device_id');
      if (_deviceId == null) {
        final random = Random.secure();
        final bytes = List.generate(16, (_) => random.nextInt(256));
        bytes[6] = (bytes[6] & 15) | 64;
        bytes[8] = (bytes[8] & 63) | 128;
        final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        _deviceId = '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
        await settings.setString('playback.device_id', _deviceId!);
        token.throwIfCancelled();
      }
      final support = await getApplicationSupportDirectory();
      token.throwIfCancelled();
      if (!mounted) return;
      final directory = Directory('${support.path}/playback');
      await directory.create(recursive: true);
      token.throwIfCancelled();
      final store = PrefsStore();
      _store = store;
      _persistence = await PrefsPersistence.open(store: store,
        file: File('${directory.path}/prefs'), scope: PrefsScope.desktop, cancellationToken: token);
      token.throwIfCancelled();
      _playerPersistence = await PrefsPersistence.open(store: store,
        file: File('${directory.path}/player-prefs'), scope: PrefsScope.authenticated, cancellationToken: token);
      token.throwIfCancelled();
      store.registerDesktopDefaults();
      // Streaming subset of original 0x101c1581c; offline preferences are deferred.
      store.register('audio.play_bitrate_enumeration', prefs.Value(number: Int64.ZERO), flags: 0x88);
      store.register('audio.play_bitrate_non_metered_enumeration', prefs.Value(number: Int64.ZERO), flags: 0x88);
      store.register('audio.allow_downgrade', prefs.Value(bool_2: true), flags: 8);
      store.register('audio.car_mode', prefs.Value(bool_2: false), flags: 8);
      _volume = ((store.get('app.player.volume').entries['app.player.volume']?.number.toInt() ?? 65535)
        / 65535).clamp(0.0, 1.0);
      if (_volume > 0) _volumeBehindMute = _volume;
      _credentials = NativeLegacyAuthPreferences(store: store, deviceId: _deviceId!);
      if (widget.playbackSession == null && widget.resolveSpotifySource == null) {
        _runtime = await widget.runtimeFactory(deviceId: _deviceId!, preferences: store,
          streamingDirectory: Directory('${directory.path}/streaming'), cancellationToken: token);
        token.throwIfCancelled();
        if (!mounted) return;
        _runtime!.status.addListener(_runtimeChanged);
        _syncSavedTracks();
      }
      await _initializeBackend();
      if (!mounted) return;
    } catch (error) {
      if (token.isCancelled) return;
      if (mounted) setState(() => _initializationError = '$error');
    }
  }

  Future<void> _initializeBackend() async {
    final token = _lifetime;
    token.throwIfCancelled();
    final runtime = _runtime;
    final engine = await DartAudioEngine.open(volume: _volume,
      resolveSpotifyRequest: runtime is NativeDesktopRuntime ? runtime.resolvePlayback : null,
      resolveSpotifySource: _runtime?.resolve ?? widget.playbackSession?.resolve ?? widget.resolveSpotifySource);
    final backend = ContextPlayerBackend(engine);
    final dispatcher = EsperantoDispatcher();
    backend.register(dispatcher);
    final controller = PlaybackController(ContextPlayerClient(dispatcher));
    if (!mounted || token.isCancelled) { await backend.close(); return; }
    widget.playbackSession?.bindEngine(engine);
    _runtime?.bindEngine(engine);
    if (_runtime case final NativeDesktopRuntime native) native.bindContextPlayer(backend);
    _errors = controller.errors.listen(_playbackFailed);
    setState(() {
      _backend = backend;
      _controller = controller;
      _initializationError = null;
    });
    controller.start();
    _watchResume();
    unawaited(_restorePlayback());
    unawaited(_ensureTray());
    unawaited(_ensureMediaControls());
  }

  void _watchResume() {
    unawaited(_resumeStates?.cancel());
    _resumeStates = _controller?.states.listen((state) {
      if (state.item == null || state.isBuffering) return;
      if (state.isPaused) {
        _resumeTimer?.cancel(); _resumeTimer = null;
        unawaited(_saveResume());
      } else {
        _resumeTimer ??= Timer(const Duration(seconds: 5), () {
          _resumeTimer = null;
          unawaited(_saveResume());
        });
      }
    });
  }

  Future<void> _saveResume() async {
    final settings = _settings ??= await SharedPreferences.getInstance();
    final runtime = _runtime, bookmark = _backend?.resumeBookmark();
    if (runtime?.ready != true || bookmark == null) return;
    final value = jsonEncode({'username': runtime!.username, 'player': bookmark,
      'location': _shell.currentState?.widget.route.location ?? '/'});
    _resumeWrites = _resumeWrites.catchError((Object _) {}).then((_) async {
      await settings.setString('playback.resume', value);
    });
    try { await _resumeWrites; }
    catch (error) { debugPrint('Playback bookmark could not be saved: $error'); }
  }

  List<Map<String, Object?>> _artworkSources(String uri, List<Map<String, Object?>> supplied) {
    final runtime = _runtime;
    return runtime is NativeDesktopRuntime ? runtime.artworkSources(uri, supplied) : supplied;
  }

  Widget _artwork(String uri, List<Map<String, Object?>> supplied, {bool round = false,
      Alignment alignment = Alignment.center, double borderRadius = 4}) {
    final runtime = _runtime!;
    Widget image() {
      final images = _artworkSources(uri, supplied);
      return SpotifyArtwork(key: ValueKey(uri), images: images,
        prepare: runtime is NativeDesktopRuntime && runtime.ready && images.isEmpty && uri.startsWith('spotify:playlist:')
          ? (token) => runtime.ensurePlaylistArtwork(uri, supplied, cancellationToken: token) : null,
        load: runtime.artwork, round: round, alignment: alignment, borderRadius: borderRadius);
    }
    // Server-provided alternatives can arrive through another view after this
    // image already failed. Rebuild this image when those actual choices change.
    return runtime is NativeDesktopRuntime
      ? ListenableBuilder(listenable: runtime.artworkChanges, builder: (_, _) => image()) : image();
  }

  Future<Uint8List?> _mediaArtwork(PlaybackItem item, {CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final runtime = _runtime;
    if (runtime == null) return null;
    final images = _artworkSources(item.uri, item.images);
    final source = nativeRendererImageSources(images, width: 512, height: 512,
      devicePixelRatio: 1).firstOrNull;
    final url = source?['url'];
    return url is String && url.isNotEmpty ? runtime.artwork(url, cancellationToken: cancellationToken) : null;
  }

  Future<void> _restorePlayback() async {
    if (_lifetime.isCancelled) return;
    final runtime = _runtime, backend = _backend;
    if (_restoreAttempted || backend == null || runtime?.ready != true) return;
    _restoreAttempted = true;
    final bookmark = _pendingResume;
    _pendingResume = null;
    if (bookmark == null || bookmark['username'] != runtime!.username || _controller?.state?.item != null) return;
    try {
      await backend.restoreBookmark((bookmark['player'] as Map).cast<String, Object?>());
      _lifetime.throwIfCancelled();
      final location = bookmark['location'];
      final shell = _shell.currentState;
      if (shell != null && location is String && location.startsWith('/')) {
        shell.widget.navigation.go(DesktopRoute.fromUri(Uri.parse(location)));
      }
    } catch (error) { if (!_lifetime.isCancelled) debugPrint('Playback bookmark could not be restored: $error'); }
  }

  Future<void> _ensureTray() {
    if (_lifetime.isCancelled) return Future<void>.value();
    final pending = _trayOpening;
    if (pending != null) return pending;
    if (_tray != null) return Future<void>.value();
    late final Future<void> opening;
    opening = _openTray().whenComplete(() {
      if (identical(_trayOpening, opening)) _trayOpening = null;
    });
    return _trayOpening = opening;
  }

  Future<void> _openTray() async {
    final controller = _controller;
    if (!mounted || controller == null || _tray != null) return;
    try {
      final tray = await DesktopTray.open(controller: controller, toggle: _toggle,
        previous: () => _skip(next: false), next: () => _skip(next: true),
        cancellationToken: _lifetime,
        onError: (error) => _notice(_failure('Menu bar action failed', error)));
      if (!mounted || _lifetime.isCancelled) { await tray?.close(); return; }
      _tray = tray;
    } catch (error) {
      // A tray failure must not retire an authenticated playback session.
      if (!_lifetime.isCancelled) debugPrint('Spotify menu bar icon: $error');
    }
  }

  Future<void> _ensureMediaControls() {
    if (_lifetime.isCancelled) return Future<void>.value();
    final pending = _mediaOpening;
    if (pending != null) return pending;
    if (_mediaControls != null) return Future<void>.value();
    late final Future<void> opening;
    opening = _openMediaControls().whenComplete(() {
      if (identical(_mediaOpening, opening)) _mediaOpening = null;
    });
    return _mediaOpening = opening;
  }

  Future<void> _openMediaControls() async {
    final controller = _controller;
    if (!mounted || controller == null || _mediaControls != null) return;
    try {
      final controls = await DesktopMediaControls.open(controller: controller, toggle: _toggle,
        loadArtwork: _mediaArtwork, cancellationToken: _lifetime,
        onError: (error) => _notice(_failure('Media control failed', error)));
      if (!mounted || _lifetime.isCancelled) { await controls?.close(); return; }
      _mediaControls = controls;
    } catch (error) { if (!_lifetime.isCancelled) debugPrint('Spotify media controls: $error'); }
  }

  @override
  void reassemble() {
    super.reassemble();
    _syncSavedTracks();
    HardwareKeyboard.instance.removeHandler(_handleSearchShortcut);
    HardwareKeyboard.instance.addHandler(_handleSearchShortcut);
    FocusManager.instance.removeEarlyKeyEventHandler(_handlePlayPauseShortcut);
    FocusManager.instance.addEarlyKeyEventHandler(_handlePlayPauseShortcut);
    final runtime = _runtime, engine = _backend?.engine;
    if (runtime is NativeDesktopRuntime && engine is DartAudioEngine) {
      runtime.bindEngine(engine);
      runtime.bindContextPlayer(_backend!);
      engine.bindSpotifyRequestResolver(runtime.resolvePlayback);
    }
    _watchResume();
    unawaited(_saveResume());
    if (_tray == null) {
      unawaited(_ensureTray());
    }
    if (_mediaControls == null) { unawaited(_ensureMediaControls()); }
    else { _mediaControls!.refresh(); }
  }

  void _runtimeChanged() {
    _syncSavedTracks();
    final ready = _runtime?.ready == true;
    if (ready && _runtime is NativeDesktopRuntime && _backend != null) {
      (_runtime as NativeDesktopRuntime).bindContextPlayer(_backend!);
    }
    if (ready && !_mediaSessionReady) _mediaControls?.refresh(reloadArtwork: true);
    _mediaSessionReady = ready;
    if (mounted) setState(() {});
    unawaited(_restorePlayback());
  }

  void _syncSavedTracks() {
    final repository = _runtime?.savedTracksRepository;
    if (identical(repository, _savedTracks?.repository)) return;
    _savedTracks?.dispose();
    _savedTracks = repository == null ? null : SavedTracksController(repository);
  }

  Widget _trackSaveButton(BuildContext context, String uri) {
    final controller = _savedTracks;
    if (controller == null || !SavedTracksController.supports(uri)) return const SizedBox.shrink();
    return TrackSaveButton(controller: controller, uri: uri,
      onError: (error) => _notice(_failure('Could not update Liked Songs', error)));
  }

  String _failure(String action, Object error) {
    final detail = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return detail.isEmpty ? '$action.' : '$action: $detail';
  }

  void _notice(String message) {
    final context = _navigator.currentContext;
    if (context == null || !context.mounted || !mounted) return;
    showSpotifySnackBar(context, message);
  }

  void _playbackFailed(Object error) {
    final detail = error is PlaybackServiceException ? error.reasons.join(' ') : '';
    final message = detail.contains('stream_connection') ? 'The music connection was interrupted. Try this track again.'
      : detail.contains('stream_timeout') ? 'The music server took too long to respond. Try again.'
      : detail.contains('unavailable') ? 'This track is unavailable for your account.'
      : 'This track couldn’t start playing. Try again.';
    final context = _navigator.currentContext;
    if (!mounted || context == null || !context.mounted) return;
    showSpotifySnackBar(context, message,
      action: SnackBarAction(label: 'Retry', onPressed: () => unawaited(_retryPlayback())));
  }

  Future<void> _retryPlayback() async {
    try { await _controller?.resume(); }
    catch (error) { _playbackFailed(error); }
  }

  Future<void> _openLink() async {
    if (_openLinkOpen) { _openLinkDialog.currentState?.focusInput(); return; }
    _openLinkOpen = true;
    String? uri;
    try {
      await _opening;
      final context = _navigator.currentContext;
      if (context == null || !context.mounted || !mounted) return;
      final route = DialogRoute<String>(context: context,
        builder: (_) => _OpenSpotifyLinkDialog(key: _openLinkDialog));
      try { uri = await Navigator.of(context, rootNavigator: true).push(route); }
      finally { await route.completed; }
    } finally { _openLinkOpen = false; }
    if (uri == null || uri.trim().isEmpty || !mounted) return;
    await _playUri(uri.trim());
  }

  String _audioUri(String input) {
    if (RegExp(r'^spotify:(track|episode):[A-Za-z0-9]{22}$').hasMatch(input)) return input;
    final link = Uri.tryParse(input);
    if (link != null && const {'http', 'https'}.contains(link.scheme) &&
        const {'open.spotify.com', 'play.spotify.com'}.contains(link.host)) {
      final parts = link.pathSegments.where((part) => part.isNotEmpty).toList();
      if (parts.isNotEmpty && parts.first.startsWith('intl-')) parts.removeAt(0);
      if (parts.length == 2 && const {'track', 'episode'}.contains(parts.first) &&
          RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(parts.last)) {
        return 'spotify:${parts.first}:${parts.last}';
      }
    }
    throw const FormatException('Open a Spotify track or episode link.');
  }

  Future<void> _playUri(String value) async {
    _playSelectionCancellation?.cancel();
    final token = _playSelectionCancellation = CancellationToken();
    final revision = ++_playSelectionRevision;
    try {
      await _opening?.asCancellable(token);
      token.throwIfCancelled();
      if (!mounted || revision != _playSelectionRevision) return;
      final runtime = _runtime;
      if (runtime != null && !runtime.ready) {
        _notice('Log in to Spotify before playing.');
        return;
      }
      final backend = _backend;
      if (backend == null) throw StateError(_initializationError ?? 'Playback is still starting');
      await backend.playUri(_audioUri(value));
    } on CancelledException { return; }
    catch (error) { if (revision == _playSelectionRevision) _notice(_failure('Could not play this item', error)); }
  }

  void _selectSearch(SearchItem item) {
    if ((item.type == 'track' || item.type == 'episode') && item.isPlayable != false) {
      unawaited(_playUri(item.uri));
    }
  }

  void _selectHome(HomeItem item) {
    if ((item.type == 'track' || item.type == 'episode') && item.isPlayable != false) {
      unawaited(_playUri(item.uri));
    }
  }

  void _playSearchItem(SearchItem item) {
    if (const {'track', 'episode'}.contains(item.type)) {
      unawaited(_playUri(item.uri));
    } else if (const {'album', 'playlist'}.contains(item.type)) {
      unawaited(_playEntity(EntityPlaybackSelection(entity:
        EntityDetails.fromJson({'uri': item.uri, 'type': item.type}))));
    } else {
      _notice('Playback of this collection is not available yet.');
    }
  }

  Future<void> _playEntity(EntityPlaybackSelection selection) async {
    _playSelectionCancellation?.cancel();
    final token = _playSelectionCancellation = CancellationToken();
    final revision = ++_playSelectionRevision;
    try {
      await _opening?.asCancellable(token);
      token.throwIfCancelled();
      if (!mounted || revision != _playSelectionRevision) return;
      final runtime = _runtime, controller = _controller;
      if (runtime == null || !runtime.ready || controller == null) {
        _notice('Log in to Spotify before playing.');
        return;
      }
      var sourceRows = selection.rows;
      if (sourceRows == null) {
        final repository = runtime.entityRepository;
        if (repository == null) throw StateError('This collection is currently unavailable');
        sourceRows = (await repository.open(selection.entity.uri, cancellationToken: token)).tracks.rows;
      }
      if (!mounted || revision != _playSelectionRevision || !identical(runtime, _runtime) || !runtime.ready) return;
      List<EntityRow> loadedRows = sourceRows;
      if (selection.entity.type == 'artist' && loadedRows.length < selection.entity.trackCount) {
        final repository = runtime.entityRepository!;
        var cursor = loadedRows.length;
        while (cursor < selection.entity.trackCount) {
          token.throwIfCancelled();
          final page = await repository.tracks(selection.entity, offset: cursor, cancellationToken: token);
          if (!mounted || revision != _playSelectionRevision || !identical(runtime, _runtime) || !runtime.ready) return;
          if (page.rows.isEmpty) break;
          loadedRows = [...loadedRows, ...page.rows];
          cursor = page.nextOffset ?? cursor + page.rows.length;
        }
      }
      final rows = loadedRows.where((row) => row.isSupported && row.canRequestPlayback && !row.isDisc).toList();
      if (rows.isEmpty) throw StateError('No playable tracks are available in this collection');
      final selected = selection.row;
      var selectedIndex = selected == null ? 0 : rows.indexOf(selected);
      if (selectedIndex < 0 && selected != null) {
        selectedIndex = rows.indexWhere((row) => row.playbackUri == selected.playbackUri &&
          (selected.uid == null || row.uid == selected.uid));
      }
      if (selectedIndex < 0) throw StateError('This track is unavailable in the collection');
      token.throwIfCancelled();
      await controller.play(PlaybackContext(selection.contextUri, pages: [PlaybackPage(items: [
        for (final row in rows) PlaybackItemReference(row.playbackUri, uid: row.uid,
          metadata: _entityPlaybackMetadata(row, selection.entity)),
      ])]), PlaybackOrigin(viewURI: selection.entity.uri),
        options: PlaybackOptions(skipTo: PlaybackSkipTarget(index: selectedIndex)));
    } on CancelledException { return; }
    catch (error) { if (revision == _playSelectionRevision) _notice(_failure('Could not play this collection', error)); }
  }

  Map<String, String> _entityPlaybackMetadata(EntityRow row, EntityDetails entity) {
    final album = row.album ?? (entity.type == 'album' ? entity.data : null);
    // A playlist cover or artist portrait is not the song's album cover.
    final images = row.images.isNotEmpty ? row.images : entity.type == 'album' ? entity.images : const <EntityJson>[];
    return {'title': row.name,
      'original_uri': row.uri,
      ...row.playbackArtistMetadata,
      if (album?['uri'] case final String uri) 'album_uri': uri,
      if (album?['name'] case final String name) 'album_title': name,
      if (row.durationMs != null) 'duration': '${row.durationMs}',
      if (images.firstOrNull?['url'] case final String image) 'image_url': image};
  }

  Future<void> _connect() async {
    await _opening;
    if (!mounted || _signingIn || _signingOut) return;
    final runtime = _runtime;
    if (runtime != null) {
      final token = CancellationToken();
      _signInCancellation = token;
      setState(() => _signingIn = true);
      try {
        await runtime.signIn(cancellationToken: token);
        token.throwIfCancelled();
        if (runtime.ready) {
          await const DesktopHost().showWindow(cancellationToken: token);
          token.throwIfCancelled();
          _notice('Connected to Spotify.');
        }
      } on CancelledException {
        // The Cancel button retires the actual runtime sign-in owner.
      } catch (error) {
        if (!token.isCancelled) _notice(_failure('Spotify sign-in could not be completed', error));
      } finally {
        if (identical(_signInCancellation, token)) {
          _signInCancellation = null;
          if (mounted) setState(() => _signingIn = false);
        }
      }
      return;
    }
    final session = widget.playbackSession;
    if (session != null) {
      if (!mounted || _signingIn) return;
      final token = CancellationToken();
      _signInCancellation = token;
      setState(() => _signingIn = true);
      try {
        final credential = await _requestCredential();
        token.throwIfCancelled();
        if (credential == null || !mounted) return;
        await session.authenticate(credential, cancellationToken: token);
        token.throwIfCancelled();
        _notice('Connected to Spotify.');
      } on CancelledException {
        // The session propagates cancellation to its authentication exchange.
      } catch (error) {
        if (!token.isCancelled) _notice(_failure('Spotify sign-in could not be completed', error));
      } finally {
        if (identical(_signInCancellation, token)) {
          _signInCancellation = null;
          if (mounted) setState(() => _signingIn = false);
        }
      }
      return;
    }
    final stored = _credentials?.readLegacy();
    final decoded = stored?.available == true ? _codec.decode(stored!.stored) : null;
    if (decoded == null) {
      _notice('Spotify sign-in is not connected yet.');
      return;
    }
    try {
      await _backend!.connect(username: decoded.username,
        authenticationType: decoded.authenticationType, data: decoded.data);
    } catch (_) {
      _notice('Spotify connection is not available yet.');
    }
  }

  Future<NativeLogin5Password?> _requestCredential() async {
    final context = _navigator.currentContext;
    if (context == null || !context.mounted) return null;
    final username = TextEditingController(), password = TextEditingController();
    try {
      return await showDialog<NativeLogin5Password>(context: context, builder: (context) {
        void submit() {
          if (username.text.trim().isEmpty || password.text.isEmpty) return;
          Navigator.pop(context, NativeLogin5Password(id: username.text.trim(), password: password.text));
        }
        return AlertDialog(title: const Text('Log in to Spotify'),
          content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: username, autofocus: true, decoration: const InputDecoration(labelText: 'Username or email')),
            TextField(controller: password, obscureText: true, enableSuggestions: false, autocorrect: false,
              decoration: const InputDecoration(labelText: 'Password'), onSubmitted: (_) => submit()),
          ])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Log in'))]);
      });
    } finally {
      password.clear();
      username.dispose(); password.dispose();
    }
  }

  Future<void> _signOut() async {
    await _opening;
    if (!mounted || _signingOut) return;
    setState(() => _signingOut = true);
    final username = _runtime?.username;
    _playSelectionCancellation?.cancel();
    _playSelectionRevision++;
    _resumeTimer?.cancel(); _resumeTimer = null;
    _pendingResume = null;
    try {
      try { await _backend?.clearSession(); }
      finally {
        try {
          if (_runtime case final runtime?) { await runtime.signOut(); }
          else { await widget.playbackSession?.signOut(); }
        } finally {
          if (username != null) { _credentials?.setEnabled(username, false); }
          await _resumeWrites.catchError((Object _) {});
          await _settings?.remove('playback.resume');
        }
      }
      await _mediaControls?.clearArtwork();
      _shell.currentState?.widget.navigation.reset(DesktopRoute.fromUri(Uri.parse('/')));
      _notice('Logged out of Spotify.');
    } catch (error) { _notice(_failure('Spotify logout could not be completed', error)); }
    finally {
      _syncSavedTracks();
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Future<void> _cancelSignIn() async {
    if (_signInCancellation case final token?) { token.cancel(); return; }
    try { await _runtime?.cancelSignIn(); }
    catch (error) { _notice(_failure('Could not cancel sign-in', error)); }
  }

  Future<void> _setVolume(double volume) async {
    try {
      await _backend?.setVolume(volume);
      _store?.set({'app.player.volume': prefs.Value(number: Int64((volume * 65535).round()))});
      if (volume > 0) _volumeBehindMute = volume;
      if (mounted) setState(() => _volume = volume);
    } catch (_) { _notice('Volume could not be changed.'); }
  }

  Future<void> _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    try {
      await _opening;
      final context = _navigator.currentContext, store = _store;
      if (!mounted || context == null || !context.mounted || store == null) return;
      int quality(String key) => store.get(key).entries[key]?.number.toInt() ?? 0;
      await showDialog<void>(context: context, builder: (context) => DesktopSettingsDialog(
        volume: _volume, streamingQuality: quality('audio.play_bitrate_non_metered_enumeration'),
        meteredQuality: quality('audio.play_bitrate_enumeration'),
        onVolumeChanged: (value) => unawaited(_setVolume(value)),
        onQualityChanged: (key, value) => store.set({key: prefs.Value(number: Int64(value))}),
        onLastFmSettings: () => unawaited(_openLastFmSettings()),
      ));
    } finally { _settingsOpen = false; }
  }

  Future<void> _openLastFmSettings() async {
    try { await const DesktopHost().openExternalUrl('https://www.last.fm/settings/applications', cancellationToken: _lifetime); }
    catch (_) { _notice('Could not open Last.fm.'); }
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      if (controller.state?.isPaused == false) { await controller.pause(); }
      else { await controller.resume(); }
    } catch (_) { _notice('Playback is not available.'); }
  }

  Future<void> _skip({required bool next}) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      if (next) { await controller.skipNext(); }
      else { await controller.skipPrevious(); }
    } catch (_) { _notice('No other track is available.'); }
  }

  @override
  void dispose() {
    _lifetime.cancel();
    _playSelectionCancellation?.cancel();
    _signInCancellation?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleSearchShortcut);
    FocusManager.instance.removeEarlyKeyEventHandler(_handlePlayPauseShortcut);
    _runtime?.status.removeListener(_runtimeChanged);
    _savedTracks?.dispose(); _savedTracks = null;
    unawaited(_closeResources());
    super.dispose();
  }

  Future<void> _closeResources() async {
    await _opening;
    _resumeTimer?.cancel();
    await _saveResume();
    await _resumeStates?.cancel();
    await _trayOpening;
    await _tray?.close();
    await _mediaOpening;
    await _mediaControls?.close();
    await _errors?.cancel();
    await _controller?.close();
    try {
      await _runtime?.close();
      await widget.playbackSession?.close();
    }
    finally { await _backend?.close(); }
    await _persistence?.close();
    await _playerPersistence?.close();
    await _store?.close();
  }

  @override
  Widget build(BuildContext context) => PlatformMenuBar(menus: [
    PlatformMenu(label: 'Spotify', menus: [
      PlatformMenuItemGroup(members: [
        PlatformMenuItem(label: 'Settings…', shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
          onSelected: _openSettings),
      ]),
      PlatformMenuItem(label: 'Log out', onSelected: !_signingOut &&
        (_runtime?.ready == true || widget.playbackSession != null) ? _signOut : null),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
      ]),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
      ]),
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
    ]),
    PlatformMenu(label: 'File', menus: [
      PlatformMenuItemGroup(members: [PlatformMenuItem(label: 'Open Spotify Link…',
          onSelected: _openLink)]),
      PlatformMenuItem(label: 'Close Window',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyW, meta: true),
        onSelected: () => const DesktopHost().closeWindow()),
    ]),
    const PlatformMenu(label: 'Edit', menus: [
      PlatformMenuItemGroup(members: [
        PlatformMenuItem(label: 'Undo',
          shortcut: SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
          onSelectedIntent: UndoTextIntent(SelectionChangedCause.keyboard)),
        PlatformMenuItem(label: 'Redo',
          shortcut: SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
          onSelectedIntent: RedoTextIntent(SelectionChangedCause.keyboard)),
      ]),
      PlatformMenuItemGroup(members: [
        PlatformMenuItem(label: 'Cut',
          shortcut: SingleActivator(LogicalKeyboardKey.keyX, meta: true),
          onSelectedIntent: CopySelectionTextIntent.cut(SelectionChangedCause.keyboard)),
        PlatformMenuItem(label: 'Copy',
          shortcut: SingleActivator(LogicalKeyboardKey.keyC, meta: true),
          onSelectedIntent: CopySelectionTextIntent.copy),
        PlatformMenuItem(label: 'Paste',
          shortcut: SingleActivator(LogicalKeyboardKey.keyV, meta: true),
          onSelectedIntent: PasteTextIntent(SelectionChangedCause.keyboard)),
        PlatformMenuItem(label: 'Select All',
          shortcut: SingleActivator(LogicalKeyboardKey.keyA, meta: true),
          onSelectedIntent: SelectAllTextIntent(SelectionChangedCause.keyboard)),
      ]),
    ]),
    PlatformMenu(label: 'View', menus: [
      PlatformMenuItemGroup(members: [
        PlatformMenuItem(label: 'Actual Size',
          shortcut: const SingleActivator(LogicalKeyboardKey.digit0, meta: true),
          onSelected: () => _scale.currentState?.reset()),
        PlatformMenuItem(label: 'Zoom In', shortcut: const CharacterActivator('+', meta: true),
          onSelected: () => _scale.currentState?.zoomIn()),
        PlatformMenuItem(label: 'Zoom Out',
          shortcut: const SingleActivator(LogicalKeyboardKey.minus, meta: true),
          onSelected: () => _scale.currentState?.zoomOut()),
      ]),
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
    ]),
    PlatformMenu(label: 'Search', menus: [
      PlatformMenuItem(label: 'Focus Search',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyL, meta: true),
        onSelected: _focusGlobalSearch),
      PlatformMenuItem(label: 'Quick Search…',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
        onSelected: _openGlobalQuickSearch),
    ]),
    PlatformMenu(label: 'Playback', menus: [
      PlatformMenuItem(label: 'Play / Pause', onSelected: _toggle),
      PlatformMenuItem(label: 'Previous', onSelected: () => _skip(next: false)),
      PlatformMenuItem(label: 'Next', onSelected: () => _skip(next: true)),
    ]),
    const PlatformMenu(label: 'Window', menus: [
      PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
      ]),
      PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
    ]),
  ], child: SpotifyDesktopApp(navigatorKey: _navigator, shellKey: _shell, scaleKey: _scale,
    playbackController: _controller,
    playbackArtworkBuilder: _runtime == null ? null : (context, item) => _artwork(item.uri, item.images),
    searchRepository: _runtime?.searchRepository,
    homeRepository: _runtime?.homeRepository,
    libraryRepository: _runtime?.libraryRepository,
    entityRepository: _runtime?.entityRepository,
    lyricsRepository: _runtime is NativeDesktopRuntime ? (_runtime as NativeDesktopRuntime).lyricsRepository : null,
    artworkBuilder: _runtime == null ? null : (context, item) => _artwork(item.uri, item.images,
      round: item.type == 'artist' || item.type == 'author'),
    homeArtworkBuilder: _runtime == null ? null : (context, item) => _artwork(item.uri, item.images,
      round: item.type == 'artist'),
    libraryArtworkBuilder: _runtime == null ? null : (context, item) => item.type == 'liked-songs'
      ? const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xff450af5), Color(0xffc4efd9)])),
          child: Center(child: Icon(Icons.favorite, color: Colors.white)))
      : _artwork(item.uri, item.images, round: item.type == 'artist' || item.type == 'author'),
    entityArtworkBuilder: _runtime == null ? null : (context, item) => _artwork(item.uri, item.images,
      alignment: item.data['artworkRole'] == 'header-background' ? const Alignment(0, -.7) : Alignment.center,
      borderRadius: item.data['artworkRole'] == 'header-background' ? 0 : 4),
    entityRowArtworkBuilder: _runtime == null ? null : (context, item) => _artwork(item.uri, item.images),
    entityRowActionsBuilder: _savedTracks == null ? null : (context, row) => _trackSaveButton(context, row.uri),
    trackSaveButtonBuilder: _savedTracks == null ? null : _trackSaveButton,
    onSelect: _selectSearch,
    onQuickSearchPlay: _playSearchItem,
    onHomeSelect: _selectHome,
    onEntityPlay: (selection) => unawaited(_playEntity(selection)),
    accountName: _runtime?.ready == true ? _runtime?.username : null,
    onLogOut: _runtime?.ready == true && !_signingOut ? () => unawaited(_signOut()) : null,
    onLogIn: _runtime?.ready == true || _signingOut ? null : _signingIn
      ? () => _notice(_runtime?.status.value ?? 'Signing in…') : _connect,
    playbackBuilder: (context, controller, state) {
      if (_initializationError case final error?) {
        return Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SelectableText('Playback could not start: $error', maxLines: 2,
            style: const TextStyle(color: Color(0xfff15e6c), fontSize: 12))));
      }
      final runtime = _runtime;
      if (runtime != null && !runtime.ready) {
        return Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_signingIn) const Padding(padding: EdgeInsets.only(right: 12),
              child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            Flexible(child: Text(runtime.status.value, maxLines: 2,
              style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 12))),
            if (_signingIn) TextButton(onPressed: _cancelSignIn, child: const Text('Cancel')),
          ])));
      }
      return DesktopPlaybackBar(controller: controller,
        lyricsActive: _shell.currentState?.widget.route.destination == DesktopDestination.lyrics,
        onShowLyrics: runtime is NativeDesktopRuntime && runtime.ready ? () => _shell.currentState?.openLyrics() : null,
        onNavigate: (link) => _shell.currentState?.navigateToEntity(link),
        onToggleMute: _backend == null ? null : () {
          if (_volume > 0) _volumeBehindMute = _volume;
          unawaited(_setVolume(_volume == 0 ? _volumeBehindMute : 0));
        },
        trackSaveButtonBuilder: _savedTracks == null ? null : _trackSaveButton,
        artworkBuilder: runtime == null ? null : (context, item) => _artwork(item.uri, item.images),
        onVolumeChanged: _backend == null ? null : _setVolume, volume: _volume);
    },
  ));
}

class _OpenSpotifyLinkDialog extends StatefulWidget {
  const _OpenSpotifyLinkDialog({super.key});
  @override State<_OpenSpotifyLinkDialog> createState() => _OpenSpotifyLinkDialogState();
}

class _OpenSpotifyLinkDialogState extends State<_OpenSpotifyLinkDialog> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  void focusInput() { if (mounted) _focus.requestFocus(); }
  @override void dispose() { _text.dispose(); _focus.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) => AlertDialog(
    title: const Text('Open Spotify link'),
    content: SizedBox(width: 440, child: TextField(controller: _text,
      focusNode: _focus, autofocus: true,
      decoration: const InputDecoration(hintText: 'Spotify track or episode link'),
      onSubmitted: (value) => Navigator.pop(context, value))),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('Play'))],
  );
}
