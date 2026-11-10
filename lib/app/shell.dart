import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform, mapEquals;
import 'package:flutter/gestures.dart' show kPrimaryButton, kTouchSlop,
    PointerDeviceKind, PointerPanZoomStartEvent, PointerPanZoomUpdateEvent, PointerPanZoomEndEvent,
    GestureBinding, GestureArenaEntry, GestureArenaMember, GestureDisposition, HitTestResult;
import 'package:flutter/rendering.dart' show RenderViewportBase, RenderEditable;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../entities/entities.dart';
import '../home/home.dart';
import '../home/destinations_controller.dart';
import '../home/destinations_repository.dart';
import '../home/destinations_view.dart';
import '../library/library.dart';
import '../library/selection_viewport.dart';
import '../lyrics/controller.dart';
import '../lyrics/repository.dart';
import '../lyrics/view.dart';
import '../playback/controller.dart';
import '../playback/models.dart';
import '../search/controller.dart';
import '../search/models.dart';
import '../search/quick_search_dialog.dart';
import '../search/results_view.dart';
import '../search/repository.dart';
import '../search/view.dart';
import 'navigation.dart';
import 'playback_bar.dart';
import 'now_playing_panel.dart';
import 'shell_icons.dart';
import 'sidebar_resize_handle.dart';
import 'desktop_icon_button.dart';
import 'snack_bar.dart';

typedef _ShellContents = ({Widget expandedLibrary, Widget collapsedLibrary,
  Widget compactLibrary, Widget main, Widget right, Widget playback, Widget navigation});

/// Renderer hierarchy: global navigation, library/main panels, player region.
class SpotifyDesktopShell extends StatefulWidget {
  const SpotifyDesktopShell({
    super.key, required this.navigation, required this.route,
    this.homeController, this.libraryController, this.searchController, this.entityController, this.playbackController, this.playbackBuilder,
    this.lyricsRepository,
    this.onSelect, this.onHomeSelect, this.onOpenHomeSection, this.onLogIn,
    this.onQuickSearchPlay, this.onLogOut,
    this.accountName,
    this.playbackArtworkBuilder,
    this.trackSaveButtonBuilder,
    this.artworkBuilder, this.homeArtworkBuilder,
    this.onLibrarySelect, this.onLibraryOpenFolder,
    this.libraryArtworkBuilder, this.libraryItemActionsBuilder,
    this.onEntitySelect, this.onEntityPlay, this.onEntityNavigate,
    this.entityArtworkBuilder, this.entityRowArtworkBuilder, this.entityRowActionsBuilder,
  });

  final DesktopRouter navigation;
  final DesktopRoute route;
  final HomeController? homeController;
  final LibraryController? libraryController;
  final DesktopSearchController? searchController;
  final EntityController? entityController;
  final PlaybackController? playbackController;
  final LyricsRepository? lyricsRepository;
  final DesktopPlaybackBuilder? playbackBuilder;
  final ValueChanged<SearchItem>? onSelect;
  final ValueChanged<SearchItem>? onQuickSearchPlay;
  final ValueChanged<HomeItem>? onHomeSelect;
  final ValueChanged<HomeSection>? onOpenHomeSection;
  final VoidCallback? onLogIn;
  final String? accountName;
  final PlaybackArtworkBuilder? playbackArtworkBuilder;
  final TrackSaveButtonBuilder? trackSaveButtonBuilder;
  final SearchArtworkBuilder? artworkBuilder;
  final HomeArtworkBuilder? homeArtworkBuilder;
  final ValueChanged<LibraryItem>? onLibrarySelect;
  final ValueChanged<LibraryItem>? onLibraryOpenFolder;
  final LibraryArtworkBuilder? libraryArtworkBuilder;
  final LibraryItemActionsBuilder? libraryItemActionsBuilder;
  final ValueChanged<EntityRow>? onEntitySelect;
  final ValueChanged<EntityPlaybackSelection>? onEntityPlay;
  final ValueChanged<EntityLink>? onEntityNavigate;
  final EntityArtworkBuilder? entityArtworkBuilder;
  final EntityRowArtworkBuilder? entityRowArtworkBuilder;
  final EntityRowActionsBuilder? entityRowActionsBuilder;
  final VoidCallback? onLogOut;

  @override
  State<SpotifyDesktopShell> createState() => SpotifyDesktopShellState();
}

class SpotifyDesktopShellState extends State<SpotifyDesktopShell> implements GestureArenaMember {
  static const _windowHost = MethodChannel('spotify_flutter/desktop_host');
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _searchLink = LayerLink();
  final _searchPortalKey = GlobalKey();
  final _searchTapGroup = Object();
  final _suggestionsController = OverlayPortalController();
  bool _collapsed = false;
  bool _quickSearchOpen = false;
  bool _showNowPlaying = true;
  double? _libraryWidth, _nowPlayingWidth;
  bool? _resizingSidebar;
  Future<void>? _restoringSidebarWidths;
  SharedPreferences? _sidebarPreferences;
  bool? _sidebarWidthsEdited;
  ValueNotifier<int>? _sidebarSizing;
  ValueNotifier<int> get _sidebarChanges => _sidebarSizing ??= ValueNotifier(0);
  PlaybackState? _playbackState;
  StreamSubscription<PlaybackState>? _playbackStates;
  LyricsController? _lyrics;
  HomeDestinationRepository? _homeDestinationRepository;
  Map<String, HomeDestinationController>? _homeDestinations;
  _ShellContents? _contents;
  Widget? _view;
  int? _historyPointer;
  DesktopRoute? _historyStartRoute;
  Offset _historyPan = Offset.zero;
  double _historyVerticalTravel = 0, _historyDirection = 0;
  GestureArenaEntry? _historyArenaEntry;
  List<ScrollPosition> _historyHorizontalScrolls = const [];
  ValueNotifier<double>? _historyFeedback;
  ValueNotifier<double> get _historyProgress => _historyFeedback ??= ValueNotifier(0);
  bool get _macWindow => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  void _invalidateContents() {
    _contents = null;
    _view = null;
  }

