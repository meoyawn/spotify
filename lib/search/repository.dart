import 'package:cancellation_token/cancellation_token.dart';

import '../async/shared_task.dart';
import '../protocol/pathfinder.dart';
import 'models.dart';

abstract interface class SearchRepository {
  Future<SearchPage> suggestions(String query, {CancellationToken? cancellationToken});
  Future<SearchPage> recent({CancellationToken? cancellationToken});
}

abstract interface class SearchModalRepository {
  Future<SearchPage> modal(String query, {CancellationToken? cancellationToken});
}

abstract interface class FullSearchRepository {
  Future<SearchResults> results(String query, {SearchCategory? category, int offset = 0, int? limit, CancellationToken? cancellationToken});
  Future<void> removeRecent(List<String> uris, {CancellationToken? cancellationToken});
  Future<void> saveRecent(List<String> uris, {CancellationToken? cancellationToken});
}

/// Values observed in the captured desktop session, supplied by experiments.
class SearchFeatures {
  const SearchFeatures({
    this.includeAuthors = true,
    this.includeAlbumPreReleases = false,
    this.includeEpisodeContentRatingsV2 = true,
  });

  final bool includeAuthors;
  final bool includeAlbumPreReleases;
  final bool includeEpisodeContentRatingsV2;
}

class SearchQueryError implements Exception {
  const SearchQueryError(this.errors);
  final Object? errors;

  @override
  String toString() => 'SearchQueryError: $errors';
}

/// Desktop suggestions and recent history; no default transport or credentials.
class PathfinderSearchRepository implements SearchRepository, SearchModalRepository, FullSearchRepository {
  PathfinderSearchRepository(this.loader, {
    this.features = const SearchFeatures(),
  });

  static const suggestionsOperation = PathfinderOperation(
    name: 'searchSuggestions',
    operation: 'query',
    sha256Hash: 'f244254b94c0e824d458ac216e0f8406a73f2f69a9ff52831a2f78fa774ff6ce',
    value: null,
  );
  static const recentOperation = PathfinderOperation(
    name: 'recentSearches',
    operation: 'query',
    sha256Hash: 'ece96d7b82c820fb9938dd1df50dee3e53737d808c3883e3d01c467c423601b0',
    value: null,
  );
  static const modalOperation = PathfinderOperation(
    name: 'searchModalResults', operation: 'query',
    sha256Hash: '9a79751378a306d87d9789fa0c4a8f7c7213891c47a3993a0d0b58ff26514e59',
    value: null,
  );
  static const fullOperation = PathfinderOperation(name: 'searchDesktop', operation: 'query',
    sha256Hash: 'eef7cc54888d91bdd6802623477873caa3948ae173a0c34fd86827b267e94c03', value: null);
  static const categoryHashes = {
    SearchCategory.tracks: 'b02683192a98dde7966b5e6655a79eeb62713eab703eda9902c932818dd52751',
    SearchCategory.albums: '202cb3305e31e5a0767ba7925f28bd728cf8f8b0217e6da43909056071cd70e9',
    SearchCategory.artists: '7bf95d754fdbe32c8b161fbbe54d1ae50974900df4dce4c8f1afcbcad153224d',
    SearchCategory.playlists: 'd520014e748f9ea44f7707d8df1819867ac1205e8b7f3e28f22fe5fc858921b1',
    SearchCategory.podcasts: '0195d9f61b43606d490bca64c3456e3593528cea6cc05c7e822c7c42beed0f4e',
    SearchCategory.episodes: '397a4e93a21d140d088cfd26641133c5146a2f5f08e420654868153e720f5571',
    SearchCategory.audiobooks: 'e05ac765d02c084f8783d3c1572b23d57761c43f47eb8b87ce2f9ccced3fa068',
    SearchCategory.authors: '4a9d403a7cbc7e19da5520d619a865472b35382b043bfa458154e73a5c6f46bd',
    SearchCategory.genres: '9e1c0e056c46239dd1956ea915b988913c87c04ce3dadccdb537774490266f46',
    SearchCategory.users: '8f358dd82e62f61dd4ceaa9f8cd0889e644c9b707f1b724fbfb356a757cb7e5a',
  };

  final PathfinderLoader loader;
  final SearchFeatures features;
  final _results = <(String, SearchCategory?, int, int), (DateTime, SharedTask<SearchResults>)>{};
  (DateTime, SharedTask<SearchPage>)? _recent;

