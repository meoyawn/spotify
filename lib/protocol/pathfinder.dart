import 'request_builder.dart';
import 'package:cancellation_token/cancellation_token.dart';
/// Descriptor used by embedded module 85418 in Spotify 1.3.6.1921.
class PathfinderOperation {
  const PathfinderOperation({
    required this.name,
    required this.operation,
    required this.sha256Hash,
    required this.value,
  });

  final String name;
  final String operation;
  final String sha256Hash;
  final String? value;
}

/// The application envelope plus metadata passed to its request implementation.
class PathfinderRequest {
  const PathfinderRequest({
    required this.envelope,
    required this.endpointIdentifier,
    this.abortSignal,
  });

  final RequestEnvelope envelope;
  final String endpointIdentifier;
  final Object? abortSignal;
}

class PathfinderResponse {
  const PathfinderResponse({required this.body});

  final Object? body;
}

/// The branded response failure tested by original module 92464.
/// Other failures, including objects with a status field, do not cause fallback.
class HttpResponseError implements Exception {
  const HttpResponseError({
    required this.message,
    required this.url,
    required this.method,
    required this.status,
    this.response,
  });

  final String name = 'HttpResponseError';
  final String message;
  final String url;
  final String method;
  final int status;
  final Object? response;

  @override
  String toString() => '$name: $message';
}

class GraphQLFallbackUnavailableError implements Exception {
  const GraphQLFallbackUnavailableError(this.operationName, this.reason);

  final String operationName;
  final String reason;
  final String name = 'GraphQLFallbackUnavailableError';
  String get message => 'Fallback query for "$operationName" is not available!';

  @override
  String toString() => '$name: $message';
}

typedef PathfinderSend = Future<PathfinderResponse> Function(
  PathfinderRequest request,
);

/// The installed loader delegates cache ownership and the decision to fetch.
typedef PathfinderCacheLayer = Future<Object?> Function(
  SpotifyRequestBuilder builder,
  PathfinderOperation operation,
  Object? variables,
  Map<String, Object?> query,
  Map<String, String> headers,
  Future<Object?> Function() fetch,
  int cacheSeconds,
);

/// Port of embedded module 92464, with no built-in network transport.
/// The sender owns response rejection, cancellation, and transport additions.
class PathfinderLoader {
  const PathfinderLoader(
    this.builder, {
    required this.send,
    this.isInternalRequest = false,
    this.cacheLayer,
  });

  final SpotifyRequestBuilder builder;
  final PathfinderSend send;
  final bool isInternalRequest;
  final PathfinderCacheLayer? cacheLayer;

  Future<Object?> load(
    PathfinderOperation operation,
    Object? variables, {
    Map<String, Object?> query = const {},
    Map<String, String> headers = const {},
    Object? abortSignal,
    int cacheSeconds = -1,
    CancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancelled();
    Future<Object?> fetch() async => (await _load(
      operation,
      variables,
      query,
      headers,
      abortSignal,
      cancellationToken,
    )).body;

    final cache = cacheLayer;
    if (cache != null) {
      return await cache(
        builder,
        operation,
        variables,
        query,
        headers,
        fetch,
        cacheSeconds,
      ).asCancellable(cancellationToken);
    }
    return await fetch();
  }

  Future<PathfinderResponse> _load(
    PathfinderOperation operation,
    Object? variables,
    Map<String, Object?> query,
    Map<String, String> headers,
    Object? abortSignal,
    CancellationToken? cancellationToken,
  ) async {
    cancellationToken?.throwIfCancelled();
    final PathfinderResponse response;
    try {
      response = await send(_request(
        operation,
        variables,
        query,
        headers: headers,
        abortSignal: abortSignal,
        cancellationToken: cancellationToken,
      )).asCancellable(cancellationToken);
    } on HttpResponseError catch (error) {
      if (error.status == 405 || error.status == 412) {
        return _fallback(
          operation,
          variables,
          query,
          error.status == 405 ? 'method-not-allowed' : 'precondition-failed',
          cancellationToken,
        );
      }
      rethrow;
    }
    final body = response.body;
    if (body is Map && body['errors'] is List &&
        (body['errors'] as List).any(
          (error) => error is Map &&
              error['message'] == 'PersistedQueryNotFound',
        )) {
      return _fallback(
        operation,
        variables,
        query,
        'persisted-query-not-found',
        cancellationToken,
      );
    }
    return response;
  }

  Future<PathfinderResponse> _fallback(
    PathfinderOperation operation,
    Object? variables,
    Map<String, Object?> query,
    String reason,
    CancellationToken? cancellationToken,
  ) async {
    cancellationToken?.throwIfCancelled();
    if (operation.value == null) {
      throw GraphQLFallbackUnavailableError(operation.name, reason);
    }
    return send(_request(operation, variables, query, fallback: true,
      cancellationToken: cancellationToken)).asCancellable(cancellationToken);
  }

  PathfinderRequest _request(
    PathfinderOperation operation,
    Object? variables,
    Map<String, Object?> query, {
    bool fallback = false,
    Map<String, String> headers = const {},
    Object? abortSignal,
    CancellationToken? cancellationToken,
  }) {
    final host = isInternalRequest
        ? 'https://wgint.spotify.net/curiosity/v1'
        : 'https://api-partner.spotify.com/pathfinder/v${fallback ? 1 : 2}';
    final extensions = {
      'persistedQuery': {'version': 1, 'sha256Hash': operation.sha256Hash},
    };
    final body = fallback
        ? {
            'operationName': operation.name,
            'variables': variables,
            'query': operation.value,
            'extensions': extensions,
          }
        : {
            'variables': variables,
            'operationName': operation.name,
            'extensions': extensions,
          };
    return PathfinderRequest(
      envelope: builder
          .build()
          .withCancellation(cancellationToken)
          .withHost(host)
          .withMethod('POST')
          .withoutMarket()
          .withPath('/query')
          .withJsonContentType()
          .withQueryParameters(query)
          .withBody(body)
          .withHeaders(headers)
          .envelope(),
      endpointIdentifier: '/query/${operation.name}',
      abortSignal: abortSignal,
    );
  }
}