  Future<void> _restoreSidebarWidths() => _restoringSidebarWidths ??= () async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      _sidebarPreferences = preferences;
      if (_sidebarWidthsEdited == true) return;
      final left = preferences.getDouble('ui.library.width');
      final right = preferences.getDouble('ui.now-playing.width');
      setState(() {
        if (left != null && left.isFinite && left >= 280) _libraryWidth = left;
        if (right != null && right.isFinite) _nowPlayingWidth = right.clamp(280, 420);
        _collapsed = preferences.getBool('ui.library.collapsed') ?? _collapsed;
      });
      _sidebarChanges.value++;
    } on MissingPluginException { /* A standalone shell can have no native preferences. */ }
    on PlatformException catch (error) { debugPrint('Sidebar preferences: ${error.message}'); }
  }();

  Future<void> _saveSidebarWidths() async {
    _sidebarWidthsEdited = true;
    try {
      final preferences = _sidebarPreferences ??= await SharedPreferences.getInstance();
      await Future.wait([
        if (_libraryWidth case final width?) preferences.setDouble('ui.library.width', width),
        if (_nowPlayingWidth case final width?) preferences.setDouble('ui.now-playing.width', width),
        preferences.setBool('ui.library.collapsed', _collapsed),
      ]);
    } on MissingPluginException { /* Resizing also works without persistence. */ }
    on PlatformException catch (error) { debugPrint('Sidebar preferences: ${error.message}'); }
  }

  void _toggleLibrary() {
    _sidebarWidthsEdited = true; _collapsed = !_collapsed;
    _sidebarChanges.value++;
    unawaited(_saveSidebarWidths());
  }

  Future<void> _startWindowDrag() async {
    try { await _windowHost.invokeMethod<void>('startWindowDrag'); }
    on MissingPluginException { /* The current runner can predate this native primitive. */ }
    on PlatformException catch (error) { debugPrint('Window drag: ${error.message}'); }
  }

  @override
  void initState() {
    super.initState();
    widget.searchController?.addListener(_syncSearch);
    _applyRoute();
    _focus.addListener(_searchFocused);
    _watchPlayback();
    _watchLyrics();
    unawaited(_restoreSidebarWidths());
    unawaited(widget.libraryController?.initialize());
  }

  @override
  void didUpdateWidget(SpotifyDesktopShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_historyStartRoute != widget.navigation.route) _cancelHistoryGesture();
    _invalidateContents();
    if (oldWidget.homeController != widget.homeController) { _disposeDestinations(); }
    if (oldWidget.playbackController != widget.playbackController) { _watchPlayback(); }
    if (oldWidget.playbackController != widget.playbackController ||
        oldWidget.lyricsRepository != widget.lyricsRepository) { _watchLyrics(); }
    if (oldWidget.libraryController != widget.libraryController) {
      unawaited(widget.libraryController?.initialize());
    }
    if (oldWidget.searchController != widget.searchController) {
      oldWidget.searchController?.removeListener(_syncSearch);
      widget.searchController?.addListener(_syncSearch);
      _applyRoute();
    } else if (oldWidget.route.location != widget.route.location) {
      _applyRoute();
    }
  }

  void _watchPlayback() {
    unawaited(_playbackStates?.cancel());
    _playbackState = widget.playbackController?.state;
    _playbackStates = widget.playbackController?.states.listen((state) {
      final previous = _playbackState;
      _playbackState = state;
      if (mounted && (previous?.item?.uri != state.item?.uri || previous?.isPaused != state.isPaused ||
          previous?.hasContext != state.hasContext || previous?.isBuffering != state.isBuffering ||
          previous?.shuffle != state.shuffle ||
          previous?.restrictions.canToggleShuffle != state.restrictions.canToggleShuffle ||
          !mapEquals(previous?.item?.metadata, state.item?.metadata))) {
        setState(_invalidateContents);
      }
    });
  }

  void _watchLyrics() {
    _lyrics?.dispose();
    final repository = widget.lyricsRepository, player = widget.playbackController;
    _lyrics = repository != null && player != null ? LyricsController(repository, player) : null;
  }

  Future<void> openLyrics() async {
    if (_lyrics == null) return;
    if (widget.route.destination == DesktopDestination.lyrics) {
      if (widget.navigation.canGoBack) widget.navigation.back();
      else _navigate(DesktopRoute.fromUri(Uri.parse('/')));
    } else {
      _navigate(DesktopRoute.fromUri(Uri.parse('/lyrics')));
    }
  }

  @override void reassemble() {
    super.reassemble();
    _invalidateContents();
    _watchPlayback();
    unawaited(_restoreSidebarWidths());
  }

  void _applyRoute() {
    if (widget.route.destination == DesktopDestination.search) {
      _setInput(widget.route.query);
      widget.searchController?.setQuery(widget.route.query, fetchSuggestions: false);
    } else {
      _syncSearch();
    }
  }

  void _setInput(String query) {
    if (_input.text == query) return;
    _input.value = TextEditingValue(text: query,
      selection: TextSelection.collapsed(offset: query.length));
  }

  void _syncSearch() {
    final controller = widget.searchController;
    if (controller != null) _setInput(controller.state.query);
  }

  void _searchFocused() {
    if (_focus.hasFocus) {
      _showSuggestions();
      unawaited(widget.searchController?.initialize());
    } else {
      if (_suggestionsController.isShowing) _suggestionsController.hide();
    }
  }

  void _showSuggestions() {
    if (desktopRouteForLink(_input.text) != null) return;
    if (widget.searchController != null && !_suggestionsController.isShowing) _suggestionsController.show();
  }

  void _dismissSuggestions({bool unfocus = false}) {
    if (_suggestionsController.isShowing) _suggestionsController.hide();
    if (unfocus) _focus.unfocus();
  }

  void _queryChanged(String query) {
    final link = desktopRouteForLink(query);
    widget.searchController?.setQuery(query, fetchSuggestions: link == null);
    if (link != null) {
      _dismissSuggestions();
      return;
    }
    if (_focus.hasFocus) _showSuggestions();
  }

  void focusSearch() {
    _focus.requestFocus();
    _input.selection = TextSelection(baseOffset: 0, extentOffset: _input.text.length);
    _showSuggestions();
  }

  Future<void> openQuickSearch() async {
    if (_quickSearchOpen) return;
    _quickSearchOpen = true;
    QuickSearchChoice? choice;
    try {
      _dismissSuggestions(unfocus: true);
      final repository = widget.searchController?.repository;
      final route = DialogRoute<QuickSearchChoice>(context: context,
        barrierColor: const Color(0x99000000), builder: (context) => QuickSearchDialog(
          repository: repository is SearchModalRepository ? repository as SearchModalRepository : null,
          artworkBuilder: widget.artworkBuilder,
          onPlay: widget.onQuickSearchPlay ?? widget.onSelect,
          canPlay: (item) => const {'track', 'episode', 'album', 'playlist'}.contains(item.type) &&
            (widget.onQuickSearchPlay != null || const {'track', 'episode'}.contains(item.type))));
      try { choice = await Navigator.of(context, rootNavigator: true).push(route); }
      finally { await route.completed; }
    } finally { _quickSearchOpen = false; }
    if (!mounted || choice == null) return;
    final item = choice.item;
    _navigate(DesktopRoute.content(choice.uri, title: item?.name,
      subtitle: item?.contributors.join(', ')));
  }

  void _navigate(DesktopRoute route) {
    _dismissSuggestions();
    _focus.unfocus();
    widget.navigation.go(route);
  }

  void _navigateHistory(bool back) {
    if (back ? !widget.navigation.canGoBack : !widget.navigation.canGoForward) return;
    _dismissSuggestions(unfocus: true);
    if (back) { widget.navigation.back(); }
    else { widget.navigation.forward(); }
  }

  void _historyGestureStart(PointerPanZoomStartEvent event) {
    _cancelHistoryGesture();
    if (!_macWindow || event.kind != PointerDeviceKind.trackpad ||
        ModalRoute.of(context)?.isCurrent != true ||
        !widget.navigation.canGoBack && !widget.navigation.canGoForward) { return; }
    _historyPointer = event.pointer;
    _historyStartRoute = widget.navigation.route;
    _historyPan = Offset.zero;
    _historyVerticalTravel = 0;
    _historyDirection = 0;
    final hits = HitTestResult();
    GestureBinding.instance.hitTestInView(hits, event.position, event.viewId);
    _historyHorizontalScrolls = [for (final hit in hits.path)
      if (switch (hit.target) {
        RenderViewportBase(offset: final ScrollPosition position) => position,
        RenderEditable(offset: final ScrollPosition position) => position,
        _ => null,
      } case final position?)
        if (position.hasContentDimensions && position.axis == Axis.horizontal) position];
    _historyArenaEntry = GestureBinding.instance.gestureArena.add(event.pointer, this);
  }

  @override
  void acceptGesture(int pointer) {
    if (_historyPointer == pointer) _historyArenaEntry = null;
  }

  @override
  void rejectGesture(int pointer) {
    if (_historyPointer == pointer) {
      _historyArenaEntry = null;
      _cancelHistoryGesture();
    }
  }

  void _cancelHistoryGesture() {
    final entry = _historyArenaEntry;
    _historyArenaEntry = null;
    _historyPointer = null;
    _historyStartRoute = null;
    _historyHorizontalScrolls = const [];
    _historyFeedback?.value = 0;
    entry?.resolve(GestureDisposition.rejected);
  }

  void _historyGestureUpdate(PointerPanZoomUpdateEvent event) {
    if (_historyPointer != event.pointer) return;
    _historyPan = event.pan;
    _historyVerticalTravel += event.panDelta.dy.abs();
    // Flutter supplies logical scroll pixels, not Chromium's normalized touches.
    // Keep its vertical-intent cancellation and direction lock in these units.
    if (_historyStartRoute != widget.navigation.route || event.scale != 1 || event.rotation != 0 ||
        _historyVerticalTravel > kTouchSlop && _historyVerticalTravel * 1.3 > _historyPan.dx.abs()) {
      _cancelHistoryGesture();
      return;
    }
    if (_historyPan.dx.abs() > kTouchSlop) {
      if (_historyDirection == 0) {
        final back = _historyPan.dx > 0;
        if (back ? !widget.navigation.canGoBack : !widget.navigation.canGoForward) {
          _cancelHistoryGesture();
          return;
        }
        // Let a shelf consume the gesture when it has content in this direction.
        for (final position in _historyHorizontalScrolls) {
          final delta = position.axisDirection == AxisDirection.left ? _historyPan.dx : -_historyPan.dx;
          if (delta < 0 && position.pixels > position.minScrollExtent ||
              delta > 0 && position.pixels < position.maxScrollExtent) {
            _cancelHistoryGesture();
            return;
          }
        }
        _historyDirection = _historyPan.dx.sign;
        // Listener runs before pointerRouter dispatch. Claim this same update
        // before a Scrollable can accept it, locking both axes until finger lift.
        _historyArenaEntry?.resolve(GestureDisposition.accepted);
      } else if (_historyDirection != _historyPan.dx.sign) {
        _cancelHistoryGesture();
        return;
      }
    }
    if (_historyDirection != 0) {
      _historyProgress.value = _historyDirection * (_historyDirection * _historyPan.dx / 80).clamp(0, 1);
    }
  }

  void _historyGestureEnd(PointerPanZoomEndEvent event) {
    if (_historyPointer != event.pointer) return;
    // Commit once on finger lift; returning below the distance cancels the swipe.
    final back = _historyPan.dx > 0;
    final commit = _historyDirection != 0 && _historyPan.dx.abs() >= 80 &&
      _historyStartRoute == widget.navigation.route && ModalRoute.of(context)?.isCurrent == true;
    _cancelHistoryGesture();
    if (commit) _navigateHistory(back);
  }

  bool _historyContentScrolled(ScrollNotification notification) {
    // A shelf or page that actually moved owns this gesture, even if it reaches
    // its edge later. A fresh outward swipe at the edge can navigate history.
    if (_historyPointer != null && notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final metrics = notification.metrics;
      final before = (metrics.pixels - (notification.scrollDelta ?? 0))
        .clamp(metrics.minScrollExtent, metrics.maxScrollExtent);
      final after = metrics.pixels.clamp(metrics.minScrollExtent, metrics.maxScrollExtent);
      if (before != after) _cancelHistoryGesture();
    }
    return false;
  }

  void _select(SearchItem item) {
    unawaited(widget.searchController?.remember(item));
    widget.onSelect?.call(item);
    _navigate(DesktopRoute.selected(item));
  }

  void _selectHome(HomeItem item) {
    widget.onHomeSelect?.call(item);
    _navigate(DesktopRoute.content(item.uri, title: item.name,
      subtitle: item.contributors.join(', ')));
  }

  void _selectLibrary(LibraryItem item) {
    widget.onLibrarySelect?.call(item);
    _navigate(DesktopRoute.content(item.uri, title: item.name,
      subtitle: item.contributors.join(', ')));
  }

  /// Shared root callback for metadata links and caller-owned now-playing UI.
  void navigateToEntity(EntityLink link) {
    widget.onEntityNavigate?.call(link);
    _navigate(DesktopRoute.content(link.uri, title: link.name));
  }

  void _openLibraryRailItem(LibraryItem item) {
    if (item.type != 'folder') {
      _selectLibrary(item);
      return;
    }
    unawaited(widget.libraryController?.openFolder(item.uri));
    widget.onLibraryOpenFolder?.call(item);
    _navigate(DesktopRoute.fromUri(Uri.parse('/collection')));
  }

  void _submit(String query) {
    final link = desktopRouteForLink(query);
    if (link != null) {
      _navigate(link);
      return;
    }
    final selected = _suggestionsController.isShowing ? widget.searchController?.state.selectedItem : null;
    if (selected != null) {
      _select(selected);
    } else if (query.isNotEmpty) {
      _navigate(DesktopRoute.search(query));
    }
  }

  void _logIn() {
    final login = widget.onLogIn;
    if (login != null) {
      login();
      return;
    }
    showDialog<void>(context: context, builder: (context) => AlertDialog(
      backgroundColor: const Color(0xff282828),
      content: const Text('Sign-in is currently unavailable.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context),
        child: const Text('Close', style: TextStyle(color: Colors.white)))],
    ));
  }

  KeyEventResult _searchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _dismissSuggestions(unfocus: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      _showSuggestions();
      widget.searchController?.moveSelection(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _cancelHistoryGesture();
    _historyFeedback?.dispose();
    _disposeDestinations();
    _lyrics?.dispose();
    unawaited(_playbackStates?.cancel());
    widget.searchController?.removeListener(_syncSearch);
    _focus.dispose();
    _input.dispose();
    _sidebarSizing?.dispose();
    super.dispose();
  }

  _ShellContents _buildContents() {
    final expandedLibrary = _library(false, canExpand: true);
    final collapsedLibrary = _library(true, canExpand: true);
    final compactLibrary = _library(true, canExpand: false);
    final main = ClipRRect(borderRadius: BorderRadius.circular(8),
      child: ColoredBox(color: const Color(0xff121212), child: Stack(fit: StackFit.expand, children: [
        _mainView(),
        IgnorePointer(child: RepaintBoundary(child: CustomPaint(
          painter: _HistorySwipeIndicator(_historyProgress)))),
      ])));
    final right = _playbackState?.item == null ? const SizedBox.shrink() : NowPlayingPanel(
      state: _playbackState!, artworkBuilder: widget.playbackArtworkBuilder,
      trackSaveButtonBuilder: widget.trackSaveButtonBuilder,
      lyricsController: _lyrics, onShowLyrics: openLyrics, onNavigate: navigateToEntity,
      onClose: () { _showNowPlaying = false; _sidebarChanges.value++; });
    final playback = DesktopPlaybackBar(controller: widget.playbackController,
      lyricsActive: widget.route.destination == DesktopDestination.lyrics,
      onShowLyrics: _lyrics == null ? null : openLyrics,
      builder: widget.playbackBuilder, trackSaveButtonBuilder: widget.trackSaveButtonBuilder);
    final navigation = _globalNav();
    return (expandedLibrary: expandedLibrary, collapsedLibrary: collapsedLibrary,
      compactLibrary: compactLibrary, main: main, right: right,
      playback: playback, navigation: navigation);
  }

  @override
  Widget build(BuildContext context) {
    // State can retain inherited dependencies registered by earlier hot-reload
    // code or dialog helpers. A metrics-driven rebuild must not discard stable
    // panel widgets. Their own elements still observe theme and text scaling.
    if (_view != null) return _view!;
    final contents = _contents ??= _buildContents();
    return _view = CallbackShortcuts(bindings: {
    const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => unawaited(openQuickSearch()),
    const SingleActivator(LogicalKeyboardKey.keyL, meta: true): focusSearch,
  }, child: Focus(autofocus: true, child: Listener(
    onPointerPanZoomStart: _historyGestureStart,
    onPointerPanZoomUpdate: _historyGestureUpdate,
    onPointerPanZoomEnd: _historyGestureEnd,
    child: NotificationListener<ScrollNotification>(onNotification: _historyContentScrolled,
      child: Scaffold(
    body: SafeArea(top: !_macWindow, child: LayoutBuilder(builder: (context, constraints) =>
      _desktopLayout(constraints, expandedLibrary: contents.expandedLibrary,
        collapsedLibrary: constraints.maxWidth >= 840 ? contents.collapsedLibrary : contents.compactLibrary,
        main: contents.main, right: contents.right, playback: contents.playback,
        navigation: contents.navigation))),
  )))));
  }

  Widget _desktopLayout(BoxConstraints constraints, {required Widget expandedLibrary,
    required Widget collapsedLibrary, required Widget main, required Widget right,
    required Widget playback, required Widget navigation}) {
    // Both window metrics and sidebar drags change constraints. Keep panel and
    // player widgets outside those builders so real layout can run without
    // reconstructing all mounted rows, image builders and controls each time.
    return developer.Timeline.timeSync('ui.shell.layout', () => Column(children: [
      SizedBox(height: 64, child: navigation),
      Expanded(child: ValueListenableBuilder<int>(valueListenable: _sidebarChanges,
        builder: (context, _, _) {
      final showLibrary = constraints.maxWidth >= 600;
      final collapsed = _collapsed || constraints.maxWidth < 840;
      final showRight = constraints.maxWidth >= 1200 && _showNowPlaying && _playbackState?.item != null;
      final rightWidth = showRight ? (_nowPlayingWidth ?? 356).clamp(280, 420).toDouble() : 0.0;
      // Original main-view minimum416, outer padding16, and eight-pixel gutters.
      final panelBudget = constraints.maxWidth - 16 - (showLibrary ? 8 : 0) - (showRight ? 8 : 0);
      final leftMaximum = panelBudget - 416 - rightWidth;
      final leftRanges = <SidebarWidthRange>[
        (min: 72, max: 72),
        if (constraints.maxWidth >= 840 && leftMaximum >= 280)
          (min: 280, max: leftMaximum.clamp(280, 420)),
        if (constraints.maxWidth >= 840 && leftMaximum >= 584)
          (min: 584, max: leftMaximum),
      ];
      final leftWidth = showLibrary ? snapSidebarWidth(collapsed ? 72.0 : _libraryWidth ?? 290, leftRanges) : 0.0;
      final rightMaximum = (panelBudget - 416 - leftWidth).clamp(280, 420).toDouble();
      return Stack(fit: StackFit.expand, children: [Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (showLibrary) ...[
              SizedBox(key: const ValueKey('library-panel'), width: leftWidth,
                child: leftWidth == 72 ? collapsedLibrary : expandedLibrary),
              SidebarResizeHandle(key: const ValueKey('library-resize'), label: 'Resize Your Library',
                width: leftWidth, ranges: leftRanges, growsRight: true,
                onResize: (width) {
                  _sidebarWidthsEdited = true; _collapsed = width == 72;
                  if (!_collapsed) _libraryWidth = width;
                  _sidebarChanges.value++;
                },
                onDragState: (value) { _resizingSidebar = value; _sidebarChanges.value++; },
                onResizeEnd: () => unawaited(_saveSidebarWidths())),
            ],
            Expanded(child: main),
            if (showRight) ...[
              SidebarResizeHandle(key: const ValueKey('now-playing-resize'), label: 'Resize Now Playing',
                width: rightWidth, ranges: [(min: 280, max: rightMaximum)], growsRight: false,
                onResize: (width) {
                  _sidebarWidthsEdited = true; _nowPlayingWidth = width; _sidebarChanges.value++;
                },
                onDragState: (value) { _resizingSidebar = value; _sidebarChanges.value++; },
                onResizeEnd: () => unawaited(_saveSidebarWidths())),
              SizedBox(key: const ValueKey('now-playing-panel'), width: rightWidth, child: right),
            ],
          ]),
        ),
        if (_resizingSidebar == true) const Positioned.fill(child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: AbsorbPointer(child: ColoredBox(color: Colors.transparent)))),
      ]);
    })),
      SizedBox(height: constraints.maxHeight < 440 ? 64 : 88,
        child: playback),
    ]));
  }

  Widget _globalNav() {
    final home = DesktopIconButton(size: 48, padding: const EdgeInsets.all(12),
      tooltip: 'Home',
      onPressed: () => _navigate(DesktopRoute.fromUri(Uri.parse('/'))),
      backgroundColor: const Color(0xff1f1f1f),
      icon: Icon(widget.route.destination == DesktopDestination.home
          ? SpotifyShellIcons.homeFilled : SpotifyShellIcons.home,
        color: widget.route.destination == DesktopDestination.home ? Colors.white : null),
    );
    final account = widget.accountName;
    final Widget profile = account == null ? TextButton(onPressed: _logIn,
      style: TextButton.styleFrom(foregroundColor: Colors.black,
        backgroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 20),
        minimumSize: const Size(72, 48)),
      child: const Text('Log in', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)))
      : PopupMenuButton<String>(tooltip: 'Profile', position: PopupMenuPosition.under,
        color: const Color(0xff282828), padding: EdgeInsets.zero,
        onSelected: (action) { if (action == 'logout') widget.onLogOut?.call(); },
        itemBuilder: (_) => [PopupMenuItem<String>(enabled: false,
          child: Text(account, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const PopupMenuDivider(),
          PopupMenuItem<String>(value: 'logout', enabled: widget.onLogOut != null, child: const Text('Log out'))],
        child: Semantics(label: 'Profile menu, signed in as $account', button: true,
          child: Container(width: 48, height: 48, padding: const EdgeInsets.all(8),
          decoration: const BoxDecoration(color: Color(0xff1f1f1f), shape: BoxShape.circle),
          child: const DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle,
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xff63c8ce), Color(0xff617ce7), Color(0xff8658eb)]))))));
    final search = _searchInput();
    final nativeInset = _macWindow ? 80.0 : 0.0;
    final back = DesktopIconButton(tooltip: 'Go back', size: 36,
      icon: const Icon(SpotifyShellIcons.back),
      onPressed: widget.navigation.canGoBack ? () => _navigateHistory(true) : null);
    final forward = DesktopIconButton(tooltip: 'Go forward', size: 36,
      icon: const Icon(SpotifyShellIcons.forward),
      onPressed: widget.navigation.canGoForward ? () => _navigateHistory(false) : null);
    Widget? cached;
    int? cachedBand;
    return LayoutBuilder(builder: (context, constraints) {
    final width = constraints.maxWidth;
    final band = width < 420 ? 0 : width < 600 ? 1 : width < 800 ? 2 : width < 1000 ? 3 : 4;
    if (cached != null && cachedBand == band) return cached!;
    cachedBand = band;
    final history = Row(mainAxisSize: MainAxisSize.min, children: [back, if (width >= 800) forward]);
    Widget contents;
    if (width < 600) {
      contents = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
        SizedBox(width: nativeInset),
        SizedBox(width: 40, height: 48, child: home),
        const SizedBox(width: 8),
        Expanded(child: search),
        DesktopIconButton(tooltip: 'Your Library', size: 40,
          icon: const Icon(SpotifyShellIcons.expandLibrary, size: 20),
          onPressed: () => _navigate(DesktopRoute.fromUri(Uri.parse('/collection')))),
        if (width >= 420) profile,
      ]));
    } else {
      final center = Row(children: [SizedBox(width: 48, height: 48, child: home),
        const SizedBox(width: 8), Expanded(child: search)]);
      if (width < 1000) {
        contents = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          SizedBox(width: nativeInset), history, const SizedBox(width: 8), Expanded(child: center),
          const SizedBox(width: 16), profile,
        ]));
      } else {
        contents = Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Stack(children: [
          Row(children: [SizedBox(width: nativeInset), history, const Spacer(), profile]),
          Center(child: LayoutBuilder(builder: (context, bounds) =>
            SizedBox(width: (bounds.maxWidth * 0.5).clamp(350, 546), height: 48, child: center))),
        ]));
      }
    }
    return cached = Stack(fit: StackFit.expand, children: [
      if (_macWindow) Positioned.fill(child: Listener(behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (event.buttons == kPrimaryButton) unawaited(_startWindowDrag());
        }, child: const SizedBox.expand())),
      contents,
    ]);
    });
  }

  Widget _searchInput() => LayoutBuilder(builder: (context, constraints) => OverlayPortal(
    key: _searchPortalKey,
    controller: _suggestionsController,
    overlayChildBuilder: (context) {
      final controller = widget.searchController;
      if (controller == null) return const SizedBox.shrink();
      final available = (MediaQuery.sizeOf(context).height - 176).clamp(80.0, 420.0).toDouble();
      return Positioned(left: 0, top: 0, child: CompositedTransformFollower(
        link: _searchLink, showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft, followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 4), child: TextFieldTapRegion(groupId: _searchTapGroup,
          child: Focus(canRequestFocus: false, descendantsAreFocusable: false,
            child: SizedBox(width: constraints.maxWidth, child: SearchSuggestionsDropdown(
              controller: controller, maxHeight: available, onSelect: _select,
              onViewAllResults: (query) => _navigate(DesktopRoute.search(query)),
              artworkBuilder: widget.artworkBuilder))))));
    },
    child: CompositedTransformTarget(link: _searchLink, child: Focus(onKeyEvent: _searchKey,
    child: ValueListenableBuilder<TextEditingValue>(valueListenable: _input,
      builder: (context, value, _) => SizedBox(height: 48, child: TextField(
        controller: _input, focusNode: _focus, groupId: _searchTapGroup,
        onChanged: _queryChanged, onTap: _showSuggestions,
        onTapOutside: (_) => _dismissSuggestions(unfocus: true),
        onSubmitted: _submit, textInputAction: TextInputAction.search,
        style: const TextStyle(color: Colors.white, fontSize: 16), cursorColor: Colors.white,
        decoration: InputDecoration(
          hintText: 'What do you want to play?',
          hintStyle: const TextStyle(color: Color(0xffb3b3b3), fontSize: 16),
          filled: true, fillColor: const Color(0xff1f1f1f),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          prefixIcon: const Icon(SpotifyShellIcons.search, color: Color(0xffb3b3b3)),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (value.text.isNotEmpty && constraints.maxWidth >= 240) DesktopIconButton(tooltip: 'Clear search', size: 40,
              icon: const Icon(SpotifyShellIcons.close, size: 20),
              onPressed: () { _setInput(''); _queryChanged(''); _focus.requestFocus(); }),
            const SizedBox(height: 24, child: VerticalDivider(width: 1, thickness: 1, color: Color(0xff7c7c7c))),
            const SizedBox(width: 8),
            DesktopIconButton(tooltip: 'Browse', size: 40, icon: const Icon(SpotifyShellIcons.browse),
              onPressed: () => _navigate(DesktopRoute.search(''))),
          ]),
          border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(500)),
          focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(500)),
        ),
      )),
    ))),
  ));

  Widget _library(bool collapsed, {required bool canExpand}) => Material(
    color: const Color(0xff121212), borderRadius: BorderRadius.circular(8), clipBehavior: Clip.antiAlias,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: 64, child: collapsed
          ? Center(child: DesktopIconButton(tooltip: canExpand ? 'Expand Your Library' : 'Your Library',
              onPressed: () {
                if (_collapsed && canExpand) {
                  _toggleLibrary();
                } else {
                  _navigate(DesktopRoute.fromUri(Uri.parse('/collection')));
                }
              },
              icon: const Icon(SpotifyShellIcons.collapseLibrary)))
          : Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
              Expanded(child: TextButton(onPressed: _toggleLibrary,
                style: TextButton.styleFrom(foregroundColor: Colors.white, alignment: Alignment.centerLeft),
                child: const Text('Your Library', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)))),
              const DesktopIconButton(tooltip: 'Create playlist is currently unavailable', size: 36,
                backgroundColor: Color(0xff1f1f1f), icon: Icon(Icons.add, size: 20)),
              const SizedBox(width: 8),
              DesktopIconButton(tooltip: 'Expand Your Library', icon: const Icon(SpotifyShellIcons.expandLibrary, size: 16),
                onPressed: () => _navigate(DesktopRoute.fromUri(Uri.parse('/collection')))),
            ]))),
      if (widget.libraryController case final controller?)
        Expanded(child: collapsed ? _libraryRail(controller) : LibraryView(
          key: const PageStorageKey('library-sidebar'), controller: controller,
          activeUri: widget.route.entityUri,
          onSelect: _selectLibrary, onOpenFolder: widget.onLibraryOpenFolder,
          artworkBuilder: widget.libraryArtworkBuilder, actionsBuilder: widget.libraryItemActionsBuilder,
          showHeader: false))
      else if (!collapsed) const Padding(padding: EdgeInsets.all(20),
        child: Text('Your library is currently unavailable.',
          style: TextStyle(color: Color(0xffb3b3b3), fontSize: 14))),
    ]),
  );

  Widget _libraryRail(LibraryController controller) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final state = controller.state;
      if (state.page == null) {
        return Align(alignment: Alignment.topCenter, child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: state.phase == LibraryPhase.failed
            ? IconButton(tooltip: 'Couldn’t load Your Library. Try again',
                icon: const Icon(Icons.refresh), onPressed: controller.refresh)
            : const SizedBox.square(dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2)),
        ));
      }
      if (state.items.isEmpty) {
        return Align(alignment: Alignment.topCenter, child: IconButton(
          tooltip: state.query.textFilter.isEmpty ? 'Your library is empty.' : 'No results',
          icon: const Icon(Icons.library_music_outlined),
          onPressed: () => _navigate(DesktopRoute.fromUri(Uri.parse('/collection')))));
      }
      return LibrarySelectionViewport(library: controller, activeUri: widget.route.entityUri,
        rowExtent: 56, itemCount: state.items.length,
        builder: (scroll) => ListView.builder(controller: scroll, itemExtent: 56,
      key: const PageStorageKey('library-rail'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: controller.state.items.length + (controller.state.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == controller.state.items.length) {
          return SizedBox(height: 48, child: controller.state.isLoadingMore
            ? const Center(child: SizedBox.square(dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(tooltip: 'Load more', icon: const Icon(Icons.more_horiz),
                onPressed: controller.loadMore));
        }
        final item = controller.state.items[index];
        final selected = libraryUriMatches(item.uri, widget.route.entityUri);
        return Semantics(selected: selected, child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: selected ? const Color(0xff333333) : null,
            borderRadius: BorderRadius.circular(4)), child: Tooltip(
          message: item.isSupported ? item.name : 'Content is currently unavailable.',
          child: SizedBox.square(dimension: 48, child: Material(
            color: const Color(0xff282828), borderRadius: BorderRadius.circular(4),
            clipBehavior: Clip.antiAlias, child: Stack(fit: StackFit.expand, children: [
              InkWell(onTap: item.isSupported ? () => _openLibraryRailItem(item) : null,
                child: widget.libraryArtworkBuilder?.call(context, item) ?? Icon(
                  item.type == 'folder' ? Icons.folder_outlined : Icons.music_note,
                  color: const Color(0xffb3b3b3))),
              if (item.isSupported && widget.libraryItemActionsBuilder != null)
                Positioned(right: 0, bottom: 0, child: _LibraryRailActions(
                  item: item, actionsBuilder: widget.libraryItemActionsBuilder!)),
            ]),
          )),
        )));
      },
      ));
    },
  );

  Widget _mainView() {
    final route = widget.route;
    if (route.destination == DesktopDestination.lyrics && _lyrics != null) {
      return LyricsView(controller: _lyrics!);
    }
    final homeDestination = _destinationFor(route);
    if (homeDestination != null) {
      return HomeDestinationView(key: ValueKey(homeDestination.target.key), controller: homeDestination,
        onSelect: _selectHome, onOpenSection: _openHomeSection, artworkBuilder: widget.homeArtworkBuilder);
    }
    final entity = widget.entityController;
    if (route.destination == DesktopDestination.item && entity != null) {
      return EntityView(key: PageStorageKey('entity-view:${entity.state.uri}'), controller: entity,
        playingUri: _playbackState?.item?.uri,
        shuffle: _playbackState?.shuffle == true,
        onToggleShuffle: widget.playbackController != null && _playbackState?.restrictions.canToggleShuffle == true
          ? () => unawaited(widget.playbackController!.setShuffle(_playbackState?.shuffle != true)
              .catchError((Object _) { if (mounted) showSpotifySnackBar(context, 'Couldn’t change shuffle.'); })) : null,
        isPlaying: _playbackState?.hasContext == true &&
          _playbackState?.isPaused == false && _playbackState?.isBuffering == false,
        onSelect: widget.onEntitySelect, onPlay: widget.onEntityPlay, onNavigate: navigateToEntity,
        artworkBuilder: widget.entityArtworkBuilder, rowArtworkBuilder: widget.entityRowArtworkBuilder,
        rowActionsBuilder: widget.entityRowActionsBuilder);
    }
    final library = widget.libraryController;
    if (route.destination == DesktopDestination.library && library != null) {
      return LibraryView(key: const PageStorageKey('library-main'), controller: library,
        activeUri: route.entityUri,
        onSelect: _selectLibrary, onOpenFolder: widget.onLibraryOpenFolder,
        artworkBuilder: widget.libraryArtworkBuilder, actionsBuilder: widget.libraryItemActionsBuilder);
    }
    final home = widget.homeController;
    if (route.destination == DesktopDestination.home && home != null) {
      return HomeView(controller: home, onSelect: _selectHome,
        showFilters: true,
        facet: route.homeFacet, onSelectFacet: (facet) => _navigate(DesktopRoute.home(facet: facet)),
        onOpenSection: _openHomeSection, artworkBuilder: widget.homeArtworkBuilder);
    }
    final search = widget.searchController;
    if (route.destination == DesktopDestination.search && search != null) {
      return SearchResultsView(controller: search, query: route.query, category: route.searchCategory, onSelect: _select,
        onCategory: (category) => _navigate(DesktopRoute.search(route.query, category: category)),
        onPlay: widget.onQuickSearchPlay == null ? null : (item) {
          unawaited(search.remember(item)); widget.onQuickSearchPlay!(item);
        },
        artworkBuilder: widget.artworkBuilder);
    }
    final title = switch (route.destination) {
      DesktopDestination.home => 'Home', DesktopDestination.search => 'Search',
      DesktopDestination.library => 'Your Library',
      DesktopDestination.lyrics => 'Lyrics',
      DesktopDestination.item => route.title ?? 'This item is unavailable',
      DesktopDestination.unavailable => 'This page is unavailable',
    };
    final message = switch (route.destination) {
      DesktopDestination.home || DesktopDestination.search => widget.accountName != null
          ? 'Find music using Search.' : widget.onLogIn == null
          ? 'Sign-in is currently unavailable.' : 'Log in to continue.',
      DesktopDestination.library => 'Your library is currently unavailable.',
      DesktopDestination.lyrics => 'Play a song to see its lyrics.',
      DesktopDestination.item => (widget.onSelect != null || widget.onHomeSelect != null || widget.onLibrarySelect != null)
          && route.title != null ? route.subtitle ?? '' : 'Playback is currently unavailable.',
      DesktopDestination.unavailable => 'Return home to continue.',
    };
    return Padding(padding: const EdgeInsets.all(24), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(fontFamily: 'SpotifyMixUITitle', fontSize: 32,
          fontWeight: FontWeight.w700, color: Colors.white)),
        Expanded(child: Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(message,
          textAlign: TextAlign.center, style: const TextStyle(color: Color(0xffb3b3b3), fontSize: 16))))),
      ],
    ));
  }

  void _openHomeSection(HomeSection section) {
    widget.onOpenHomeSection?.call(section);
    final uri = section.seeAllUri;
    if (uri == null || uri.isEmpty) return;
    _navigate(uri.startsWith('/') ? DesktopRoute.fromUri(Uri.parse(uri))
      : DesktopRoute.content(uri, title: section.title));
  }

  HomeDestinationController? _destinationFor(DesktopRoute route) {
    final target = route.homeDestination, provider = widget.homeController?.repository;
    if (target == null || provider is! HomeDestinationProvider) return null;
    final repository = _homeDestinationRepository ??= (provider as HomeDestinationProvider).destinations;
    final controllers = _homeDestinations ??= {};
    final existing = controllers.remove(target.key);
    final controller = existing ?? HomeDestinationController(repository, target);
    controllers[target.key] = controller;
    while (controllers.length > 8) { controllers.remove(controllers.keys.first)?.dispose(); }
    return controller;
  }

  void _disposeDestinations() {
    for (final controller in _homeDestinations?.values ?? <HomeDestinationController>[]) {
      controller.dispose();
    }
    _homeDestinations?.clear();
    _homeDestinationRepository = null;
  }
}