  @override
  Future<SearchResults> results(String query, {SearchCategory? category, int offset = 0, int? limit, CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    if (query.isEmpty) return Future.value(SearchResults(query: query));
    final count = limit ?? category?.pageSize ?? 10;
    if (offset < 0 || count < 1 || count > 100) throw ArgumentError('Invalid search page');
    final key = (query, category, offset, count), now = DateTime.now();
    final previous = _results.remove(key);
    if (previous != null && now.isBefore(previous.$1) && !previous.$2.token.isCancelled) {
      _results[key] = previous; return previous.$2.wait(cancellationToken);
    }
    final operation = category == null ? fullOperation : PathfinderOperation(
      name: category == SearchCategory.episodes ? 'searchFullEpisodes' : 'search${category.name[0].toUpperCase()}${category.name.substring(1)}',
      operation: 'query', sha256Hash: categoryHashes[category]!, value: null);
    final variables = category == null ? <String, Object?>{
      'searchTerm': query, 'offset': 0, 'limit': 10, 'numberOfTopResults': 5,
      'includeAudiobooks': true, 'includeArtistHasConcertsField': false,
      'includePreReleases': true, 'includeAlbumPreReleases': features.includeAlbumPreReleases,
      'includeAuthors': features.includeAuthors, 'includeEpisodeContentRatingsV2': features.includeEpisodeContentRatingsV2,
      'isPrefix': null, 'sectionFilters': ['GENERIC'],
    } : category == SearchCategory.episodes ? <String, Object?>{
      'searchTerm': query, 'offset': offset, 'limit': count,
      'includeEpisodeContentRatingsV2': features.includeEpisodeContentRatingsV2,
    } : <String, Object?>{
      'includePreReleases': category == SearchCategory.audiobooks,
      'includeAlbumPreReleases': features.includeAlbumPreReleases, 'numberOfTopResults': 20,
      'searchTerm': query, 'offset': offset, 'limit': count, 'includeAudiobooks': true,
      'includeAuthors': features.includeAuthors, 'includeEpisodeContentRatingsV2': features.includeEpisodeContentRatingsV2,
    };
    late final SharedTask<SearchResults> pending;
    pending = SharedTask((token) => _load(operation, variables, cancellationToken: token).then((body) {
      if ((body['data'] as Map?)?['searchV2'] is! Map) throw const SearchQueryError('No search data returned');
      return SearchResults.fromJson(body, query: query, category: category);
    }).catchError((Object error) {
      if (identical(_results[key]?.$2, pending)) _results.remove(key);
      throw error;
    }));
    _results[key] = (now.add(Duration(minutes: category == null ? 15 : 5)), pending);
    while (_results.length > 24) { _results.remove(_results.keys.first); }
    return pending.wait(cancellationToken);
  }

  @override
  Future<void> removeRecent(List<String> uris, {CancellationToken? cancellationToken}) =>
    _history('removeRecentSearches', 'removeFromRecentSearches', uris, cancellationToken);
  @override
  Future<void> saveRecent(List<String> uris, {CancellationToken? cancellationToken}) =>
    _history('saveRecentSearches', 'saveToRecentSearches', uris, cancellationToken);

  Future<void> _history(String operation, String field, List<String> uris, CancellationToken? cancellationToken) async {
    cancellationToken?.throwIfCancelled();
    if (uris.isEmpty) return;
    final body = await _load(PathfinderOperation(name: operation, operation: 'mutation',
      sha256Hash: recentOperation.sha256Hash, value: null), {'uris': uris}, cancellationToken: cancellationToken);
    final response = (body['data'] as Map?)?[field];
    if (response is! Map || response['__typename'] == 'GenericError') {
      throw SearchQueryError(response is Map ? response['message'] : 'Search history update failed');
    }
    _recent = null;
  }

  @override
  Future<SearchPage> modal(String query, {CancellationToken? cancellationToken}) async {
    if (query.trim().isEmpty) return SearchPage(query: query, items: []);
    return SearchPage.fromModalJson(await _load(modalOperation, {
      'limit': 30, 'numberOfTopResults': 30, 'offset': 0,
      'searchTerm': query, 'includeAuthors': features.includeAuthors,
    }, cancellationToken: cancellationToken), query: query);
  }

  @override
  Future<SearchPage> suggestions(String query, {CancellationToken? cancellationToken}) async {
    if (query.isEmpty) return SearchPage(query: '', items: []);
    return SearchPage.fromJson(await _load(suggestionsOperation, {
      'query': query,
      'limit': 30,
      'numberOfTopResults': 30,
      'offset': 0,
      'includeAuthors': features.includeAuthors,
      'includeAlbumPreReleases': features.includeAlbumPreReleases,
      'includeEpisodeContentRatingsV2': features.includeEpisodeContentRatingsV2,
    }, cancellationToken: cancellationToken));
  }

  @override
  Future<SearchPage> recent({CancellationToken? cancellationToken}) {
    cancellationToken?.throwIfCancelled();
    final now = DateTime.now(), previous = _recent;
    if (previous != null && now.isBefore(previous.$1) && !previous.$2.token.isCancelled) {
      return previous.$2.wait(cancellationToken);
    }
    late final SharedTask<SearchPage> pending;
    pending = SharedTask((token) => _load(recentOperation, {
      'limit': 50,
      'includeAuthors': features.includeAuthors,
      'includeEpisodeContentRatingsV2': features.includeEpisodeContentRatingsV2,
    }, cancellationToken: token).then((body) => SearchPage.fromJson(body, recent: true)).catchError((Object error) {
      if (identical(_recent?.$2, pending)) _recent = null;
      throw error;
    }));
    _recent = (now.add(const Duration(minutes: 5)), pending);
    return pending.wait(cancellationToken);
  }

  Future<SearchJson> _load(
    PathfinderOperation operation,
    SearchJson variables, {
    CancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    final Object? response;
    try {
      response = await loader.load(operation, variables, cancellationToken: cancellationToken);
    } on CancelledException { rethrow; } catch (error) {
      final String? message = switch (error) {
        HttpResponseError() => error.message,
        GraphQLFallbackUnavailableError() => error.message,
        Error() => error.toString(),
        Exception() => error.toString(),
        _ => null,
      };
      throw SearchQueryError(message == null ? null : [{'message': message}]);
    }
    final body = response is SearchJson ? response : <String, Object?>{};
    final errors = body['errors'];
    if (errors != null && errors != false && errors != '' && errors != 0) {
      throw SearchQueryError(errors);
    }
    return body;
  }
}
