import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../entities/entities.dart';
import '../home/home.dart';
import '../library/library.dart';
import '../lyrics/repository.dart';
import '../playback/controller.dart';
import '../search/controller.dart';
import '../search/models.dart';
import '../search/repository.dart';
import '../search/view.dart';
import 'navigation.dart';
import 'playback_bar.dart';
import 'shell.dart';

/// Flutter application root. Backend ownership stays with the injecting caller.
class SpotifyDesktopApp extends StatefulWidget {
  const SpotifyDesktopApp({
    super.key,
    this.homeRepository,
    this.libraryRepository,
    this.searchRepository,
    this.entityRepository,
    this.lyricsRepository,
    this.playbackController,
    this.playbackBuilder,
    this.onSelect,
    this.onQuickSearchPlay,
    this.onHomeSelect,
    this.onOpenHomeSection,
    this.onLibrarySelect,
    this.onLibraryOpenFolder,
    this.onEntitySelect,
    this.onEntityPlay,
    this.onEntityNavigate,
    this.onLogIn,
    this.onLogOut,
    this.accountName,
    this.artworkBuilder,
    this.homeArtworkBuilder,
    this.libraryArtworkBuilder,
    this.libraryItemActionsBuilder,
    this.entityArtworkBuilder,
    this.entityRowArtworkBuilder,
    this.entityRowActionsBuilder,
    this.initialLocation = '/',
    this.navigatorKey,
    this.shellKey,
    this.playbackArtworkBuilder,
    this.trackSaveButtonBuilder,
  });

  final HomeRepository? homeRepository;
  final LibraryRepository? libraryRepository;
  final SearchRepository? searchRepository;
  final EntityRepository? entityRepository;
  final LyricsRepository? lyricsRepository;
  final PlaybackController? playbackController;
  final DesktopPlaybackBuilder? playbackBuilder;
  final ValueChanged<SearchItem>? onSelect;
  final ValueChanged<SearchItem>? onQuickSearchPlay;
  final ValueChanged<HomeItem>? onHomeSelect;
  final ValueChanged<HomeSection>? onOpenHomeSection;
  final ValueChanged<LibraryItem>? onLibrarySelect;
  final ValueChanged<LibraryItem>? onLibraryOpenFolder;
  final ValueChanged<EntityRow>? onEntitySelect;
  final ValueChanged<EntityPlaybackSelection>? onEntityPlay;
  final ValueChanged<EntityLink>? onEntityNavigate;
  final VoidCallback? onLogIn;
  final String? accountName;
  final SearchArtworkBuilder? artworkBuilder;
  final HomeArtworkBuilder? homeArtworkBuilder;
  final LibraryArtworkBuilder? libraryArtworkBuilder;
  final LibraryItemActionsBuilder? libraryItemActionsBuilder;
  final EntityArtworkBuilder? entityArtworkBuilder;
  final EntityRowArtworkBuilder? entityRowArtworkBuilder;
  final EntityRowActionsBuilder? entityRowActionsBuilder;
  final String initialLocation;
  final GlobalKey<NavigatorState>? navigatorKey;
  final GlobalKey<SpotifyDesktopShellState>? shellKey;
  final PlaybackArtworkBuilder? playbackArtworkBuilder;
  final TrackSaveButtonBuilder? trackSaveButtonBuilder;
  final VoidCallback? onLogOut;

  @override
  State<SpotifyDesktopApp> createState() => _SpotifyDesktopAppState();
}

class _SpotifyDesktopAppState extends State<SpotifyDesktopApp> {
  HomeController? _home;
  LibraryController? _library;
  DesktopSearchController? _search;
  final _entities = <String, EntityController>{};
  late final DesktopRouter _router;
  late final PlatformRouteInformationProvider _routeInformation;
  static const _desktopLinks = MethodChannel('spotify_flutter/desktop_links');
  int _linkRevision = 0;

  void _openLink(String input) {
    final route = desktopRouteForLink(input);
    if (route == null) return;
    _linkRevision++;
    FocusManager.instance.primaryFocus?.unfocus();
    _router.go(route);
  }

  Future<void> _receiveDesktopLinks() async {
    _desktopLinks.setMethodCallHandler((call) async {
      if (call.method != 'openUrl') throw MissingPluginException();
      if (!mounted || call.arguments is! String) return;
      _openLink(call.arguments as String);
    });
    final revision = _linkRevision;
    try {
      final pending = await _desktopLinks.invokeMethod<String>('takePendingUrl');
      if (mounted && revision == _linkRevision && pending != null) _openLink(pending);
    } on MissingPluginException { /* Standalone shells can have no macOS host. */ }
    on PlatformException catch (error) { debugPrint('Incoming links: ${error.code}'); }
  }

