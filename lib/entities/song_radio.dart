import 'package:cancellation_token/cancellation_token.dart';

import '../protocol/request_builder.dart';

typedef SongRadioResolver = Future<String> Function(String uri, {CancellationToken? cancellationToken});

/// Original renderer modules 39732 and 53150. Free/Premium product identity is
/// independent of the account's personalized-recommendation permission.
bool songRadioAllowed(Map<String, String> productState) =>
  productState['user_access_personalized_recs'] == null
    ? productState['dsa-mode-enabled'] != '1'
    : productState['user_access_personalized_recs'] != '0';

Future<String> resolveSongRadioPlaylist(String uri, {required SpotifyRequestBuilder builder,
    required Future<({int status, Object? body})> Function(RequestEnvelope request) send,
    CancellationToken? cancellationToken}) async {
  cancellationToken?.throwIfCancelled();
  if (!RegExp(r'^spotify:track:[0-9A-Za-z]{22}$').hasMatch(uri)) {
    throw const FormatException('Song radio needs a Spotify song.');
  }
  final response = await send(builder.build().withCancellation(cancellationToken)
    .withHost('https://spclient.wg.spotify.com/inspiredby-mix/v2')
    .withPath('/seed_to_playlist/$uri')
    .withQueryParameters({'response-format': 'json'}).withoutMarket().envelope());
  cancellationToken?.throwIfCancelled();
  if (response.status < 200 || response.status >= 300) {
    throw StateError(switch (response.status) {
      403 => 'Song radio is unavailable for this account.',
      404 => 'Song radio is unavailable for this song.',
      429 => 'Song radio is temporarily unavailable. Try again later.',
      _ => 'Couldn’t load song radio (${response.status}).',
    });
  }
  final body = response.body;
  final items = body is Map ? body['mediaItems'] : null;
  final first = items is List && items.isNotEmpty ? items.first : null;
  final playlist = first is Map ? first['uri'] : null;
  if (playlist is! String || !RegExp(r'^spotify:playlist:[0-9A-Za-z]{22}$').hasMatch(playlist)) {
    throw const FormatException('Spotify returned no song radio playlist.');
  }
  return playlist;
}
