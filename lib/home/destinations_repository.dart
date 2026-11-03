import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import '../protocol/pathfinder.dart';
import 'models.dart';
import 'repository.dart';

enum HomeDestinationKind { homeSection, browsePage, browseSection }

class HomeDestinationTarget {
  const HomeDestinationTarget(this.kind, this.uri);
  final HomeDestinationKind kind;
  final String uri;
  String get key => '${kind.name}:$uri';
}

class HomeDestinationPage {
  HomeDestinationPage({this.title = '', this.subtitle = '', this.color,
    required List<HomeSection> sections, this.nextOffset, this.fullPage = false, this.continuationTarget})
    : sections = List.unmodifiable(sections);
  final String title, subtitle;
  final String? color;
  final List<HomeSection> sections;
  final int? nextOffset;
  final bool fullPage;
  final HomeDestinationTarget? continuationTarget;
}

abstract interface class HomeDestinationRepository {
  Future<HomeDestinationPage> destination(HomeDestinationTarget target, {int offset = 0, CancellationToken? cancellationToken});
}

abstract interface class HomeDestinationProvider {
  HomeDestinationRepository get destinations;
}

/// Original section providers53311/18722 and Browse page provider44729.
class PathfinderHomeDestinationRepository implements HomeDestinationRepository {
  PathfinderHomeDestinationRepository(this.loader, {required this.context, this.sectionItemsLimit});
  final PathfinderLoader loader;
  final HomeRequestContext context;
  final int? sectionItemsLimit;
  final _cache = <String, ({DateTime expires, HomeDestinationPage page})>{};
  final _pending = <String, SharedTask<HomeDestinationPage>>{};
  static const _operations = {
    HomeDestinationKind.homeSection: PathfinderOperation(name: 'homeSection', operation: 'query',
      sha256Hash: '5fb7da7a03ee2776c0670856609cb85a189a3cecc36cc160b91cde79063b9cf1', value: null),
    HomeDestinationKind.browsePage: PathfinderOperation(name: 'browsePage', operation: 'query',
      sha256Hash: 'f5c4e6d668f5716464a231c1cc8b22c1cbf6ad68b09929fd7de813a30581298b', value: null),
    HomeDestinationKind.browseSection: PathfinderOperation(name: 'browseSection', operation: 'query',
      sha256Hash: 'b13c1cccbfcb6947753c2613411b3566485c21fd5f36d80a80bb64be61ba2d51', value: null),
  };

  @override
  Future<HomeDestinationPage> destination(HomeDestinationTarget target, {int offset = 0, CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    if (offset < 0 || !RegExp(r'^spotify:(?:section|page|genre):[^\s:]+$').hasMatch(target.uri) ||
        (target.kind != HomeDestinationKind.browsePage && !target.uri.startsWith('spotify:section:'))) {
      throw ArgumentError('Invalid Home destination');
    }
    final key = '${target.key}:$offset';
    final cached = _cache.remove(key);
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      _cache[key] = cached;
      return cached.page;
    }
    var task = _pending[key];
    if (task == null || task.token.isCancelled) {
      task = SharedTask((token) async {
        final page = await _load(target, offset, token);
        token.throwIfCancelled();
        _cache[key] = (expires: DateTime.now().add(Duration(
          minutes: target.kind == HomeDestinationKind.homeSection ? 5 : 15)), page: page);
        while (_cache.length > 32) { _cache.remove(_cache.keys.first); }
        return page;
      });
      _pending[key] = task;
    }
    try { return await task.wait(cancellationToken); }
    finally {
      if ((task.isComplete || task.token.isCancelled) && identical(_pending[key], task)) _pending.remove(key);
    }
  }