/// Chromium's edge shield: up to 70 px revealed from a 140 px oval, with a
/// slightly taller, darker shape at the commit threshold. Only this layer paints.
class _HistorySwipeIndicator extends CustomPainter {
  _HistorySwipeIndicator(this.progress) : super(repaint: progress);
  final ValueNotifier<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final value = progress.value;
    if (value == 0) return;
    final back = value > 0, amount = value.abs();
    final complete = amount >= 1;
    final height = complete ? 150.0 : 140.0;
    final revealed = 70 * amount;
    final edge = back ? -140 + revealed : size.width - revealed;
    final oval = Rect.fromLTWH(edge, (size.height - height) / 2, 140, height);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawOval(oval, Paint()..color = Colors.black.withValues(
      alpha: complete ? .75 : amount.clamp(.25, .65)));
    canvas.translate(back ? oval.right - 35 : oval.left + 35, size.height / 2);
    if (!back) canvas.scale(-1, 1);
    canvas.drawPath(Path()..moveTo(4, -9)..lineTo(-5, 0)..lineTo(4, 9)
      ..moveTo(-5, 0)..lineTo(14, 0), Paint()..color = Colors.white
      ..style = PaintingStyle.stroke..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HistorySwipeIndicator oldDelegate) => oldDelegate.progress != progress;
}

class _LibraryRailActions extends StatefulWidget {
  const _LibraryRailActions({required this.item, required this.actionsBuilder});
  final LibraryItem item;
  final LibraryItemActionsBuilder actionsBuilder;

  @override
  State<_LibraryRailActions> createState() => _LibraryRailActionsState();
}

class _LibraryRailActionsState extends State<_LibraryRailActions> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) => MenuAnchor(controller: _menu,
    menuChildren: [Listener(onPointerUp: (_) => scheduleMicrotask(_menu.close),
      child: widget.actionsBuilder(context, widget.item))],
    builder: (context, controller, _) => SizedBox.square(dimension: 24, child: IconButton(
      tooltip: 'Actions for ${widget.item.name}',
      padding: EdgeInsets.zero, constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      style: IconButton.styleFrom(backgroundColor: const Color(0xff282828)),
      icon: const Icon(Icons.more_horiz, size: 16),
      onPressed: () => controller.isOpen ? controller.close() : controller.open(),
    )),
  );
}