  @override
  void initState() {
    super.initState();
    final homeRepository = widget.homeRepository;
    if (homeRepository != null) _home = HomeController(homeRepository);
    final libraryRepository = widget.libraryRepository;
    if (libraryRepository != null) _library = LibraryController(libraryRepository);
    final repository = widget.searchRepository;
    if (repository != null) _search = DesktopSearchController(repository);
    _routeInformation = PlatformRouteInformationProvider(
      initialRouteInformation: RouteInformation(uri: Uri.parse(widget.initialLocation)),
    );
    _router = DesktopRouter(initialLocation: widget.initialLocation, navigatorKey: widget.navigatorKey,
      builder: (navigation, route) => SpotifyDesktopShell(
        key: widget.shellKey,
        navigation: navigation,
        route: route,
        homeController: _home,
        libraryController: _library,
        searchController: _search,
        entityController: _entityFor(route),
        playbackController: widget.playbackController,
        lyricsRepository: widget.lyricsRepository,
        playbackBuilder: widget.playbackBuilder,
        playbackArtworkBuilder: widget.playbackArtworkBuilder,
        trackSaveButtonBuilder: widget.trackSaveButtonBuilder,
        onSelect: widget.onSelect,
        onQuickSearchPlay: widget.onQuickSearchPlay,
        onHomeSelect: widget.onHomeSelect,
        onOpenHomeSection: widget.onOpenHomeSection,
        onLibrarySelect: widget.onLibrarySelect,
        onLibraryOpenFolder: widget.onLibraryOpenFolder,
        onEntitySelect: widget.onEntitySelect,
        onEntityPlay: widget.onEntityPlay,
        onEntityNavigate: widget.onEntityNavigate,
        onLogIn: widget.onLogIn,
        onLogOut: widget.onLogOut,
        accountName: widget.accountName,
        artworkBuilder: widget.artworkBuilder,
        homeArtworkBuilder: widget.homeArtworkBuilder,
        libraryArtworkBuilder: widget.libraryArtworkBuilder,
        libraryItemActionsBuilder: widget.libraryItemActionsBuilder,
        entityArtworkBuilder: widget.entityArtworkBuilder,
        entityRowArtworkBuilder: widget.entityRowArtworkBuilder,
        entityRowActionsBuilder: widget.entityRowActionsBuilder,
      ),
    );
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) unawaited(_receiveDesktopLinks());
  }

  @override
  void didUpdateWidget(SpotifyDesktopApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.homeRepository != widget.homeRepository) {
      _home?.dispose();
      final repository = widget.homeRepository;
      _home = repository == null ? null : HomeController(repository);
    }
    if (oldWidget.libraryRepository != widget.libraryRepository) {
      _library?.dispose();
      final repository = widget.libraryRepository;
      _library = repository == null ? null : LibraryController(repository);
    }
    if (oldWidget.searchRepository != widget.searchRepository) {
      _search?.dispose();
      final repository = widget.searchRepository;
      _search = repository == null ? null : DesktopSearchController(repository);
    }
    if (oldWidget.entityRepository != widget.entityRepository) _disposeEntities();
    _router.refresh();
  }

  EntityController? _entityFor(DesktopRoute route) {
    final repository = widget.entityRepository;
    final uri = route.entityUri;
    if (repository == null || uri == null) return null;
    return _entities.putIfAbsent(uri, () => EntityController(repository, uri: uri,
      onLibraryChanged: () { if (_library != null) unawaited(_library!.refresh(invalidate: false)); }));
  }

  void _disposeEntities() {
    for (final controller in _entities.values) {
      controller.dispose();
    }
    _entities.clear();
  }

  @override
  void dispose() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      _desktopLinks.setMethodCallHandler(null);
      unawaited(_desktopLinks.invokeMethod<void>('stop').catchError((Object _) {}));
    }
    _home?.dispose();
    _library?.dispose();
    _search?.dispose();
    _disposeEntities();
    _routeInformation.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: 'Spotify',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      fontFamily: 'SpotifyMixUI',
      scaffoldBackgroundColor: Colors.black,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xff1ed760), secondary: Color(0xff1ed760),
        surface: Color(0xff121212), onSurface: Colors.white,
      ),
      iconTheme: const IconThemeData(color: Color(0xffb3b3b3), size: 24),
      iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
        foregroundColor: const Color(0xffb3b3b3), disabledForegroundColor: const Color(0xff4d4d4d),
      )),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xff282828),
        contentTextStyle: TextStyle(fontFamily: 'SpotifyMixUI', color: Colors.white, fontSize: 14, height: 1.4),
        actionTextColor: Color(0xff1ed760), disabledActionTextColor: Color(0xffb3b3b3),
      ),
      tooltipTheme: const TooltipThemeData(
        textStyle: TextStyle(fontFamily: 'SpotifyMixUI', color: Colors.white, fontSize: 14),
        decoration: BoxDecoration(color: Color(0xff282828), borderRadius: BorderRadius.all(Radius.circular(4))),
      ),
    ),
    routerDelegate: _router,
    routeInformationParser: const DesktopRouteParser(),
    routeInformationProvider: _routeInformation,
    backButtonDispatcher: RootBackButtonDispatcher(),
  );
}
