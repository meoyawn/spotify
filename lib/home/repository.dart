import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/pathfinder.dart';
import 'destinations_repository.dart';
import 'models.dart';

abstract interface class HomeRepository {
  Future<HomePage> load({String facet = '', CancellationToken? cancellationToken});
}

class HomeQueryError implements Exception {
  const HomeQueryError(this.errors);
  final Object? errors;

  @override
  String toString() => 'HomeQueryError: $errors';
}

/// Original desktop Home query. Session context and the sender are injected.
class PathfinderHomeRepository implements HomeRepository, HomeDestinationProvider {
  const PathfinderHomeRepository(this.loader, {required this.context});

  static const operation = PathfinderOperation(
    name: 'home', operation: 'query',
    sha256Hash: '5fb7da7a03ee2776c0670856609cb85a189a3cecc36cc160b91cde79063b9cf1',
    value: null,
  );
  final PathfinderLoader loader;
  final HomeRequestContext context;

  @override
  HomeDestinationRepository get destinations => PathfinderHomeDestinationRepository(loader, context: context);

  @override
  Future<HomePage> load({String facet = '', CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final Object? response;
    try {
      response = await loader.load(operation, {
        'includeHomeChapterVideoCards': context.features.includeHomeChapterVideoCards,
        'homeEndUserIntegration': 'INTEGRATION_DESKTOP',
        'timeZone': context.timeZone,
        'sp_t': context.spT,
        'facet': facet,
        'sectionItemsLimit': context.features.sectionItemsLimit ?? 10,
        'includeEpisodeContentRatingsV2': context.features.includeEpisodeContentRatingsV2,
      }, cancellationToken: cancellationToken);
    } on CancelledException { rethrow; } catch (error) {
      final message = switch (error) {
        HttpResponseError() => error.message,
        GraphQLFallbackUnavailableError() => error.message,
        Error() => error.toString(),
        Exception() => error.toString(),
        _ => null,
      };
      throw HomeQueryError(message == null ? null : [{'message': message}]);
    }
    final body = response is HomeJson ? response : <String, Object?>{};
    final errors = body['errors'];
    if (errors != null && errors != false && errors != '' && errors != 0) throw HomeQueryError(errors);
    final data = body['data'];
    final home = data is Map ? data['home'] : null;
    if (home is! HomeJson || home['__typename'] != 'HomeResponsePayload') throw const HomeQueryError(null);
    final container = home['sectionContainer'];
    final sections = container is Map ? container['sections'] : null;
    final items = sections is Map ? sections['items'] : null;
    if (sections is! Map || sections['totalCount'] == 0 || items is! List || items.isEmpty) {
      throw const HomeQueryError(null);
    }
    return HomePage.fromPayload(home, context: context);
  }
}
