import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../search/models.dart';
import '../home/destinations_repository.dart';

enum DesktopDestination { home, search, library, item, lyrics, unavailable }

class DesktopRoute {
  const DesktopRoute._(this.location, this.destination, {
    this.query = '', this.title, this.subtitle,
  });

  factory DesktopRoute.fromUri(Uri uri) {
    final path = uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (path.isEmpty || path.length == 1 && path.first == 'home') {
      return DesktopRoute.home(facet: uri.queryParameters['facet'] ?? '');
    }
    if (path.length == 2 && path.first == 'home' && path[1] == 'music') {
      // Local readable alias for the Music ID observed in Home.homeChips.
      return DesktopRoute.home(facet: 'music-chip');
    }
    if (path.first == 'search' && path.length <= 3 &&
        (path.length < 3 || SearchCategory.parse(path[2]) != null)) {
      return DesktopRoute.search(path.length >= 2 ? path[1] : '',
        category: path.length == 3 ? SearchCategory.parse(path[2]) : null);
    }
    if (path.length == 1 && path.first == 'collection') {
      return const DesktopRoute._('/collection', DesktopDestination.library);
    }
    if (path.length == 1 && path.first == 'lyrics') {
      return const DesktopRoute._('/lyrics', DesktopDestination.lyrics);
    }
    if (path.length >= 3 && path.first == 'artist' &&
        RegExp(r'^[0-9A-Za-z]{22}$').hasMatch(path[1]) &&
        (path.length == 3 && const {'related', 'appears-on', 'featuring', 'discovered-on'}.contains(path[2]) ||
         path.length == 4 && path[2] == 'discography' && const {'all', 'album', 'single', 'compilation'}.contains(path[3]))) {
      return DesktopRoute._(uri.path, DesktopDestination.item);
    }
    if (path.length == 2 && const [
      'track', 'album', 'artist', 'playlist', 'show', 'episode', 'audiobook',
      'author', 'user', 'genre', 'section', 'prerelease',
    ].contains(path.first)) {
      return DesktopRoute._(uri.path, DesktopDestination.item);
    }
    return DesktopRoute._(uri.path, DesktopDestination.unavailable);
  }

  factory DesktopRoute.search(String query, {SearchCategory? category}) => DesktopRoute._(
    query.isEmpty ? '/search' : Uri(pathSegments: ['', 'search', query, if (category != null) category.name]).toString(),
    DesktopDestination.search,
    query: query,
  );

  factory DesktopRoute.home({String facet = ''}) => DesktopRoute._(
    facet.isEmpty ? '/' : Uri(path: '/home', queryParameters: {'facet': facet}).toString(),
    DesktopDestination.home);

  factory DesktopRoute.selected(SearchItem item) {
    if (item.type == 'autocomplete') return DesktopRoute.search(item.name);
    return DesktopRoute.content(item.uri, title: item.name,
      subtitle: item.contributors.join(', '));
  }

  factory DesktopRoute.content(String uri, {String? title, String? subtitle}) {
    final parts = uri.split(':');
    final artistSection = parts.length >= 5 && parts[0] == 'spotify' && parts[1] == 'app' && parts[2] == 'artist';
    final location = artistSection ? Uri(pathSegments: ['', ...parts.skip(2)]).toString()
        : parts.length >= 3 && parts.first == 'spotify'
        ? Uri(pathSegments: ['', parts[1] == 'page' ? 'genre' : parts[1], parts.skip(2).join(':')]).toString()
        : '/unavailable';
    final destination = DesktopRoute.fromUri(Uri.parse(location)).destination;
    return DesktopRoute._(location, destination, title: title, subtitle: subtitle);
  }

  final String location;
  final DesktopDestination destination;
  final String query;
  String get homeFacet => destination == DesktopDestination.home
    ? Uri.parse(location).queryParameters['facet'] ?? '' : '';
  SearchCategory? get searchCategory {
    if (destination != DesktopDestination.search) return null;
    final path = Uri.parse(location).pathSegments;
    return path.length == 3 ? SearchCategory.parse(path[2]) : null;
  }
  final String? title;
  final String? subtitle;

