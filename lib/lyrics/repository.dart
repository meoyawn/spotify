import 'package:cancellation_token/cancellation_token.dart';

import '../playback/native_spotify_gid.dart';
import '../protocol/request_builder.dart';

class LyricsResponse {
  const LyricsResponse(this.status, this.body);
  final int status;
  final Object? body;
}

enum LyricsAvailability { available, unavailable, restricted }

class LyricsLine {
  const LyricsLine({required this.startMs, required this.endMs, required this.words});
  final int startMs;
  final int? endMs;
  final String words;
}

class TrackLyrics {
  const TrackLyrics({required this.availability, this.lines = const [], this.previewLines = const [],
    this.syncType = '', this.provider = '', this.providerDisplayName = '', this.capStatus = '',
    this.background = 0xff535353, this.text = 0xffb3b3b3, this.highlightText = 0xffffffff});
  final LyricsAvailability availability;
  final List<LyricsLine> lines, previewLines;
  final String syncType, provider, providerDisplayName, capStatus;
  final int background, text, highlightText;
  bool get isTimeSynced => syncType == 'LINE_SYNCED' || syncType == 'SYLLABLE_SYNCED';
}

/// Original module68900 requests and module91243 response fields.
class LyricsRepository {
  LyricsRepository({required this.builder, required this.send});
  final SpotifyRequestBuilder builder;
  final Future<LyricsResponse> Function(RequestEnvelope request) send;

  Future<TrackLyrics> load(String uri, String image, {String? clientLanguage,
      CancellationToken? cancellationToken}) async {
    cancellationToken?.throwIfCancelled();
    final gid = nativeSpotifyTrackGid(uri).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final availability = await send(builder.build().withCancellation(cancellationToken)
      .withHost('https://spclient.wg.spotify.com/metadata/4')
      .withPath('/track/$gid').envelope()).asCancellable(cancellationToken);
    cancellationToken?.throwIfCancelled();
    if (availability.status == 403) return const TrackLyrics(availability: LyricsAvailability.restricted);
    if (availability.status == 404) return const TrackLyrics(availability: LyricsAvailability.unavailable);
    _check(availability);
    if (_map(availability.body)['has_lyrics'] != true || image.isEmpty) {
      return const TrackLyrics(availability: LyricsAvailability.unavailable);
    }
    final response = await send(builder.build().withCancellation(cancellationToken)
      .withHost('https://spclient.wg.spotify.com/color-lyrics/v2')
      .withPath('/track/${Uri.encodeComponent(uri.split(':').last)}/image/${Uri.encodeComponent(image)}')
      .withQueryParameters({'format': 'json', 'vocalRemoval': false,
        if (clientLanguage != null && clientLanguage.isNotEmpty) 'clientLanguage': clientLanguage}).envelope())
      .asCancellable(cancellationToken);
    if (response.status == 404) return const TrackLyrics(availability: LyricsAvailability.unavailable);
    if (response.status == 403) return const TrackLyrics(availability: LyricsAvailability.restricted);
    _check(response);
    final body = _map(response.body), lyrics = _map(body['lyrics']), colors = _map(body['colors']);
    if (lyrics['lines'] is! List) throw const FormatException('Lyrics response has no lines');
    return TrackLyrics(availability: LyricsAvailability.available,
      lines: _lines(lyrics['lines']), previewLines: _lines(lyrics['previewLines']),
      syncType: lyrics['syncType'] as String? ?? '', provider: lyrics['provider'] as String? ?? '',
      providerDisplayName: lyrics['providerDisplayName'] as String? ?? '',
      capStatus: lyrics['capStatus'] as String? ?? '',
      background: _color(colors['background'], 0xff535353), text: _color(colors['text'], 0xffb3b3b3),
      highlightText: _color(colors['highlightText'], 0xffffffff));
  }
}

void _check(LyricsResponse response) {
  if (response.status < 200 || response.status >= 300) {
    throw StateError(response.status == 429 ? 'Lyrics are temporarily unavailable. Try again later.'
      : 'Couldn’t load lyrics (${response.status}).');
  }
}
Map<String, Object?> _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
int _color(Object? value, int fallback) => value is int ? 0xff000000 | (value & 0xffffff) : fallback;
List<LyricsLine> _lines(Object? value) {
  if (value is! List) return const [];
  int start(Object? line) => int.tryParse('${_map(line)['startTimeMs']}') ?? 0;
  return List.unmodifiable([for (var i = 0; i < value.length; i++) LyricsLine(
    startMs: start(value[i]), endMs: i + 1 < value.length ? start(value[i + 1]) : null,
    words: _map(value[i])['words'] as String? ?? '')]);
}