  Future<HomeDestinationPage> _load(HomeDestinationTarget target, int offset, CancellationToken token) async {
    token.throwIfCancelled();
    final variables = switch (target.kind) {
      HomeDestinationKind.homeSection => <String, Object?>{
        'includeHomeChapterVideoCards': context.features.includeHomeChapterVideoCards,
        'uri': target.uri, 'homeEndUserIntegration': 'INTEGRATION_DESKTOP',
        'timeZone': context.timeZone, 'sp_t': context.spT,
        'sectionItemsOffset': offset, 'sectionItemsLimit': sectionItemsLimit ?? 20,
        'includeEpisodeContentRatingsV2': context.features.includeEpisodeContentRatingsV2,
      },
      HomeDestinationKind.browsePage => <String, Object?>{
        'pagePagination': {'offset': offset, 'limit': 10},
        'sectionPagination': {'offset': 0, 'limit': 10},
        'uri': target.uri, 'browseEndUserIntegration': 'INTEGRATION_DESKTOP',
        'includeEpisodeContentRatingsV2': context.features.includeEpisodeContentRatingsV2,
      },
      HomeDestinationKind.browseSection => <String, Object?>{
        'pagination': {'offset': offset, 'limit': 20},
        'uri': target.uri, 'browseEndUserIntegration': 'INTEGRATION_DESKTOP',
        'includeEpisodeContentRatingsV2': context.features.includeEpisodeContentRatingsV2,
      },
    };
    final Object? response;
    try { response = await loader.load(_operations[target.kind]!, variables, cancellationToken: token); }
    on CancelledException { rethrow; }
    catch (error) { throw HomeQueryError(error.toString()); }
    final body = _map(response), errors = body['errors'];
    if (errors != null && errors != false && errors != '' && errors != 0) throw HomeQueryError(errors);
    final data = _map(body['data']);
    if (target.kind == HomeDestinationKind.browsePage) {
      final browse = _map(data['browse']);
      if (browse['__typename'] != 'BrowseSectionContainer') throw const HomeQueryError(null);
      final header = _map(browse['header']), sections = _map(browse['sections']);
      final entries = _list(sections['items']);
      final projected = entries.map((section) => HomeSection.browse(_map(section))).whereType<HomeSection>().toList();
      if (offset == 0 && entries.length == 1) {
        final uri = _map(entries.first)['uri'];
        if (uri is String && uri.startsWith('spotify:section:')) {
          final drilldown = HomeDestinationTarget(HomeDestinationKind.browseSection, uri);
          try {
            final expanded = await destination(drilldown, cancellationToken: token);
            return HomeDestinationPage(title: _label(header['title']), subtitle: _label(header['subtitle']),
              color: _map(header['color'])['hex'] as String?, fullPage: true,
              sections: expanded.sections, nextOffset: expanded.nextOffset, continuationTarget: drilldown);
          } on HomeQueryError { /* Original single-shelf fallback retains the page's supplied cards. */ }
        }
        return HomeDestinationPage(title: _label(header['title']), subtitle: _label(header['subtitle']),
          color: _map(header['color'])['hex'] as String?, fullPage: true, sections: projected);
      }
      return HomeDestinationPage(title: _label(header['title']), subtitle: _label(header['subtitle']),
        color: _map(header['color'])['hex'] as String?,
        sections: projected, nextOffset: _next(sections, offset));
    }
    final Map<String, Object?> section;
    if (target.kind == HomeDestinationKind.homeSection) {
      final collection = _map(data['homeSections']), sections = _list(collection['sections']);
      if (collection['__typename'] != 'HomeSectionCollection' || sections.isEmpty ||
          _map(sections.first)['__typename'] != 'HomeSection') { throw const HomeQueryError(null); }
      section = _map(sections.first);
    } else {
      section = _map(data['browseSection']);
      if (section['__typename'] != 'BrowseSection') { throw const HomeQueryError(null); }
    }
    final projected = target.kind == HomeDestinationKind.homeSection
      ? HomeSection.fullPage(section) : HomeSection.browse(section, fullPage: true);
    return HomeDestinationPage(title: projected?.title ?? '', subtitle: projected?.pretitle ?? '',
      fullPage: true, sections: [?projected], nextOffset: _next(_map(section['sectionItems']), offset));
  }
}

Map<String, Object?> _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
List<Object?> _list(Object? value) => value is List ? value : [];
String _label(Object? value) => _map(value)['transformedLabel'] as String? ?? '';
int? _next(Map<String, Object?> container, int offset) {
  final value = _map(container['pagingInfo'])['nextOffset'];
  return value is int && value > offset ? value : null;
}