  HomeDestinationTarget? get homeDestination {
    if (destination != DesktopDestination.item) return null;
    final path = Uri.parse(location).pathSegments;
    if (path.length != 2) return null;
    if (path.first == 'section') return HomeDestinationTarget(HomeDestinationKind.homeSection, 'spotify:section:${path[1]}');
    if (path.first != 'genre' || path[1] == 'recently-played') return null;
    final id = path[1];
    if (id.startsWith('section')) {
      return HomeDestinationTarget(HomeDestinationKind.browseSection,
        'spotify:section:${id.replaceFirst(RegExp(r'^section'), '')}');
    }
    return HomeDestinationTarget(HomeDestinationKind.browsePage,
      RegExp(r'^(section)?[0-9A-Za-z_-]{22}$').hasMatch(id) ? 'spotify:page:$id' : 'spotify:genre:$id');
  }

  /// Supported detail routes, including legacy user-owned playlist URIs.
  String? get entityUri {
    if (destination != DesktopDestination.item) return null;
    final path = Uri.parse(location).pathSegments;
    if (path.length >= 3 && path.first == 'artist') return 'spotify:app:${path.join(':')}';
    if (path.length != 2) return null;
    if (const {'track', 'artist', 'album', 'playlist'}.contains(path.first)) {
      return 'spotify:${path.first}:${path[1]}';
    }
    if (path.first == 'user' && RegExp(r'^[^:]*:playlist:[^:]+$').hasMatch(path[1])) {
      return 'spotify:user:${path[1]}';
    }
    return null;
  }
}

class DesktopRouteParser extends RouteInformationParser<DesktopRoute> {
  const DesktopRouteParser();

  @override
  Future<DesktopRoute> parseRouteInformation(RouteInformation routeInformation) =>
      SynchronousFuture(DesktopRoute.fromUri(routeInformation.uri));

  @override
  RouteInformation restoreRouteInformation(DesktopRoute configuration) =>
      RouteInformation(uri: Uri.parse(configuration.location));
}

/// Persistent desktop navigation history shared by top bar and platform back.
class DesktopRouter extends RouterDelegate<DesktopRoute>
    with ChangeNotifier, PopNavigatorRouterDelegateMixin<DesktopRoute> {
  DesktopRouter({required this.builder, String initialLocation = '/',
      GlobalKey<NavigatorState>? navigatorKey})
    : navigatorKey = navigatorKey ?? GlobalKey<NavigatorState>(),
      _history = [DesktopRoute.fromUri(Uri.parse(initialLocation))];

  final Widget Function(DesktopRouter navigation, DesktopRoute route) builder;
  final List<DesktopRoute> _history;
  int _index = 0;
  Widget? _pageContent;

  @override
  final GlobalKey<NavigatorState> navigatorKey;

  DesktopRoute get route => _history[_index];
  bool get canGoBack => _index > 0;
  bool get canGoForward => _index + 1 < _history.length;

  void go(DesktopRoute route) {
    if (route.location == this.route.location) return;
    _history.removeRange(_index + 1, _history.length);
    _history.add(route);
    _index++;
    refresh();
  }

  void back() {
    if (!canGoBack) return;
    _index--;
    refresh();
  }

  void reset(DesktopRoute route) {
    _history..clear()..add(route);
    _index = 0;
    refresh();
  }

  void forward() {
    if (!canGoForward) return;
    _index++;
    refresh();
  }

  void refresh() {
    _pageContent = null;
    notifyListeners();
  }

  @override
  DesktopRoute get currentConfiguration => route;

  @override
  Future<void> setNewRoutePath(DesktopRoute configuration) async {
    go(configuration);
  }

  @override
  Future<bool> popRoute() async {
    if (!canGoBack) return false;
    back();
    return true;
  }

  @override
  Widget build(BuildContext context) => Navigator(
    key: navigatorKey,
    // Router also builds when inherited window data changes. Only navigation
    // or new application inputs need a new shell; descendants still observe
    // their own theme, text scale and layout constraints normally.
    pages: [MaterialPage<void>(key: const ValueKey('desktop-shell'), child: _pageContent ??= builder(this, route))],
    onDidRemovePage: (_) {},
  );
}
